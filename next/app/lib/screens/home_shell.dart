// Top-level scaffold: tab-aware app bar + bell, bottom nav, connection-state
// banner. Backend management lives in the Settings tab.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../notification.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../state/terminal_hub.dart';
import '../ui/app_tokens.dart';
import 'files_tab.dart';
import 'notification_center.dart';
import 'plugins_tab.dart';
import 'settings_tab.dart';
import 'terminal_detail.dart';
import 'terminal_tab.dart';
import 'workspace_picker.dart';

class HomeShell extends StatefulWidget {
  final AppState appState;
  final TerminalHub terminalHub;
  final SettingsStore settingsStore;
  final AppPersistedState state;
  final SystemTrayController systemTrayController;

  /// Push the Backends management screen. Owned by main.dart so navigation
  /// happens on the root navigator.
  final VoidCallback onOpenBackends;

  /// Switch the active backend before jumping from a cross-backend terminal
  /// session into its Files workspace.
  final Future<void> Function(String backendId) onSwitchBackend;

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
    required this.terminalHub,
    required this.settingsStore,
    required this.state,
    required this.systemTrayController,
    required this.onOpenBackends,
    required this.onSwitchBackend,
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
const int _kTerminalTabIndex = 1;
const int _kPluginsTabIndex = 2;
const int _kSettingsTabIndex = 3;

class _HomeShellState extends State<HomeShell> {
  int _tab = _kFilesTabIndex;
  bool _appStateFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    widget.terminalHub.addListener(_onTerminalHubChanged);
  }

  @override
  void dispose() {
    widget.terminalHub.removeListener(_onTerminalHubChanged);
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

  void _onTerminalHubChanged() {
    if (!mounted) return;
    final err = widget.terminalHub.lastOperationError;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      widget.terminalHub.clearLastOperationError();
    }
    setState(() {});
  }

