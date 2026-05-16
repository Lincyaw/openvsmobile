// Top-level scaffold: app bar with workspace switcher + gear, bottom nav,
// connection-state banner.

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
          _ConnectionBanner(state: connState, client: widget.appState.client),
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

class _ConnectionBanner extends StatelessWidget {
  final BackendConnectionState state;
  final BackendClient client;
  const _ConnectionBanner({required this.state, required this.client});

  @override
  Widget build(BuildContext context) {
    if (state == BackendConnectionState.connected) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final (msg, color, withSpinner) = switch (state) {
      BackendConnectionState.disconnected => (
          'Disconnected',
          theme.colorScheme.errorContainer,
          false
        ),
      BackendConnectionState.connecting => (
          'Connecting…',
          theme.colorScheme.secondaryContainer,
          true
        ),
      BackendConnectionState.handshaking => (
          'Handshaking…',
          theme.colorScheme.secondaryContainer,
          true
        ),
      BackendConnectionState.failed => (
          'Connection failed: ${client.lastError.value ?? ""}',
          theme.colorScheme.errorContainer,
          false
        ),
      BackendConnectionState.connected => ('', Colors.transparent, false),
    };
    return Container(
      width: double.infinity,
      color: color,
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
          Expanded(child: Text(msg)),
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
