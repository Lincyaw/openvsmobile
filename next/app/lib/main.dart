// App entrypoint. Boots the BackendClient + AppState, loads the persisted
// backends list (migrating the legacy single-backend keys if present),
// wires connectivity + app-lifecycle to the always-on reconnect loop, and
// drops the user into either the home shell or the empty-state Backends
// screen for first-run setup.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'backend_client.dart';
import 'notification.dart';
import 'screens/backends_screen.dart';
import 'screens/diag_overlay.dart';
import 'screens/home_shell.dart';
import 'screens/notification_center.dart';
import 'services/connectivity_probe.dart';
import 'services/deep_link_service.dart';
import 'services/diag_log.dart';
import 'services/notification_foreground_service.dart';
import 'services/system_tray.dart';
import 'settings_store.dart';
import 'ui/app_theme.dart';
import 'ui/app_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The foreground-service ↔ main-isolate SendPort must be wired before
  // `runApp` so that taps on tray notifications posted while the app was
  // dead are still routed correctly when the app launches.
  FlutterForegroundTask.initCommunicationPort();
  runApp(const MobileCodeApp());
}

class MobileCodeApp extends StatefulWidget {
  const MobileCodeApp({super.key, this.enableSystemTray = true});

  final bool enableSystemTray;

  @override
  State<MobileCodeApp> createState() => _MobileCodeAppState();
}

