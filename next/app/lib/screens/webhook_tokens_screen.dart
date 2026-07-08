// Webhook tokens admin screen. Manages publish tokens (design section 4.5) for
// agent/CI notification senders. Server-derived token state lives in
// AppState.publishTokens; this screen only owns transient form state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../state/publish_tokens_model.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';

class WebhookTokensScreen extends StatefulWidget {
  final AppState appState;
  const WebhookTokensScreen({super.key, required this.appState});

  @override
  State<WebhookTokensScreen> createState() => _WebhookTokensScreenState();
}

class _WebhookTokensScreenState extends State<WebhookTokensScreen> {
  bool _initialRefreshScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleInitialRefresh();
  }

  @override
  void didUpdateWidget(covariant WebhookTokensScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) _scheduleInitialRefresh();
  }

  void _scheduleInitialRefresh() {
    if (_initialRefreshScheduled) return;
    final tokens = widget.appState.publishTokens;
    if (widget.appState.connectionState != BackendConnectionState.connected ||
        tokens.loaded ||
        tokens.loading) {
      return;
    }
    _initialRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialRefreshScheduled = false;
      if (!mounted) return;
      final appState = widget.appState;
      final tokens = appState.publishTokens;
      if (appState.connectionState != BackendConnectionState.connected ||
          tokens.loaded ||
          tokens.loading) {
        return;
      }
      unawaited(tokens.refresh());
    });
  }

  Future<void> _refresh() async {
    if (widget.appState.connectionState != BackendConnectionState.connected) {
      return;
    }
    await widget.appState.publishTokens.refresh();
  }

  Future<void> _openCreate() async {
    if (widget.appState.connectionState != BackendConnectionState.connected) {
      return;
    }
    await Navigator.of(context).push<CreatedPublishToken?>(
      MaterialPageRoute<CreatedPublishToken?>(
        builder: (_) => _CreateTokenScreen(appState: widget.appState),
      ),
    );
  }

  Future<void> _revoke(PublishTokenRecord row) async {
    final messenger = ScaffoldMessenger.of(context);
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
      await widget.appState.publishTokens.revoke(row.id);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Token revoked')));
    } catch (err) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Revoke failed: $err')));
    }
  }

  Future<void> _relabel(PublishTokenRecord row) async {
    final controller = TextEditingController(text: row.label);
    final messenger = ScaffoldMessenger.of(context);
    try {
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
      final label = newLabel?.trim();
      if (label == null || label.isEmpty || label == row.label) return;
      await widget.appState.publishTokens.relabel(row.id, label);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Token renamed')));
    } catch (err) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Rename failed: $err')));
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        _scheduleInitialRefresh();
        final connected =
            widget.appState.connectionState == BackendConnectionState.connected;
        final tokens = widget.appState.publishTokens;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Webhook tokens'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: connected && !tokens.loading ? _refresh : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: connected ? _openCreate : null,
            icon: const Icon(Icons.add),
            label: const Text('New token'),
          ),
          body: _buildBody(tokens, connected: connected),
        );
      },
    );
  }

  Widget _buildBody(PublishTokensModel tokens, {required bool connected}) {
    if (!connected && !tokens.loaded) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48),
              SizedBox(height: AppSpacing.sm),
              Text(
                'Backend offline',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: AppSpacing.xs),
              Text(
                'Connect to a backend to manage webhook tokens.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (tokens.loading && !tokens.loaded) {
      return const Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: kSpinnerSm,
              height: kSpinnerSm,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: AppSpacing.sm),
            Text('Loading webhook tokens...'),
          ],
        ),
      );
    }
    if (tokens.error != null && !tokens.loaded) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: AppSpacing.sm),
            Text('Could not load tokens.\n${tokens.error}'),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (tokens.items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: const [
          InsetSection(
            title: 'No tokens',
            children: [
              ListTile(
                leading: Icon(Icons.key_outlined),
                title: Text('Create a publish token'),
                subtitle: Text(
                  'Use publish tokens for mobile-notify, Claude/Codex hooks, '
                  'CI, and monitoring senders without sharing the backend auth token.',
                ),
              ),
            ],
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
              for (final t in tokens.items)
                ListTile(
                  key: ValueKey<String>('webhook-token:${t.id}'),
                  title: Text(t.label),
                  subtitle: Text(_describeToken(t)),
                  trailing: PopupMenuButton<String>(
                    enabled: connected,
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

  String _describeToken(PublishTokenRecord t) {
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
  CreatedPublishToken? _result;

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
      setState(() => _error = 'Per-hour rate must be >= per-minute');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await widget.appState.publishTokens.create(
        label: label,
        sourcePrefix: prefix.isEmpty ? null : prefix,
        rateLimitPerMin: perMin,
        rateLimitPerHour: perHour,
      );
      if (!mounted) return;
      setState(() {
        _result = created;
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
            helperText: 'Human name, e.g. "claude-code" or "github-actions"',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _prefixCtl,
          decoration: const InputDecoration(
            labelText: 'Source prefix (optional)',
            helperText:
                'Limit allowed source values. Empty means no restriction.',
            helperMaxLines: 2,
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
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: kSpinnerSm,
                      height: kSpinnerSm,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Text('Minting...'),
                  ],
                )
              : const Text('Mint token'),
        ),
      ],
    );
  }

  Widget _success(CreatedPublishToken token) {
    final agentHookSnippets = _agentHookSnippets(token);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Token minted. Copy it now; it will not be shown again.',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.md),
        _CodeBlock(text: token.secret, copyLabel: 'Copy token'),
        const SizedBox(height: AppSpacing.sm),
        FilledButton.icon(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            await Clipboard.setData(ClipboardData(text: token.secret));
            if (!mounted) return;
            messenger.showSnackBar(const SnackBar(content: Text('Copied')));
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy token'),
        ),
        const SizedBox(height: AppSpacing.lg),
        const Text('Authorization header form:'),
        const SizedBox(height: AppSpacing.xs),
        _CodeBlock(
          text: 'Authorization: Bearer ${token.secret}',
          copyLabel: 'Copy authorization header',
        ),
        const SizedBox(height: AppSpacing.md),
        const Text('Paste-friendly hook URL form:'),
        const SizedBox(height: AppSpacing.xs),
        _CodeBlock(
          text: 'POST /hook/${token.secret}/<source>',
          copyLabel: 'Copy hook URL form',
        ),
        const SizedBox(height: AppSpacing.md),
        const Text('mobile-notify CLI:'),
        const SizedBox(height: AppSpacing.xs),
        _CodeBlock(
          text:
              'mobile-notify --token ${token.secret} --source ${token.record.sourcePrefix ?? '<source>'} --title "Task finished"',
          copyLabel: 'Copy mobile-notify command',
        ),
        for (final snippet in agentHookSnippets) ...[
          const SizedBox(height: AppSpacing.md),
          Text(snippet.title),
          const SizedBox(height: AppSpacing.xs),
          _CodeBlock(
            text:
                'mobile-notify --token ${token.secret} --source ${snippet.source} --from-agent-hook',
            copyLabel: snippet.copyLabel,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(token),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _AgentHookSnippet {
  final String title;
  final String source;
  final String copyLabel;

  const _AgentHookSnippet({
    required this.title,
    required this.source,
    required this.copyLabel,
  });
}

List<_AgentHookSnippet> _agentHookSnippets(CreatedPublishToken token) {
  final prefix = token.record.sourcePrefix?.trim();
  if (prefix != null && prefix.isNotEmpty) {
    return [
      _AgentHookSnippet(
        title: 'Agent hook CLI:',
        source: prefix,
        copyLabel: 'Copy agent hook command',
      ),
    ];
  }
  return const [
    _AgentHookSnippet(
      title: 'Claude Code hook CLI:',
      source: 'claude-code',
      copyLabel: 'Copy Claude Code hook command',
    ),
    _AgentHookSnippet(
      title: 'Codex hook CLI:',
      source: 'codex',
      copyLabel: 'Copy Codex hook command',
    ),
  ];
}

class _CodeBlock extends StatelessWidget {
  final String text;
  final String copyLabel;

  const _CodeBlock({required this.text, required this.copyLabel});

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: SelectableText(text, style: AppText.monoCaption(context)),
            ),
          ),
          IconButton(
            tooltip: copyLabel,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: AppIconSize.sm),
            onPressed: () => unawaited(_copy(context)),
          ),
        ],
      ),
    );
  }
}
