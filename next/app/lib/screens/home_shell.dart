// Top-level scaffold: tab-aware app bar + bell, bottom nav, connection-state
// banner. Backend management lives in the Settings tab.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../notification.dart';
import '../services/connection_diagnostics.dart';
import '../services/eyes_free_trace.dart';
import '../services/terminal_notification_resolver.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../state/terminal_hub.dart';
import '../ui/app_tokens.dart';
import 'eyes_free_tab.dart';
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
const int _kVoiceTabIndex = 2;
const int _kPluginsTabIndex = 3;
const int _kSettingsTabIndex = 4;

class _HomeShellState extends State<HomeShell> {
  int _tab = _kFilesTabIndex;
  int _lastNonVoiceTab = _kFilesTabIndex;
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
    EyesFreeTrace.log('home', 'open settings tab from=$_tab');
    setState(() {
      _tab = _kSettingsTabIndex;
      _lastNonVoiceTab = _kSettingsTabIndex;
    });
  }

  void _selectTab(int index) {
    EyesFreeTrace.log('home', 'select tab from=$_tab to=$index');
    setState(() {
      _tab = index;
      if (index != _kVoiceTabIndex) {
        _lastNonVoiceTab = index;
      }
    });
  }

  void _exitVoiceTab() {
    EyesFreeTrace.log('home', 'exit voice tab to=$_lastNonVoiceTab');
    setState(() => _tab = _lastNonVoiceTab);
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
    setState(() {
      _tab = _kFilesTabIndex;
      _lastNonVoiceTab = _kFilesTabIndex;
    });
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
    setState(() {
      _tab = _kFilesTabIndex;
      _lastNonVoiceTab = _kFilesTabIndex;
    });
  }

  Future<void> _openTerminalFromNotification(OpenTerminalAction action) async {
    final ref = await resolveTerminalForNotification(
      terminalHub: widget.terminalHub,
      action: action,
      activeBackendId: widget.state.activeBackendId,
      isMounted: () => mounted,
    );
    if (!mounted) return;
    if (ref == null) {
      final backendId = action.backendId ?? widget.state.activeBackendId;
      if (backendId == null || backendId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No backend is active for this terminal'),
          ),
        );
        return;
      }
      final suffix = action.externalSessionId == null
          ? ''
          : ' (${action.externalSessionId})';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Terminal session not found$suffix')),
      );
      setState(() {
        _tab = _kTerminalTabIndex;
        _lastNonVoiceTab = _kTerminalTabIndex;
      });
      return;
    }

    final target = ref;
    widget.terminalHub.focusTerminal(target.backendId, target.sessionId);
    final sessions = widget.terminalHub.sessionsForBackend(target.backendId);
    final index = sessions.indexWhere((s) => s.sessionId == target.sessionId);
    if (!mounted) return;
    setState(() {
      _tab = _kTerminalTabIndex;
      _lastNonVoiceTab = _kTerminalTabIndex;
    });
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
      _kVoiceTabIndex => const _StaticAppBarTitle(
        icon: Icons.record_voice_over_outlined,
        label: 'Voice',
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
        _tab == _kFilesTabIndex ||
        _tab == _kVoiceTabIndex ||
        _tab == _kPluginsTabIndex;
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
                EyesFreeTab(
                  appState: widget.appState,
                  isActive: _tab == _kVoiceTabIndex,
                  onExit: _exitVoiceTab,
                ),
                PluginsTab(appState: widget.appState),
                SettingsTab(
                  appState: widget.appState,
                  settingsStore: widget.settingsStore,
                  backendState: widget.state,
                  systemTrayController: widget.systemTrayController,
                  isActive: _tab == _kSettingsTabIndex,
                  onOpenBackends: widget.onOpenBackends,
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
        onDestinationSelected: _selectTab,
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
            icon: Icon(Icons.record_voice_over_outlined),
            selectedIcon: Icon(Icons.record_voice_over),
            label: 'Voice',
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
    final copy = connectionStatusCopy(
      state: s,
      backendName: widget.backendName,
      lastError: widget.lastError,
    );
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    copy.title,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (copy.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      copy.detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: theme.textTheme.bodySmall?.fontSize,
                      ),
                    ),
                  ],
                ],
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
    if (s == BackendConnectionState.connected) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDensity.bannerHPad,
        vertical: AppDensity.bannerVPad,
      ),
      child: Row(
        children: [
          if (copy.loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (copy.loading) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Semantics(
              label: copy.semanticsLabel,
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.title,
                      style: TextStyle(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    if (copy.detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        copy.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.colorScheme.onSecondaryContainer,
                          fontSize: theme.textTheme.bodySmall?.fontSize,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
    final attention = appState.notifications.attentionCount;
    final connected =
        appState.connectionState == BackendConnectionState.connected;
    if (!connected && unread == 0) return const SizedBox.shrink();
    void openCenter() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NotificationCenterScreen(
            appState: appState,
            settingsStore: settingsStore,
            onOpenTerminal: onOpenTerminal,
          ),
        ),
      );
    }

    return Semantics(
      label: _notificationBellSemanticsLabel(
        unreadCount: unread,
        attentionCount: attention,
      ),
      button: true,
      onTap: openCenter,
      child: ExcludeSemantics(
        child: IconButton(
          tooltip: 'Notifications',
          icon: _notificationBellIcon(
            unreadCount: unread,
            attentionCount: attention,
          ),
          onPressed: openCenter,
        ),
      ),
    );
  }
}

Widget _notificationBellIcon({
  required int unreadCount,
  required int attentionCount,
}) {
  const icon = Icon(Icons.notifications_outlined);
  if (attentionCount > 0) {
    return Badge(label: Text(_compactBadgeCount(attentionCount)), child: icon);
  }
  if (unreadCount > 0) {
    return const Badge(child: icon);
  }
  return icon;
}

String _compactBadgeCount(int count) => count > 9 ? '9+' : count.toString();

String _notificationBellSemanticsLabel({
  required int unreadCount,
  required int attentionCount,
}) {
  if (attentionCount > 0) {
    return attentionCount == 1
        ? 'Notifications, 1 item needs attention'
        : 'Notifications, $attentionCount items need attention';
  }
  if (unreadCount > 0) return 'Notifications, unread items';
  return 'Notifications';
}

String _terminalSessionTitle(TerminalSession session, int index) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return 'sh · ${index + 1}';
}
