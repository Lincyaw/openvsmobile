// App entrypoint. Boots the BackendClient + AppState, loads saved settings,
// wires connectivity + app-lifecycle to the always-on reconnect loop, and
// drops the user into either the home shell or the first-run settings prompt.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'backend_client.dart';
import 'screens/home_shell.dart';
import 'screens/notification_center.dart';
import 'screens/settings_screen.dart';
import 'services/connectivity_probe.dart';
import 'services/deep_link_service.dart';
import 'services/fcm_service.dart';
import 'services/notification_foreground_service.dart';
import 'settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The foreground-service ↔ main-isolate SendPort must be wired before
  // `runApp` so that taps on tray notifications posted while the app was
  // dead are still routed correctly when the app launches.
  FlutterForegroundTask.initCommunicationPort();
  // Best-effort FCM init — failures (e.g. no GMS / missing config) are
  // logged and ignored. The foreground-service path keeps working.
  await initFirebaseAndFcm();
  runApp(const OpenVsMobileApp());
}

class OpenVsMobileApp extends StatefulWidget {
  const OpenVsMobileApp({super.key});

  @override
  State<OpenVsMobileApp> createState() => _OpenVsMobileAppState();
}

class _OpenVsMobileAppState extends State<OpenVsMobileApp>
    with WidgetsBindingObserver {
  final SettingsStore _settingsStore = SettingsStore();
  late final BackendClient _client =
      BackendClient(probe: ConnectivityPlusProbe());
  final NotificationServiceController _fgService =
      NotificationServiceController();
  final FcmController _fcm = FcmController();
  final DeepLinkService _deepLinks = DeepLinkService();
  VoidCallback? _deepLinkRemover;
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  AppState? _appState;
  bool _fcmListenerWired = false;

  Settings? _settings;
  String? _deviceId;
  NotificationPrefs? _notifPrefs;
  bool _loadingSettings = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fgService.init();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final s = await _settingsStore.load();
    final did = await _settingsStore.loadOrCreateDeviceId();
    final prefs = await _settingsStore.loadNotificationPrefs();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _deviceId = did;
      _notifPrefs = prefs;
      _appState = AppState(client: _client, deviceId: did);
      _loadingSettings = false;
    });
    if (s.isComplete) {
      _client.configure(
        host: s.host,
        port: s.port,
        token: s.token,
        deviceId: did,
      );
      await _client.start();
      await _maybeStartForegroundService();
      await _initFcm(did);
    }
    // Deep links from the ntfy app land in DeepLinkService. Cold-start
    // ids are consumed on the first frame; warm taps push the same route
    // through the listener.
    await _deepLinks.init();
    _deepLinkRemover = _deepLinks.addListener(_openNotificationCenterFor);
    // If we were launched by a tap on a tray notification, route to the
    // notification center after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingTapIfAny();
      final id = _deepLinks.consumePendingId();
      if (id != null) _openNotificationCenterFor(id);
    });
  }

  /// Wire FCM once we have a deviceId. The token-register call is fired on
  /// every backend (re)connect (and on token rotation), so it survives
  /// transient drops without re-init. Safe to call multiple times.
  Future<void> _initFcm(String deviceId) async {
    await _fcm.init(client: _client, deviceId: deviceId);
    if (!_fcmListenerWired) {
      _fcmListenerWired = true;
      _client.state.addListener(_onClientStateForFcm);
    }
    // Fire once now in case we're already past the connected transition
    // (race between bootstrap and the first ws handshake).
    if (_client.state.value == BackendConnectionState.connected) {
      unawaited(_fcm.registerWithBackend());
    }
  }

  void _onClientStateForFcm() {
    if (_client.state.value == BackendConnectionState.connected) {
      unawaited(_fcm.registerWithBackend());
    }
  }

  Future<void> _maybeStartForegroundService() async {
    final s = _settings, did = _deviceId, prefs = _notifPrefs;
    debugPrint('FGS: _maybeStartForegroundService called');
    if (s == null || did == null || prefs == null) {
      debugPrint('FGS: early return — s=$s did=$did prefs=$prefs');
      return;
    }
    if (!s.isComplete) {
      debugPrint('FGS: early return — settings incomplete');
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
      await _settingsStore
          .saveNotificationPrefs(prefs.copyWith(backgroundEnabled: false));
      if (!mounted) return;
      setState(() => _notifPrefs = prefs.copyWith(backgroundEnabled: false));
      return;
    }
    // Without battery-optimization exemption, Doze freezes the service
    // isolate's WebSocket after a few minutes of background — the persistent
    // tray notification keeps showing (Android renders it from a snapshot)
    // but `notification.show` pushes never reach `_handleShow`. We prompt
    // once; if the user declines we still start the service so foreground
    // delivery keeps working.
    final ignoringBattery =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    debugPrint('FGS: isIgnoringBatteryOptimizations=$ignoringBattery');
    if (!ignoringBattery) {
      final granted =
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      debugPrint('FGS: requestIgnoreBatteryOptimization=$granted');
    }
    debugPrint('FGS: calling _fgService.start...');
    final ok = await _fgService.start(
      host: s.host,
      port: s.port,
      token: s.token,
      deviceId: did,
      mutedSources: prefs.mutedSources,
      quietStartMinutes: prefs.quietHoursStartMinutes ?? -1,
      quietEndMinutes: prefs.quietHoursEndMinutes ?? -1,
    );
    debugPrint('FGS: _fgService.start returned $ok');
  }

  void _consumePendingTapIfAny() {
    final id = consumePendingTapNotificationId();
    if (id == null) return;
    _openNotificationCenterFor(id);
  }

  /// Push the notification-center route highlighting `id`. Shared between
  /// the foreground-service tray-tap path (consumePendingTapNotificationId)
  /// and the ntfy deep-link path (DeepLinkService). If state isn't ready
  /// yet (very early launch) the call is dropped — the consumer paths both
  /// retry on the next consumption point.
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

  Future<void> _onSettingsSaved(Settings s) async {
    await _settingsStore.save(s);
    if (!mounted) return;
    setState(() => _settings = s);
    await _client.userDisconnect();
    if (s.isComplete) {
      _client.configure(
        host: s.host,
        port: s.port,
        token: s.token,
        deviceId: _deviceId,
      );
      await _client.start();
      // Restart the service with new params, if it's running or should be.
      await _fgService.stop();
      await _maybeStartForegroundService();
      final did = _deviceId;
      if (did != null && did.isNotEmpty) {
        await _initFcm(did);
      }
    }
  }

  /// Called by the notification settings screen when the user touches the
  /// toggle, mute list, or quiet hours. Reloads prefs and re-evaluates
  /// service state.
  Future<void> _onNotificationPrefsChanged() async {
    final prefs = await _settingsStore.loadNotificationPrefs();
    if (!mounted) return;
    setState(() => _notifPrefs = prefs);
    if (!prefs.backgroundEnabled) {
      await _fgService.stop();
      return;
    }
    if (await _fgService.isRunning) {
      // Already running — only the mute / quiet-hours fields can have
      // changed because backgroundEnabled is true. Push them down.
      await _fgService.updatePrefs(
        mutedSources: prefs.mutedSources,
        quietStartMinutes: prefs.quietHoursStartMinutes ?? -1,
        quietEndMinutes: prefs.quietHoursEndMinutes ?? -1,
      );
      return;
    }
    await _maybeStartForegroundService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user yanks the app back from background, fast-path the
    // reconnect instead of letting the backoff timer finish.
    if (state == AppLifecycleState.resumed) {
      _client.requestReconnectNow();
      // Any tray notification tap that happened while we were paused
      // landed in the static pending slot; consume it now.
      _consumePendingTapIfAny();
      // ntfy deep links arriving while paused queue in the pending slot
      // (cold-start path); the warm-path listener also fires from the
      // stream, but consuming here covers the case where the URI was
      // delivered before the listener was attached.
      final id = _deepLinks.consumePendingId();
      if (id != null) _openNotificationCenterFor(id);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_fcmListenerWired) {
      _client.state.removeListener(_onClientStateForFcm);
    }
    unawaited(_fcm.dispose());
    _deepLinkRemover?.call();
    unawaited(_deepLinks.dispose());
    _appState?.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'openvsmobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: _loadingSettings || _appState == null
          ? const _BootSplash()
          : (_settings == null || !_settings!.isComplete)
              ? SettingsScreen(
                  initial: _settings ??
                      const Settings(host: '', port: 7860, token: ''),
                  isFirstRun: true,
                  onSave: _onSettingsSaved,
                )
              : HomeShell(
                  appState: _appState!,
                  settingsStore: _settingsStore,
                  currentSettings: _settings!,
                  fcmController: _fcm,
                  onSettingsSaved: _onSettingsSaved,
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
            SizedBox(height: 12),
            Text('Loading settings…'),
          ],
        ),
      ),
    );
  }
}
