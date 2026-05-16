// Top-level scaffold: app bar with workspace switcher + gear, bottom nav,
// connection-state banner.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../settings_store.dart';
import 'files_tab.dart';
import 'settings_screen.dart';
import 'terminal_tab.dart';
import 'workspace_picker.dart';

class HomeShell extends StatefulWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  final Settings currentSettings;
  final Future<void> Function(Settings) onSettingsSaved;
  const HomeShell({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.currentSettings,
    required this.onSettingsSaved,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_rebuild);
    widget.appState.client.state.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.appState.removeListener(_rebuild);
    widget.appState.client.state.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  Future<void> _openSwitcher() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _WorkspaceSwitcherSheet(appState: widget.appState),
    );
  }

  Future<void> _openSettings() async {
    final fresh = await Navigator.of(context).push<Settings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initial: widget.currentSettings,
          onSave: widget.onSettingsSaved,
        ),
      ),
    );
    if (fresh != null && mounted) {
      // Caller's onSettingsSaved already persisted + triggered reconnect;
      // nothing more to do.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.appState.currentWorkspace;
    final connState = widget.appState.client.state.value;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _openSwitcher,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  cur == null ? Icons.folder_off_outlined : Icons.folder_open,
                  size: 20,
                ),
                const SizedBox(width: 8),
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
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            state: connState,
            client: widget.appState.client,
            onOpenSettings: _openSettings,
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                FilesTab(appState: widget.appState),
                TerminalTab(appState: widget.appState),
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
  final BackendClient client;
  final VoidCallback onOpenSettings;
  const _ConnectionBanner({
    required this.state,
    required this.client,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.client.lastError.value ?? 'Connection failed.',
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
      BackendConnectionState.waitingForNetwork => ('Waiting for network.', true),
      BackendConnectionState.disconnected => ('Disconnected.', false),
      BackendConnectionState.connected => ('', false),
      BackendConnectionState.failed => ('', false), // handled above
    };
    if (msg.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (withSpinner)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (withSpinner) const SizedBox(width: 8),
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

  Future<void> _confirmClose(
      BuildContext context, Workspace w) async {
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
    final recentsOnly =
        appState.recentRoots.where((r) => !activeRoots.contains(r)).toList();
    final cur = appState.currentWorkspace;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Open workspaces',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (active.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                    ? const Icon(Icons.check, color: Colors.green)
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
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Recent',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (recentsOnly.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'No other recents yet.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            for (final r in recentsOnly)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(r.split('/').isNotEmpty
                    ? r.split('/').lastWhere((s) => s.isNotEmpty,
                        orElse: () => r)
                    : r),
                subtitle: Text(
                  r,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
              subtitle:
                  const Text('Pick a folder by drilling in step-by-step'),
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
}
