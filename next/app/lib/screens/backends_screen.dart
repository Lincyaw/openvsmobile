// Backends management screen: list of saved backends, add / rename / delete,
// and choose which backend powers Files / Plugins / workspace state. Terminal
// sessions are aggregated separately by TerminalHub, which auto-connects every
// complete saved backend.
//
// First-run empty state lives here too — if `backends` is empty we show the
// "Add your first backend" prompt instead of pushing the user into a form
// without context.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings_store.dart';
import '../version.dart';
import 'backend_editor_screen.dart';
import 'backend_pairing_scan_screen.dart';
import 'lan_discovery_sheet.dart';
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

  /// Make [id] the Files / Plugins / workspace backend.
  final Future<void> Function(String id) onSwitch;

  /// Save the current backend list to a user-chosen document.
  final Future<bool> Function() onExport;

  /// Load a user-chosen backend backup. Returns the imported backend count,
  /// or null if the picker was canceled.
  final Future<int?> Function() onImport;

  const BackendsScreen({
    super.key,
    required this.state,
    required this.appState,
    required this.onAdd,
    required this.onUpdate,
    required this.onDelete,
    required this.onSwitch,
    required this.onExport,
    required this.onImport,
  });

  Future<void> _showAddSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Scan QR'),
                subtitle: const Text(
                  'Read the token and ticket printed by install.sh.',
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _startQrScan(context);
                },
              ),
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
                title: const Text('WebSocket backend'),
                subtitle: const Text(
                  'Type host, port, and bearer token yourself.',
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _startManualEntry(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('Iroh ticket'),
                subtitle: const Text('Paste endpoint ticket and bearer token.'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _startIrohEntry(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.wifi_find),
                title: const Text('Scan LAN'),
                subtitle: const Text(
                  'Discover backends on your local network.',
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _startLanDiscovery(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startQrScan(BuildContext context) async {
    final navigator = Navigator.of(context);
    final target = await navigator.push<BackendTarget>(
      MaterialPageRoute(builder: (_) => const BackendPairingScanScreen()),
    );
    if (target == null) return;
    await onAdd(target, makeActive: true);
    if (!context.mounted) return;
    final name = target.name.isEmpty
        ? _backendEndpointLabel(target)
        : target.name;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Added $name')));
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

  Future<void> _startLanDiscovery(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => LanDiscoverySheet(onAdd: onAdd),
    );
  }

  Future<void> _startManualEntry(BuildContext context) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = BackendTarget(
      id: generateUuidV4(),
      name: '',
      host: '',
      port: kDefaultBackendPort,
      token: '',
      origin: BackendOrigin.manual,
      addedAt: now,
    );
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => BackendEditorScreen(
          initial: draft,
          isFirstRun: true,
          onSave: (saved) async {
            await onAdd(saved, makeActive: state.backends.isEmpty);
          },
        ),
      ),
    );
  }

  Future<void> _startIrohEntry(BuildContext context) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = BackendTarget(
      id: generateUuidV4(),
      name: '',
      host: '',
      port: 0,
      token: '',
      transport: BackendTransport.iroh,
      irohAlpn: 'openvsmobile.rpc.v1',
      origin: BackendOrigin.manual,
      addedAt: now,
    );
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => BackendEditorScreen(
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
    BuildContext context,
    BackendTarget existing,
  ) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => BackendEditorScreen(
          initial: existing,
          onSave: (updated) async {
            await onUpdate(updated);
          },
        ),
      ),
    );
  }

  Future<void> _renameBackend(BuildContext context, BackendTarget t) async {
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

  Future<void> _confirmDelete(BuildContext context, BackendTarget t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${t.name}?'),
        content: Text(
          'This forgets ${_backendEndpointLabel(t)} on this device. The '
          'backend itself keeps running.',
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

  Future<void> _exportBackup(BuildContext context) async {
    if (state.backends.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No backends to export')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export backend backup'),
        content: const Text(
          'The backup includes backend bearer tokens. Save it somewhere '
          'private.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final saved = await onExport();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(saved ? 'Backend backup saved' : 'Export canceled'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    if (state.backends.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import backend backup'),
          content: Text(
            'This replaces ${state.backends.length} saved '
            '${state.backends.length == 1 ? 'backend' : 'backends'} on this '
            'device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    try {
      final count = await onImport();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count == null
                ? 'Import canceled'
                : 'Imported $count ${count == 1 ? 'backend' : 'backends'}',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
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
          PopupMenuButton<_BackendsAction>(
            tooltip: 'Backend backup',
            onSelected: (action) {
              switch (action) {
                case _BackendsAction.export:
                  unawaited(_exportBackup(context));
                case _BackendsAction.import:
                  unawaited(_importBackup(context));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _BackendsAction.export,
                child: Text('Export backup'),
              ),
              PopupMenuItem(
                value: _BackendsAction.import,
                child: Text('Import backup'),
              ),
            ],
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
                  onUseForWorkspace: isActive ? null : () => onSwitch(b.id),
                  onRename: () => _renameBackend(context, b),
                  onEdit: () => _editBackend(context, b),
                  onDelete: () => _confirmDelete(context, b),
                );
              },
            ),
    );
  }
}

enum _BackendsAction { export, import }

String _backendEndpointLabel(BackendTarget target) =>
    switch (target.transport) {
      BackendTransport.websocket => '${target.host}:${target.port}',
      BackendTransport.iroh => 'iroh:${_shortIrohLabel(target)}',
    };

String _shortIrohLabel(BackendTarget target) {
  final raw = (target.irohEndpointId ?? target.irohTicket ?? '').trim();
  if (raw.isEmpty) return 'ticket';
  return raw.substring(0, raw.length < 12 ? raw.length : 12);
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
            Text('No backends yet', style: theme.textTheme.titleLarge),
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
  final VoidCallback? onUseForWorkspace;
  final VoidCallback onRename;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _BackendTile({
    required this.target,
    required this.isActive,
    required this.onUseForWorkspace,
    required this.onRename,
    required this.onEdit,
    required this.onDelete,
  });

  String _originLabel() => switch (target.origin) {
    BackendOrigin.manual => 'manual',
    BackendOrigin.sshInstall => 'ssh-install',
    BackendOrigin.discovery => 'discovery',
    BackendOrigin.pairingQr => 'qr-pairing',
  };

  String _statusLabel() {
    if (isActive) return 'Files/Plugins target · Terminal auto-connects';
    return 'Terminal auto-connects';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle =
        '${_backendEndpointLabel(target)} · ${_originLabel()}\n'
        '${_statusLabel()}';
    return ListTile(
      leading: Icon(switch (target.transport) {
        BackendTransport.websocket => Icons.dns_outlined,
        BackendTransport.iroh => Icons.hub_outlined,
      }, color: isActive ? scheme.primary : scheme.onSurfaceVariant),
      title: Row(
        children: [
          Expanded(
            child: Text(
              target.name.isEmpty ? '(unnamed)' : target.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 8),
            _ScopeChip(color: scheme.primary),
          ],
        ],
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'use':
              onUseForWorkspace?.call();
            case 'rename':
              onRename();
            case 'edit':
              onEdit();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (_) => [
          if (onUseForWorkspace != null)
            const PopupMenuItem(
              value: 'use',
              child: Text('Use for Files/Plugins'),
            ),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'edit', child: Text('Edit details')),
          const PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  final Color color;

  const _ScopeChip({required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          'Files',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}
