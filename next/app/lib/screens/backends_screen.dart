// Backends management screen: list of saved backends, add / rename / delete,
// and switch the active backend (which triggers a backend client reconnect
// in main.dart).
//
// First-run empty state lives here too — if `backends` is empty we show the
// "Add your first backend" prompt instead of pushing the user into a form
// without context.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings_store.dart';
import 'settings_screen.dart';
import 'ssh_bootstrap_screen.dart';

class BackendsScreen extends StatelessWidget {
  final AppPersistedState state;
  final AppState appState;

  /// Add a brand-new backend. Caller decides whether to make it active.
  final Future<void> Function(BackendTarget target, {required bool makeActive})
      onAdd;

  /// Persist edits (rename / host:port / token) to an existing entry.
  /// If the edited entry is currently active, main.dart will trigger a
  /// reconnect with the new params.
  final Future<void> Function(BackendTarget updated) onUpdate;

  /// Remove an entry. If it was active, main.dart will pick a fallback
  /// (first remaining backend) or land on the empty state.
  final Future<void> Function(String id) onDelete;

  /// Switch the active backend to [id].
  final Future<void> Function(String id) onSwitch;

  const BackendsScreen({
    super.key,
    required this.state,
    required this.appState,
    required this.onAdd,
    required this.onUpdate,
    required this.onDelete,
    required this.onSwitch,
  });

  Future<void> _showAddSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_download),
              title: const Text('Install via SSH'),
              subtitle: const Text(
                'Run install.sh on a remote host and add the result.',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _startSshBootstrap(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Manual entry'),
              subtitle:
                  const Text('Type host, port, and bearer token yourself.'),
              onTap: () {
                Navigator.of(ctx).pop();
                _startManualEntry(context);
              },
            ),
            const ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text('From discovery source'),
              subtitle: Text('Coming soon (k8s clusters).'),
              enabled: false,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startSshBootstrap(BuildContext context) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => SshBootstrapScreen(
          appState: appState,
          onBackendInstalled: (target) async {
            await onAdd(target, makeActive: true);
          },
        ),
      ),
    );
  }

  Future<void> _startManualEntry(BuildContext context) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = BackendTarget(
      id: generateUuidV4(),
      name: '',
      host: '',
      port: 7860,
      token: '',
      origin: BackendOrigin.manual,
      addedAt: now,
    );
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initial: draft,
          isFirstRun: true,
          onSave: (saved) async {
            await onAdd(saved, makeActive: state.backends.isEmpty);
          },
        ),
      ),
    );
  }

  Future<void> _editBackend(
      BuildContext context, BackendTarget existing) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initial: existing,
          onSave: (updated) async {
            await onUpdate(updated);
          },
        ),
      ),
    );
  }

  Future<void> _renameBackend(
      BuildContext context, BackendTarget t) async {
    final ctrl = TextEditingController(text: t.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename backend'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == t.name) return;
    await onUpdate(t.copyWith(name: newName));
  }

  Future<void> _confirmDelete(
      BuildContext context, BackendTarget t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${t.name}?'),
        content: Text(
          'This forgets ${t.host}:${t.port} on this device. The backend '
          'itself keeps running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await onDelete(t.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backends'),
        actions: [
          IconButton(
            tooltip: 'Add backend',
            icon: const Icon(Icons.add),
            onPressed: () => _showAddSheet(context),
          ),
        ],
      ),
      body: state.backends.isEmpty
          ? _EmptyState(onAdd: () => _showAddSheet(context))
          : ListView.separated(
              itemCount: state.backends.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final b = state.backends[i];
                final isActive = b.id == state.activeBackendId;
                return _BackendTile(
                  target: b,
                  isActive: isActive,
                  onTap: isActive ? null : () => onSwitch(b.id),
                  onRename: () => _renameBackend(context, b),
                  onEdit: () => _editBackend(context, b),
                  onDelete: () => _confirmDelete(context, b),
                );
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No backends yet',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Add one to connect. You can install a backend via SSH or '
              'type connection details by hand.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add your first backend'),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendTile extends StatelessWidget {
  final BackendTarget target;
  final bool isActive;
  final VoidCallback? onTap;
  final VoidCallback onRename;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _BackendTile({
    required this.target,
    required this.isActive,
    required this.onTap,
    required this.onRename,
    required this.onEdit,
    required this.onDelete,
  });

  String _originLabel() => switch (target.origin) {
        BackendOrigin.manual => 'manual',
        BackendOrigin.sshInstall => 'ssh-install',
        BackendOrigin.discovery => 'discovery',
      };

  String _statusLabel() {
    if (isActive) return 'active';
    final ts = target.lastConnectedAt;
    if (ts == null) return 'not yet connected';
    final delta = DateTime.now().millisecondsSinceEpoch - ts;
    return 'last used ${_humanizeDuration(delta)} ago';
  }

  String _humanizeDuration(int millis) {
    final s = millis ~/ 1000;
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    if (h < 24) return '${h}h';
    final d = h ~/ 24;
    return '${d}d';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle =
        '${target.host}:${target.port}  ·  ${_originLabel()}  ·  ${_statusLabel()}';
    return ListTile(
      leading: Icon(
        isActive ? Icons.circle : Icons.circle_outlined,
        size: 14,
        color: isActive
            ? theme.colorScheme.primary
            : theme.colorScheme.outline,
      ),
      title: Text(target.name.isEmpty ? '(unnamed)' : target.name),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'rename':
              onRename();
            case 'edit':
              onEdit();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'edit', child: Text('Edit details')),
          PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
      onTap: onTap,
    );
  }
}
