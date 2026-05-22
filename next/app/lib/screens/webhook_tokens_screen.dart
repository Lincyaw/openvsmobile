// Webhook tokens admin screen. Manages publish tokens (the second token
// class from design §4.5 "Auth and publish tokens"): a list view of
// active tokens with a per-row revoke action, plus a "New token" flow
// that returns the freshly-minted `<id>.<secret>` exactly once.
//
// Calls `auth.publishTokens.{list,create,revoke,relabel}` directly on
// BackendClient — this is admin tooling, not user-visible state that
// other widgets re-read, so a TokensModel mirror in AppState would only
// add ceremony.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';

class WebhookTokensScreen extends StatefulWidget {
  final AppState appState;
  const WebhookTokensScreen({super.key, required this.appState});

  @override
  State<WebhookTokensScreen> createState() => _WebhookTokensScreenState();
}

class _TokenRow {
  final String id;
  final String label;
  final String? sourcePrefix;
  final int rateLimitPerMin;
  final int rateLimitPerHour;
  final int createdAt;
  final int? lastUsedAt;

  _TokenRow({
    required this.id,
    required this.label,
    required this.sourcePrefix,
    required this.rateLimitPerMin,
    required this.rateLimitPerHour,
    required this.createdAt,
    required this.lastUsedAt,
  });

  factory _TokenRow.fromJson(Map<String, dynamic> j) => _TokenRow(
    id: j['id'] as String,
    label: j['label'] as String,
    sourcePrefix: j['sourcePrefix'] as String?,
    rateLimitPerMin: j['rateLimitPerMin'] as int,
    rateLimitPerHour: j['rateLimitPerHour'] as int,
    createdAt: j['createdAt'] as int,
    lastUsedAt: j['lastUsedAt'] as int?,
  );
}

class _WebhookTokensScreenState extends State<WebhookTokensScreen> {
  bool _loading = true;
  String? _loadError;
  List<_TokenRow> _tokens = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result =
          await widget.appState.client.call('auth.publishTokens.list')
              as Map<String, dynamic>;
      final items = (result['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_TokenRow.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _tokens = items;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loadError = err.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<_CreatedToken?>(
      MaterialPageRoute<_CreatedToken?>(
        builder: (_) => _CreateTokenScreen(appState: widget.appState),
      ),
    );
    if (created != null) {
      await _refresh();
    }
  }