  Future<void> _openSwitcher() async {
    final backend = await showModalBottomSheet<BackendTarget>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _WorkspaceBackendSheet(state: widget.state),
    );
    if (!mounted || backend == null) return;
    if (backend.id != widget.state.activeBackendId) {
      await widget.onSwitchBackend(backend.id);
      if (!mounted) return;
      if (widget.appState.connectionState == BackendConnectionState.connected) {
        await widget.appState.refreshWorkspaces();
        if (!mounted) return;
      }
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) =>
          _WorkspaceSwitcherSheet(appState: widget.appState, backend: backend),
    );
  }

  void _openSettings() {
    // The failed-connection banner's "Settings" button: jump to the
    // Settings tab so the user can fix auth / backend issues from there.
    setState(() => _tab = _kSettingsTabIndex);
  }

  Future<void> _openFilesForTerminalSession(TerminalSession session) async {
    final root = session.workspaceRoot;
    if (root == null || root.isEmpty) return;
    final matching = widget.appState.activeWorkspaces
        .where((w) => w.root == root)
        .toList(growable: false);
    if (matching.isNotEmpty) {
      await widget.appState.activateWorkspace(matching.first.id);
    } else {
      final opened = await widget.appState.openWorkspace(root);
      if (opened == null) return;
    }
    if (!mounted) return;
    setState(() => _tab = _kFilesTabIndex);
  }

  Future<void> _openFilesForBackendTerminalSession(
    BackendTerminalSession ref,
  ) async {
    final root = ref.session.workspaceRoot;
    if (root == null || root.isEmpty) return;
    if (ref.backend.id != widget.state.activeBackendId) {
      await widget.onSwitchBackend(ref.backend.id);
    }
    if (!mounted) return;
    final matching = widget.appState.activeWorkspaces
        .where((w) => w.root == root)
        .toList(growable: false);
    if (matching.isNotEmpty) {
      await widget.appState.activateWorkspace(matching.first.id);
    } else {
      final opened = await widget.appState.openWorkspace(root);
      if (opened == null) return;
    }
    if (!mounted) return;
    setState(() => _tab = _kFilesTabIndex);
  }

  Future<void> _openTerminalFromNotification(OpenTerminalAction action) async {
    final backendId = action.backendId ?? widget.state.activeBackendId;
    if (backendId == null || backendId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No backend is active for this terminal')),
      );
      return;
    }

    var ref = widget.terminalHub.sessionFor(backendId, action.sessionId);
    if (ref == null) {
      await widget.terminalHub.refreshAll();
      if (!mounted) return;
      ref = widget.terminalHub.sessionFor(backendId, action.sessionId);
    }
    if (ref == null) {
      final suffix = action.externalSessionId == null
          ? ''
          : ' (${action.externalSessionId})';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Terminal session not found$suffix')),
      );
      setState(() => _tab = _kTerminalTabIndex);
      return;
    }

    final target = ref;
    widget.terminalHub.focusTerminal(target.backendId, target.sessionId);
    final sessions = widget.terminalHub.sessionsForBackend(target.backendId);
    final index = sessions.indexWhere((s) => s.sessionId == target.sessionId);
    if (!mounted) return;
    setState(() => _tab = _kTerminalTabIndex);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalDetailScreen(
          terminalHub: widget.terminalHub,
          backendId: target.backendId,
          settingsStore: widget.settingsStore,
          sessionId: target.sessionId,
          title: _terminalSessionTitle(
            target.session,
            index >= 0 ? index : sessions.length - 1,
          ),
          onOpenFiles: () => _openFilesForBackendTerminalSession(target),
        ),
      ),
    );
  }

  Widget _buildAppBarTitle(Workspace? currentWorkspace) {
    return switch (_tab) {
      _kFilesTabIndex => _WorkspaceAppBarTitle(
        currentWorkspace: currentWorkspace,
        onTap: _openSwitcher,
      ),
      _kTerminalTabIndex => const _StaticAppBarTitle(
        icon: Icons.terminal_outlined,
        label: 'Terminal',
      ),
      _kPluginsTabIndex => const _StaticAppBarTitle(
        icon: Icons.extension_outlined,
        label: 'Plugins',
      ),
      _kSettingsTabIndex => const _StaticAppBarTitle(
        icon: Icons.settings_outlined,
        label: 'Settings',
      ),
      _ => const _StaticAppBarTitle(
        icon: Icons.folder_outlined,
        label: 'OpenVSMobile',
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.appState.currentWorkspace;
    final connState = widget.appState.connectionState;
    final activeBackend = widget.state.activeBackend;
    final showActiveBackendConnectionBanner =
        _tab == _kFilesTabIndex || _tab == _kPluginsTabIndex;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _buildAppBarTitle(cur),
        actions: [
          _BellIconAction(
            appState: widget.appState,
            settingsStore: widget.settingsStore,
            onOpenTerminal: _openTerminalFromNotification,
          ),
        ],
      ),
      body: Column(
        children: [
          if (showActiveBackendConnectionBanner)
            _ConnectionBanner(
              state: connState,
              backendName: activeBackend == null
                  ? null
                  : _backendDisplayName(activeBackend),
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
                  terminalHub: widget.terminalHub,
                  activeBackendId: widget.state.activeBackendId,
                  settingsStore: widget.settingsStore,
                  onOpenFilesForSession: _openFilesForTerminalSession,
                  onOpenFilesForBackendSession:
                      _openFilesForBackendTerminalSession,
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

class _WorkspaceAppBarTitle extends StatelessWidget {
  final Workspace? currentWorkspace;
  final VoidCallback onTap;

  const _WorkspaceAppBarTitle({
    required this.currentWorkspace,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cur = currentWorkspace;
    return InkWell(
      onTap: onTap,
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
    );
  }
}

class _StaticAppBarTitle extends StatelessWidget {
  final IconData icon;
  final String label;

  const _StaticAppBarTitle({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.md),
          const SizedBox(width: AppSpacing.sm),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

String _backendDisplayName(BackendTarget backend) {
  final name = backend.name.trim();
  if (name.isNotEmpty) return name;
  return '${backend.host}:${backend.port}';
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
  final String? backendName;
  final String? lastError;
  final VoidCallback onOpenSettings;
  const _ConnectionBanner({
    required this.state,
    required this.backendName,
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
    final target = widget.backendName == null || widget.backendName!.isEmpty
        ? ''
        : ' to ${widget.backendName}';
    final (msg, withSpinner) = switch (s) {
      BackendConnectionState.connecting => ('Connecting$target…', true),
      BackendConnectionState.reconnecting => ('Connecting$target…', true),
      BackendConnectionState.waitingForNetwork => (
        widget.backendName == null || widget.backendName!.isEmpty
            ? 'Waiting for network.'
            : 'Waiting for network · ${widget.backendName}.',
        true,
      ),
      BackendConnectionState.disconnected => (
        widget.backendName == null || widget.backendName!.isEmpty
            ? 'Disconnected.'
            : '${widget.backendName} disconnected.',
        false,
      ),
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

class _WorkspaceBackendSheet extends StatelessWidget {
  final AppPersistedState state;

  const _WorkspaceBackendSheet({required this.state});

  @override
  Widget build(BuildContext context) {
    final backends = state.backends.where((b) => b.isComplete).toList();
    final activeId = state.activeBackendId;
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
                'Choose backend',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (backends.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text('No configured backends.'),
              ),
            for (final backend in backends)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(backend.name.isEmpty ? '(unnamed)' : backend.name),
                subtitle: Text(
                  '${backend.host}:${backend.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(
                    fontSize: theme.textTheme.labelSmall?.fontSize,
                  ),
                ),
                trailing: backend.id == activeId
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(backend),
              ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceSwitcherSheet extends StatefulWidget {
  final AppState appState;
  final BackendTarget backend;

  const _WorkspaceSwitcherSheet({
    required this.appState,
    required this.backend,
  });

  @override
  State<_WorkspaceSwitcherSheet> createState() =>
      _WorkspaceSwitcherSheetState();
}

class _WorkspaceSwitcherSheetState extends State<_WorkspaceSwitcherSheet> {
  bool _mutatingRecents = false;

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
      await widget.appState.closeWorkspace(w.id);
    }
  }

  Future<void> _forgetRecent(String root) async {
    if (_mutatingRecents) return;
    setState(() => _mutatingRecents = true);
    await widget.appState.forgetRecentWorkspace(root);
    if (!mounted) return;
    setState(() => _mutatingRecents = false);
  }

  Future<void> _clearRecents() async {
    if (_mutatingRecents) return;
    setState(() => _mutatingRecents = true);
    await widget.appState.clearRecentWorkspaces();
    if (!mounted) return;
    setState(() => _mutatingRecents = false);
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
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
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  const Icon(Icons.dns_outlined, size: AppIconSize.sm),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.backend.name.isEmpty
                              ? '(unnamed)'
                              : widget.backend.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${widget.backend.host}:${widget.backend.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            fontSize: theme.textTheme.labelSmall?.fontSize,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Recent',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (recentsOnly.isNotEmpty)
                    TextButton.icon(
                      onPressed: _mutatingRecents ? null : _clearRecents,
                      icon: const Icon(Icons.clear_all),
                      label: const Text('Clear'),
                    ),
                ],
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
                trailing: IconButton(
                  tooltip: 'Remove recent',
                  icon: const Icon(Icons.close),
                  onPressed: _mutatingRecents ? null : () => _forgetRecent(r),
                ),
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
  final Future<void> Function(OpenTerminalAction action) onOpenTerminal;
  const _BellIconAction({
    required this.appState,
    required this.settingsStore,
    required this.onOpenTerminal,
  });

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
              onOpenTerminal: onOpenTerminal,
            ),
          ),
        );
      },
    );
  }
}

String _terminalSessionTitle(TerminalSession session, int index) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return 'sh · ${index + 1}';
}
