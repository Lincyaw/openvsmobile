// LAN discovery bottom sheet: scans for `_openvsmobile._tcp` services,
// lists results, and on tap pre-fills the backend editor with host+port.
// The user still enters the bearer token manually — it is never broadcast.

import 'package:flutter/material.dart';

import '../services/mdns_discovery.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';
import 'backend_editor_screen.dart';

typedef BackendDiscoveryScanner = Future<List<DiscoveredBackend>> Function();

class LanDiscoverySheet extends StatefulWidget {
  final void Function(BackendTarget target, {required bool makeActive}) onAdd;
  final BackendDiscoveryScanner? scanBackends;

  const LanDiscoverySheet({super.key, required this.onAdd, this.scanBackends});

  @override
  State<LanDiscoverySheet> createState() => _LanDiscoverySheetState();
}

class _LanDiscoverySheetState extends State<LanDiscoverySheet> {
  Future<List<DiscoveredBackend>>? _future;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() {
    setState(() {
      _scanning = true;
      _future = (widget.scanBackends ?? MdnsDiscovery().scan)
          .call()
          .then((list) {
            if (mounted) setState(() => _scanning = false);
            return list;
          })
          .catchError((_) {
            if (mounted) setState(() => _scanning = false);
            return <DiscoveredBackend>[];
          });
    });
  }

  Future<void> _onTap(DiscoveredBackend d) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = BackendTarget(
      id: generateUuidV4(),
      name: d.name,
      host: d.host,
      port: d.port,
      token: '',
      origin: BackendOrigin.discovery,
      originRef: '${d.host}:${d.port}',
      addedAt: now,
    );
    if (!mounted) return;
    // Pop the sheet, then push the editor pre-filled.
    Navigator.of(context).pop();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BackendEditorScreen(
          initial: draft,
          onSave: (saved) async {
            widget.onAdd(saved, makeActive: true);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Discovered backends',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (_scanning)
                    const SizedBox(
                      width: kSpinnerSm,
                      height: kSpinnerSm,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      onPressed: _startScan,
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Scan again',
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: FutureBuilder<List<DiscoveredBackend>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done &&
                      !_scanning) {
                    return const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Scan failed: ${snap.error}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  final list = snap.data ?? const <DiscoveredBackend>[];
                  if (list.isEmpty && !_scanning) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.wifi_find_outlined,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'No backends found',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Make sure your backend is running and '
                            'connected to the same WiFi network.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final d = list[i];
                      return ListTile(
                        leading: const Icon(Icons.computer_outlined),
                        title: Text(d.name),
                        subtitle: Text(
                          '${d.host}:${d.port}  ·  v${d.version}',
                          style: AppText.monoCaption(context),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onTap(d),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