  Future<void> _revoke(_TokenRow row) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke token?'),
        content: Text(
          'Senders using "${row.label}" (id ${row.id}) will be rejected '
          'immediately. Existing notifications are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.appState.client.call('auth.publishTokens.revoke', {
        'id': row.id,
      });
      await _refresh();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revoke failed: $err')),
      );
    }
  }

  Future<void> _relabel(_TokenRow row) async {
    final controller = TextEditingController(text: row.label);
    final newLabel = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename token'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Label'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newLabel == null || newLabel.trim().isEmpty) return;
    try {
      await widget.appState.client.call('auth.publishTokens.relabel', {
        'id': row.id,
        'label': newLabel.trim(),
      });
      await _refresh();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rename failed: $err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webhook tokens'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        icon: const Icon(Icons.add),
        label: const Text('New token'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: AppSpacing.sm),
            Text('Could not load tokens.\n$_loadError'),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_tokens.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Text(
              'No webhook tokens yet. Tap "New token" to mint one — useful '
              'for posting notifications from CI, monitoring, or other tools '
              'without sharing the auth token in config.json.',
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          InsetSection(
            title: 'Active',
            children: [
              for (final t in _tokens)
                ListTile(
                  key: ValueKey<String>('webhook-token:${t.id}'),
                  title: Text(t.label),
                  subtitle: Text(_describeToken(t)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rename') _relabel(t);
                      if (v == 'revoke') _revoke(t);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'revoke', child: Text('Revoke')),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _describeToken(_TokenRow t) {
    final parts = <String>[];
    parts.add('id ${t.id}');
    parts.add(
      t.sourcePrefix == null
          ? 'any source'
          : 'source prefix: ${t.sourcePrefix}',
    );
    parts.add('${t.rateLimitPerMin}/min · ${t.rateLimitPerHour}/hr');
    parts.add(
      t.lastUsedAt == null
          ? 'never used'
          : 'last used ${_relative(t.lastUsedAt!)}',
    );
    return parts.join(' · ');
  }
}

String _relative(int epochMs) {
  final diff = DateTime.now().millisecondsSinceEpoch - epochMs;
  if (diff < 0) return 'just now';
  if (diff < 60_000) return '${(diff / 1000).round()}s ago';
  if (diff < 3_600_000) return '${(diff / 60_000).round()}m ago';
  if (diff < 86_400_000) return '${(diff / 3_600_000).round()}h ago';
  return '${(diff / 86_400_000).round()}d ago';
}

class _CreatedToken {
  final String id;
  final String secret;
  _CreatedToken(this.id, this.secret);
}

class _CreateTokenScreen extends StatefulWidget {
  final AppState appState;
  const _CreateTokenScreen({required this.appState});

  @override
  State<_CreateTokenScreen> createState() => _CreateTokenScreenState();
}

class _CreateTokenScreenState extends State<_CreateTokenScreen> {
  final _labelCtl = TextEditingController();
  final _prefixCtl = TextEditingController();
  final _perMinCtl = TextEditingController(text: '60');
  final _perHourCtl = TextEditingController(text: '600');
  bool _submitting = false;
  String? _error;
  _CreatedToken? _result;

  @override
  void dispose() {
    _labelCtl.dispose();
    _prefixCtl.dispose();
    _perMinCtl.dispose();
    _perHourCtl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final label = _labelCtl.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Label required');
      return;
    }
    final prefix = _prefixCtl.text.trim();
    final perMin = int.tryParse(_perMinCtl.text.trim());
    final perHour = int.tryParse(_perHourCtl.text.trim());
    if (perMin == null || perMin < 1) {
      setState(() => _error = 'Per-minute rate must be a positive integer');
      return;
    }
    if (perHour == null || perHour < perMin) {
      setState(() => _error = 'Per-hour rate must be ≥ per-minute');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final params = <String, dynamic>{
        'label': label,
        'rateLimitPerMin': perMin,
        'rateLimitPerHour': perHour,
      };
      if (prefix.isNotEmpty) params['sourcePrefix'] = prefix;
      final result =
          await widget.appState.client.call(
                'auth.publishTokens.create',
                params,
              )
              as Map<String, dynamic>;
      final id = (result['record'] as Map<String, dynamic>)['id'] as String;
      final secret = result['secret'] as String;
      if (!mounted) return;
      setState(() {
        _result = _CreatedToken(id, secret);
        _submitting = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New webhook token')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _result == null ? _form() : _success(_result!),
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _labelCtl,
          decoration: const InputDecoration(
            labelText: 'Label',
            helperText: 'Human name, e.g. "github-actions" or "grafana"',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _prefixCtl,
          decoration: const InputDecoration(
            labelText: 'Source prefix (optional)',
            helperText:
                'Limit which "source" values this token can publish. Empty = no restriction.',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _perMinCtl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Per minute'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: TextField(
                controller: _perHourCtl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Per hour'),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Mint token'),
        ),
      ],
    );
  }

  Widget _success(_CreatedToken token) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Token minted. Copy it now — it will not be shown again.',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: SelectableText(
            token.secret,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token.secret));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy token'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Authorization header form:'),
        const SizedBox(height: AppSpacing.xs),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: SelectableText(
            'Authorization: Bearer ${token.secret}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('URL form (for paste-into-webhook fields):'),
        const SizedBox(height: AppSpacing.xs),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: SelectableText(
            'POST /hook/${token.secret}/<source>',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(token),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