class _MobileCodeAppState extends State<MobileCodeApp>
    with WidgetsBindingObserver {
  final SettingsStore _settingsStore = SettingsStore();
  late final BackendClient _client = BackendClient(
    probe: ConnectivityPlusProbe(),
  );
  final NotificationServiceController _fgService =
      NotificationServiceController();
  final DeepLinkService _deepLinks = DeepLinkService();
  final SystemTrayController _tray = SystemTrayController();
  StreamSubscription<BackendNotification>? _trayNotifSub;
  VoidCallback? _deepLinkRemover;
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  AppState? _appState;

  AppPersistedState _state = const AppPersistedState();
  String? _deviceId;
  NotificationPrefs? _notifPrefs;
  ThemeMode _themeMode = ThemeMode.system;
  bool _loadingSettings = true;
  String? _lastPersistedWorkspaceId;
  VoidCallback? _connectedRestoreListener;
  bool _suspendWorkspaceTracking = false;
  int _backendSessionOrdinal = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fgService.init();
    if (widget.enableSystemTray) {
      unawaited(_tray.init());
      _trayNotifSub = _client.notifications.listen(
        _onBackendNotificationForTray,
      );
    }
    _client.state.addListener(_logConnectionState);
    _bootstrap();
  }

  /// Feed backend connection transitions into the debug overlay so a trace
  /// shows reconnect windows alongside any dropped writes.
  void _logConnectionState() {
    DiagLog.instance.log(
      DiagCat.net,
      'connection → ${_client.state.value.name}',
    );
  }

  /// Fan `notification.show` / `.deleted` / `.superseded` pushes to
  /// the system tray. Other pushes (terminal.*, workspace.*, etc.) are
  /// ignored here — `AppState._onNotification` consumes them.
  void _onBackendNotificationForTray(BackendNotification n) {
    switch (n.method) {
      case BackendNotifications.notificationShow:
        final p = n.params;
        if (p is! Map<String, dynamic>) return;
        final raw = p['notification'];
        if (raw is! Map<String, dynamic>) return;
        final appNotif = AppNotification.fromJson(raw);
        final prefs = _notifPrefs;
        unawaited(
          _tray.show(
            appNotif,
            mutedSources: prefs?.mutedSources.toSet() ?? const <String>{},
            quietStartMinutes: prefs?.quietHoursStartMinutes ?? -1,
            quietEndMinutes: prefs?.quietHoursEndMinutes ?? -1,
          ),
        );
      case BackendNotifications.notificationDeleted:
        final p = n.params;
        if (p is! Map<String, dynamic>) return;
        final ids =
            (p['ids'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        for (final id in ids) {
          unawaited(_tray.cancel(id));
        }
      case BackendNotifications.notificationSuperseded:
        final p = n.params;
        if (p is! Map<String, dynamic>) return;
        final oldId = p['oldId'];
        if (oldId is String) unawaited(_tray.cancel(oldId));
      default:
        break;
    }
  }

  Future<void> _bootstrap() async {
    final state = await _settingsStore.loadAppState();
    final did = await _settingsStore.loadOrCreateDeviceId();
    final prefs = await _settingsStore.loadNotificationPrefs();
    final themeMode = await _settingsStore.loadThemeMode();
    // Developer instrument: restore the debug-overlay flag so the floating
    // event log reappears across restarts while debugging.
    DiagLog.instance.enabled =
        await _settingsStore.getBool(kDiagLogPrefKey) ?? false;
    if (!mounted) return;
    final appState = AppState(client: _client, deviceId: did);
    appState.addListener(_onAppStateForWorkspaceTracking);
    setState(() {
      _state = state;
      _deviceId = did;
      _notifPrefs = prefs;
      _themeMode = themeMode;
      _appState = appState;
      _loadingSettings = false;
    });
    final active = state.activeBackend;
    if (active != null && active.isComplete) {
      final sessionOrdinal = _beginBackendSession();
      _client.configure(
        host: active.host,
        port: active.port,
        token: active.token,
        deviceId: did,
      );
      _scheduleOpenLastWorkspaceWhenConnected(active, sessionOrdinal);
      await _client.start();
      await _maybeStartForegroundService();
    }
    await _deepLinks.init();
    _deepLinkRemover = _deepLinks.addListener(_openNotificationCenterFor);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingTapIfAny();
      final id = _deepLinks.consumePendingId();
      if (id != null) _openNotificationCenterFor(id);
    });
  }

  /// One-shot: once the client transitions to `connected` for an active
  /// backend, reopen its last-known workspace (if any) and update
  /// `lastConnectedAt`. Idempotent against multiple transitions — we detach
  /// the listener after the first `connected` event.
  void _clearPendingConnectedRestore() {
    final listener = _connectedRestoreListener;
    if (listener == null) return;
    _client.state.removeListener(listener);
    _connectedRestoreListener = null;
  }

  int _beginBackendSession() {
    _backendSessionOrdinal++;
    _clearPendingConnectedRestore();
    _lastPersistedWorkspaceId = null;
    return _backendSessionOrdinal;
  }

  Future<void> _disconnectAndResetForBackendSession() async {
    _suspendWorkspaceTracking = true;
    try {
      await _client.userDisconnect();
      _appState?.resetForBackendSession();
    } finally {
      _suspendWorkspaceTracking = false;
    }
  }

  void _scheduleOpenLastWorkspaceWhenConnected(
    BackendTarget target,
    int sessionOrdinal,
  ) {
    _clearPendingConnectedRestore();

    void runRestore() {
      _clearPendingConnectedRestore();
      if (sessionOrdinal != _backendSessionOrdinal) return;
      if (_state.activeBackendId != target.id) return;
      final stamped = target.copyWith(
        lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
      );
      unawaited(_replaceBackend(stamped, makeActive: true, reconnect: false));
      final ws = target.lastWorkspaceId;
      if (ws != null && _appState != null) {
        // Wait one microtask so AppState.refreshWorkspaces (kicked by the
        // same connection-state listener inside AppState) has a chance to
        // populate the active list. activateWorkspace is a no-op if the
        // backend doesn't know the id — we then fall back to leaving the
        // user on the switcher.
        unawaited(
          Future<void>(() async {
            await _appState!.activateWorkspace(ws);
          }),
        );
      }
    }

    if (_client.state.value == BackendConnectionState.connected) {
      runRestore();
      return;
    }

    void listener() {
      if (_client.state.value != BackendConnectionState.connected) return;
      runRestore();
    }

    _connectedRestoreListener = listener;
    _client.state.addListener(listener);
  }

  /// Observe currentWorkspace transitions and persist them onto the active
  /// backend so a later switch back lands on the same workspace.
  void _onAppStateForWorkspaceTracking() {
    if (_suspendWorkspaceTracking) return;
    final cur = _appState?.currentWorkspace;
    final activeId = _state.activeBackendId;
    if (activeId == null) return;
    final id = cur?.id;
    if (id == null) return;
    if (id == _lastPersistedWorkspaceId) return;
    _lastPersistedWorkspaceId = id;
    final active = _state.activeBackend;
    if (active == null || active.lastWorkspaceId == id) return;
    final updated = active.copyWith(lastWorkspaceId: id);
    unawaited(_replaceBackend(updated, makeActive: true, reconnect: false));
  }

  Future<void> _maybeStartForegroundService() async {
    final active = _state.activeBackend;
    final prefs = _notifPrefs;
    debugPrint('FGS: _maybeStartForegroundService called');
    if (active == null || prefs == null) {
      debugPrint('FGS: early return — active=$active prefs=$prefs');
      return;
    }
    if (!active.isComplete) {
      debugPrint('FGS: early return — backend incomplete');
      return;
    }
    if (!prefs.backgroundEnabled) {
      debugPrint('FGS: early return — backgroundEnabled=false');
      await _fgService.stop();
      return;
    }
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    debugPrint('FGS: perm=$perm');
    NotificationPermission resolved = perm;
    if (perm == NotificationPermission.denied) {
      resolved = await FlutterForegroundTask.requestNotificationPermission();
      debugPrint('FGS: after request perm=$resolved');
    }
    if (resolved != NotificationPermission.granted) {
      debugPrint('FGS: early return — perm not granted ($resolved)');
      await _settingsStore.saveNotificationPrefs(
        prefs.copyWith(backgroundEnabled: false),
      );
      if (!mounted) return;
      setState(() => _notifPrefs = prefs.copyWith(backgroundEnabled: false));
      return;
    }
    final ignoringBattery =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    debugPrint('FGS: isIgnoringBatteryOptimizations=$ignoringBattery');
    if (!ignoringBattery) {
      final granted =
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      debugPrint('FGS: requestIgnoreBatteryOptimization=$granted');
    }
    debugPrint('FGS: calling _fgService.start...');
    final ok = await _fgService.start();
    debugPrint('FGS: _fgService.start returned $ok');
  }

  void _consumePendingTapIfAny() {
    final id = consumePendingTapNotificationId();
    if (id == null) return;
    _openNotificationCenterFor(id);
  }

  void _openNotificationCenterFor(String id) {
    final state = _appState;
    if (state == null) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => NotificationCenterScreen(
          appState: state,
          settingsStore: _settingsStore,
          highlightId: id,
        ),
      ),
    );
  }

  // ---- Backends list mutations ----

  /// Persist [_state] and reflect it locally. Pure write — no client touch.
  Future<void> _persistState(AppPersistedState next) async {
    await _settingsStore.saveAppState(next);
    if (!mounted) return;
    setState(() => _state = next);
  }

  /// Replace (or insert) [target] into the backends list. When [makeActive]
  /// is true, switch the active backend to [target.id]. When [reconnect] is
  /// true and the active backend's connection params changed, restart the
  /// client. (Pure bookkeeping updates like a fresh lastConnectedAt pass
  /// reconnect=false.)
  Future<void> _replaceBackend(
    BackendTarget target, {
    required bool makeActive,
    required bool reconnect,
  }) async {
    final existing = _state.backends;
    final idx = existing.indexWhere((b) => b.id == target.id);
    final next = [...existing];
    if (idx >= 0) {
      next[idx] = target;
    } else {
      next.add(target);
    }
    final wasActiveId = _state.activeBackendId;
    final newActiveId = makeActive ? target.id : wasActiveId;
    final newState = _state.copyWith(
      backends: next,
      activeBackendId: newActiveId,
    );
    await _persistState(newState);
    if (!reconnect) return;
    if (newActiveId == target.id) {
      await _restartClientForActive();
    }
  }

  Future<void> _addBackend(
    BackendTarget target, {
    required bool makeActive,
  }) async {
    await _replaceBackend(
      target,
      makeActive: makeActive,
      reconnect: makeActive,
    );
  }

  Future<void> _updateBackend(BackendTarget target) async {
    // Reconnect only when we're touching the currently active backend —
    // otherwise it's just bookkeeping on the dormant entry.
    final reconnect = target.id == _state.activeBackendId;
    await _replaceBackend(target, makeActive: false, reconnect: reconnect);
  }

  Future<void> _deleteBackend(String id) async {
    final next = _state.backends.where((b) => b.id != id).toList();
    String? newActive = _state.activeBackendId;
    final wasActive = id == newActive;
    if (wasActive) {
      newActive = next.isEmpty ? null : next.first.id;
    }
    final newState = _state.copyWith(
      backends: next,
      activeBackendId: newActive,
      clearActiveBackendId: newActive == null,
    );
    await _persistState(newState);
    if (wasActive) {
      if (newActive == null) {
        _beginBackendSession();
        await _disconnectAndResetForBackendSession();
        await _fgService.stop();
      } else {
        await _restartClientForActive();
      }
    }
  }

  Future<void> _switchBackend(String id) async {
    if (id == _state.activeBackendId) return;
    final newState = _state.copyWith(activeBackendId: id);
    await _persistState(newState);
    await _restartClientForActive();
  }

  /// Tear down and reopen the client against the active backend. Also
  /// schedules the post-connect "reopen lastWorkspaceId" pass.
  Future<void> _restartClientForActive() async {
    final active = _state.activeBackend;
    final sessionOrdinal = _beginBackendSession();
    await _disconnectAndResetForBackendSession();
    await _fgService.stop();
    if (active == null || !active.isComplete) return;
    _client.configure(
      host: active.host,
      port: active.port,
      token: active.token,
      deviceId: _deviceId,
    );
    _scheduleOpenLastWorkspaceWhenConnected(active, sessionOrdinal);
    await _client.start();
    await _maybeStartForegroundService();
  }

  /// Persist a new [ThemeMode] choice and re-render the `MaterialApp`
  /// against it. Called from the Settings tab. Synchronous from the
  /// user's perspective — we `setState` first so the toggle feels
  /// immediate, then flush to disk.
  Future<void> _onThemeModeChanged(ThemeMode mode) async {
    if (mode == _themeMode) return;
    setState(() => _themeMode = mode);
    await _settingsStore.saveThemeMode(mode);
  }

  Future<void> _onNotificationPrefsChanged() async {
    final prefs = await _settingsStore.loadNotificationPrefs();
    if (!mounted) return;
    setState(() => _notifPrefs = prefs);
    if (!prefs.backgroundEnabled) {
      await _fgService.stop();
      return;
    }
    if (await _fgService.isRunning) {
      return;
    }
    await _maybeStartForegroundService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _client.requestReconnectNow();
      _consumePendingTapIfAny();
      final id = _deepLinks.consumePendingId();
      if (id != null) _openNotificationCenterFor(id);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinkRemover?.call();
    _clearPendingConnectedRestore();
    unawaited(_deepLinks.dispose());
    unawaited(_trayNotifSub?.cancel());
    _trayNotifSub = null;
    _appState?.removeListener(_onAppStateForWorkspaceTracking);
    _appState?.dispose();
    _client.state.removeListener(_logConnectionState);
    _client.dispose();
    super.dispose();
  }

  Widget _buildBackendsScreen() {
    return BackendsScreen(
      state: _state,
      appState: _appState!,
      onAdd: _addBackend,
      onUpdate: _updateBackend,
      onDelete: _deleteBackend,
      onSwitch: _switchBackend,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'MobileCode',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      // App-wide debug overlay floats above every route (incl. pushed ones
      // like the terminal detail view). Self-hides unless enabled in
      // Settings; empty areas fall through to the app below.
      builder: (context, child) => Stack(
        children: [
          ?child,
          const Positioned.fill(child: DiagOverlay()),
        ],
      ),
      home: _loadingSettings || _appState == null
          ? const _BootSplash()
          : (_state.activeBackend == null)
          ? _buildBackendsScreen()
          : HomeShell(
              appState: _appState!,
              settingsStore: _settingsStore,
              state: _state,
              systemTrayController: _tray,
              themeMode: _themeMode,
              onThemeModeChanged: _onThemeModeChanged,
              onOpenBackends: () {
                _navKey.currentState?.push(
                  MaterialPageRoute<void>(
                    builder: (_) => _buildBackendsScreen(),
                  ),
                );
              },
              onBackendInstalled: _addBackend,
              onNotificationPrefsChanged: _onNotificationPrefsChanged,
            ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: AppSpacing.md),
            Text('Loading settings…'),
          ],
        ),
      ),
    );
  }
}
