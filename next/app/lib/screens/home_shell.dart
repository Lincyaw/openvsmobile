// Top-level scaffold: app bar with workspace switcher + bell, bottom nav,
// connection-state banner. Backend management lives in the Settings tab.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';
import 'files_tab.dart';
import 'notification_center.dart';
import 'plugins_tab.dart';
import 'settings_tab.dart';
import 'terminal_tab.dart';
import 'workspace_picker.dart';

class HomeShell extends StatefulWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  final AppPersistedState state;
  final SystemTrayController systemTrayController;

  /// Push the Backends management screen. Owned by main.dart so navigation
  /// happens on the root navigator.
  final VoidCallback onOpenBackends;

  /// Wire a freshly-bootstrapped backend back into the persisted list.
  /// Forwarded to the Settings tab so SSH bootstrap launched from there
  /// produces the same result as launching it from BackendsScreen.
  final Future<void> Function(BackendTarget target, {required bool makeActive})
  onBackendInstalled;

  /// Called when the notification preferences screen saves a change.
  /// `main.dart` uses this to (re)start or stop the foreground service.
  final Future<void> Function() onNotificationPrefsChanged;

  /// Current theme mode (system / light / dark). Forwarded into the
  /// Settings tab so the picker renders the active choice.
  final ThemeMode themeMode;

  /// Persist + apply a new theme mode. Forwarded into the Settings tab's
  /// Theme picker so changes round-trip into [main.dart] and re-render
  /// the `MaterialApp`.
  final Future<void> Function(ThemeMode mode) onThemeModeChanged;

  const HomeShell({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.state,
    required this.systemTrayController,
    required this.onOpenBackends,
    required this.onBackendInstalled,
    required this.onNotificationPrefsChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// Stable tab indices for the bottom-nav `IndexedStack`. The destinations
/// list below is the source-of-truth ordering; the named indices below
/// give the numeric values a meaning so jumps from non-tap code paths
/// (e.g. the failed-connection banner's Settings button) read as intent
/// rather than magic numbers. Only the indices we actually reference are
/// listed; if a future code path needs Files / Terminal / Plugins by
/// name, extend this block — don't reintroduce raw `0` / `1` / `2`.
const int _kFilesTabIndex = 0;
const int _kSettingsTabIndex = 3;

class _HomeShellState extends State<HomeShell> {
  int _tab = _kFilesTabIndex;
  bool _appStateFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _flushAppStateChanged();
      return;
    }
    if (_appStateFrameScheduled) return;
    _appStateFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appStateFrameScheduled = false;
      if (!mounted) return;
      _flushAppStateChanged();
    });
  }

  void _flushAppStateChanged() {
    final err = widget.appState.lastOperationError;
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      widget.appState.clearLastOperationError();
    }
    setState(() {});
  }

  Future<void> _openSwitcher() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _WorkspaceSwitcherSheet(appState: widget.appState),
    );
  }

  void _openSettings() {
    // The failed-connection banner's "Settings" button: jump to the
    // Settings tab so the user can fix auth / backend issues from there.
    setState(() => _tab = _kSettingsTabIndex);
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.appState.currentWorkspace;
    final connState = widget.appState.connectionState;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _openSwitcher,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  cur == null ? Icons.folder_off_outlined : Icons.folder_open,
                  size: AppIconSize.md,
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    cur?.label ?? '(choose workspace)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: [
          _BellIconAction(
            appState: widget.appState,
            settingsStore: widget.settingsStore,
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            state: connState,
            lastError: widget.appState.lastConnectionError,
            onOpenSettings: _openSettings,
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                FilesTab(appState: widget.appState),
                TerminalTab(
                  appState: widget.appState,
                  settingsStore: widget.settingsStore,
                ),
                PluginsTab(appState: widget.appState),
                SettingsTab(
                  appState: widget.appState,
                  settingsStore: widget.settingsStore,
                  systemTrayController: widget.systemTrayController,
                  onOpenBackends: widget.onOpenBackends,
                  onBackendInstalled: widget.onBackendInstalled,
                  onNotificationPrefsChanged: widget.onNotificationPrefsChanged,
                  themeMode: widget.themeMode,
                  onThemeModeChanged: widget.onThemeModeChanged,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Terminal',
          ),
          NavigationDestination(
            icon: Icon(Icons.extension_outlined),
            selectedIcon: Icon(Icons.extension),
            label: 'Plugins',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Connection banner. The brief calls out "WeChat-style":
///   * Hide entirely when connected.
///   * Short pre-show delay on connecting/reconnecting to avoid flicker on
///     sub-500 ms hiccups.
///   * Subtle, neutral/amber styling for transient states. Red is reserved
///     for `failed` (auth error / unrecoverable), which gets a Settings
///     shortcut so the user can fix the only thing that actually broke.
class _ConnectionBanner extends StatefulWidget {
  final BackendConnectionState state;
  final String? lastError;
  final VoidCallback onOpenSettings;
  const _ConnectionBanner({
    required this.state,
    required this.lastError,
    required this.onOpenSettings,
  });

  @override
  State<_ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<_ConnectionBanner> {
  Timer? _showTimer;
  bool _shouldShow = false;

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  @override
  void didUpdateWidget(covariant _ConnectionBanner old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _evaluate();
  }

  void _evaluate() {
    _showTimer?.cancel();
    _showTimer = null;
    final s = widget.state;
    if (s == BackendConnectionState.connected) {
      _shouldShow = false;
      return;
    }
    if (s == BackendConnectionState.failed) {
      // Show immediately; the user has to act.
      _shouldShow = true;
      return;
    }
    if (s == BackendConnectionState.waitingForNetwork) {
      // Show immediately; flicker doesn't matter here — the OS state will
      // remain "no network" until it changes, which is by definition not a
      // sub-second event.
      _shouldShow = true;
      return;
    }
    // connecting/reconnecting/disconnected: hide for 500 ms, then show.
    _shouldShow = false;
    _showTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (widget.state == BackendConnectionState.connected) return;
      setState(() => _shouldShow = true);
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldShow) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final s = widget.state;
    if (s == BackendConnectionState.failed) {
      return Container(
        width: double.infinity,
        color: theme.colorScheme.errorContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: AppDensity.bannerHPad,
          vertical: AppDensity.bannerVPad,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.lastError ?? 'Connection failed.',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: widget.onOpenSettings,
              child: const Text('Settings'),
            ),
          ],
        ),
      );
    }
    final (msg, withSpinner) = switch (s) {
      BackendConnectionState.connecting => ('Connecting…', true),
      BackendConnectionState.reconnecting => ('Connecting…', true),
      BackendConnectionState.waitingForNetwork => (
        'Waiting for network.',
        true,
      ),
      BackendConnectionState.disconnected => ('Disconnected.', false),
      BackendConnectionState.connected => ('', false),
      BackendConnectionState.failed => ('', false), // handled above
    };
    if (msg.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDensity.bannerHPad,
        vertical: AppDensity.bannerVPad,
      ),
      child: Row(
        children: [
          if (withSpinner)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (withSpinner) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceSwitcherSheet extends StatelessWidget {
  final AppState appState;
  const _WorkspaceSwitcherSheet({required this.appState});

  Future<void> _confirmClose(BuildContext context, Workspace w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${w.label}?'),
        content: Text(
          'This will kill any running terminals in this workspace.\n\n${w.root}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await appState.closeWorkspace(w.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = appState.activeWorkspaces;
    final activeRoots = active.map((w) => w.root).toSet();
    final recentsOnly = appState.recentRoots
        .where((r) => !activeRoots.contains(r))
        .toList();
    final cur = appState.currentWorkspace;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(
                'Open workspaces',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (active.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(
                  'None — open one from Recent or Browse below.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            for (final w in active)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(w.label),
                subtitle: Text(
                  w.root,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: cur?.id == w.id
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                enabled: cur?.id != w.id,
                onTap: () async {
                  Navigator.of(context).pop();
                  await appState.activateWorkspace(w.id);
                },
                onLongPress: () => _confirmClose(context, w),
              ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(
                'Recent',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (recentsOnly.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(
                  'No other recents yet.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            for (final r in recentsOnly)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(_recentLabel(r)),
                subtitle: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () async {
                  Navigator.of(context).pop();
                  await appState.openWorkspace(r);
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('Browse new…'),
              subtitle: const Text('Pick a folder by drilling in step-by-step'),
              onTap: () async {
                Navigator.of(context).pop();
                await Navigator.of(context).push(
                  MaterialPageRoute<Workspace>(
                    builder: (_) => WorkspacePickerScreen(appState: appState),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Last non-empty path segment, falling back to the full path for roots.
  String _recentLabel(String path) {
    for (final segment in path.split('/').reversed) {
      if (segment.isNotEmpty) return segment;
    }
    return path;
  }
}

/// Bell icon for the notification center. Chrome-level — visible from every
/// tab. Hidden only when both disconnected AND zero unread, since neither
/// surface needs the user's attention in that case (the connection banner
/// already signals offline).
class _BellIconAction extends StatelessWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  const _BellIconAction({required this.appState, required this.settingsStore});

  @override
  Widget build(BuildContext context) {
    final unread = appState.notifications.unreadCount;
    final connected =
        appState.connectionState == BackendConnectionState.connected;
    if (!connected && unread == 0) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Notifications',
      icon: unread > 0
          ? Badge.count(
              count: unread,
              child: const Icon(Icons.notifications_outlined),
            )
          : const Icon(Icons.notifications_outlined),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NotificationCenterScreen(
              appState: appState,
              settingsStore: settingsStore,
            ),
          ),
        );
      },
    );
  }
}
