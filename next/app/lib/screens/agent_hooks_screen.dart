// Agent completion hook settings. This is the phone-side control surface for
// the backend-bundled Claude/Codex Stop-hook installer.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';
import 'webhook_tokens_screen.dart';

class AgentHooksScreen extends StatefulWidget {
  final AppState appState;

  const AgentHooksScreen({super.key, required this.appState});

  @override
  State<AgentHooksScreen> createState() => _AgentHooksScreenState();
}

class _AgentHooksScreenState extends State<AgentHooksScreen> {
  bool _hookStatusRefreshScheduled = false;
  bool _tokenRefreshScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleHookStatusRefresh();
    _scheduleTokenRefresh();
  }

  @override
  void didUpdateWidget(covariant AgentHooksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      _scheduleHookStatusRefresh();
      _scheduleTokenRefresh();
    }
  }

  void _scheduleHookStatusRefresh() {
    if (_hookStatusRefreshScheduled) return;
    _hookStatusRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hookStatusRefreshScheduled = false;
      if (!mounted) return;
      final appState = widget.appState;
      if (appState.connectionState != BackendConnectionState.connected) {
        return;
      }
      final hooks = appState.agentHooks;
      if (hooks.lastResult != null ||
          hooks.checking ||
          hooks.installing ||
          hooks.statusUnsupported) {
        return;
      }
      unawaited(hooks.refreshStatus());
    });
  }

  void _scheduleTokenRefresh() {
    if (_tokenRefreshScheduled) return;
    _tokenRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tokenRefreshScheduled = false;
      if (!mounted) return;
      final appState = widget.appState;
      if (appState.connectionState != BackendConnectionState.connected) {
        return;
      }
      final tokens = appState.publishTokens;
      if (tokens.loaded || tokens.loading) return;
      unawaited(tokens.refresh());
    });
  }

  Future<void> _install(BuildContext context) async {
    final hooks = widget.appState.agentHooks;
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install agent hooks?'),
        content: const Text(
          'This updates Claude Code and Codex user config on the backend host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Install hooks'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    try {
      final result = await hooks.install();
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.ok ? 'Hook scan complete' : 'Hook scan failed'),
        ),
      );
    } on BackendRpcException catch (e) {
      if (!context.mounted) return;
      if (e.code == -32601) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Backend is too old for agent hook setup'),
          ),
        );
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text('Hook scan failed: $e')));
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Hook scan failed: $e')));
    }
  }

  void _openWebhookTokens(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebhookTokensScreen(appState: widget.appState),
      ),
    );
  }

  VoidCallback? _summaryAction(BuildContext context, AppState appState) {
    if (appState.connectionState != BackendConnectionState.connected) {
      return null;
    }
    final hooks = appState.agentHooks;
    if (hooks.checking || hooks.installing) return null;
    if (hooks.statusUnsupported) return null;
    final result = hooks.lastResult;
    if (result == null ||
        !result.ok ||
        _agentsNeedingHookWork(result).isNotEmpty) {
      return () => unawaited(_install(context));
    }
    if (appState.publishTokens.loaded && appState.publishTokens.items.isEmpty) {
      return () => _openWebhookTokens(context);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final appState = widget.appState;
    final hooks = appState.agentHooks;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final connected =
            appState.connectionState == BackendConnectionState.connected;
        final canInstallHooks =
            connected && !hooks.installing && !hooks.statusUnsupported;
        _scheduleHookStatusRefresh();
        _scheduleTokenRefresh();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Agent hooks'),
            actions: [
              IconButton(
                tooltip: 'Refresh hook status',
                icon: const Icon(Icons.refresh),
                onPressed: connected && !hooks.checking && !hooks.installing
                    ? () => unawaited(hooks.refreshStatus())
                    : null,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              _AgentHooksSummary(
                connected: connected,
                checking: hooks.checking,
                installing: hooks.installing,
                result: hooks.lastResult,
                statusUnsupported: hooks.statusUnsupported,
                tokenLabel: _credentialChipLabel(appState),
                actionLabel: _summaryActionLabel(appState),
                onAction: _summaryAction(context, appState),
              ),
              InsetSection(
                title: 'Agent notification setup',
                children: [
                  ListTile(
                    key: const ValueKey<String>('agent-hooks-install-tile'),
                    leading: _SetupIcon(
                      connected: connected,
                      checking: hooks.checking,
                      installing: hooks.installing,
                      result: hooks.lastResult,
                      statusUnsupported: hooks.statusUnsupported,
                    ),
                    title: Text(
                      _installTitle(
                        connected: connected,
                        checking: hooks.checking,
                        installing: hooks.installing,
                        result: hooks.lastResult,
                        statusUnsupported: hooks.statusUnsupported,
                      ),
                    ),
                    subtitle: Text(
                      _installSubtitle(
                        connected: connected,
                        checking: hooks.checking,
                        installing: hooks.installing,
                        result: hooks.lastResult,
                        statusUnsupported: hooks.statusUnsupported,
                      ),
                    ),
                    trailing: hooks.statusUnsupported
                        ? const Icon(Icons.info_outline)
                        : const Icon(Icons.chevron_right),
                    enabled: connected && !hooks.installing,
                    onTap: canInstallHooks
                        ? () => unawaited(_install(context))
                        : null,
                  ),
                  ListTile(
                    key: const ValueKey<String>('agent-hooks-token-tile'),
                    leading: Icon(_credentialIcon(appState)),
                    title: const Text('Webhook tokens'),
                    subtitle: Text(_credentialSummary(appState)),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: connected,
                    onTap: connected ? () => _openWebhookTokens(context) : null,
                  ),
                ],
              ),
              if (hooks.lastResult != null) _ResultSection(hooks.lastResult!),
              if (hooks.error != null)
                InsetSection(
                  title: 'Error',
                  children: [
                    ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('Last scan failed'),
                      subtitle: Text(hooks.error!),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SetupIcon extends StatelessWidget {
  final bool connected;
  final bool checking;
  final bool installing;
  final AgentHookInstallResult? result;
  final bool statusUnsupported;

  const _SetupIcon({
    required this.connected,
    required this.checking,
    required this.installing,
    required this.result,
    required this.statusUnsupported,
  });

  @override
  Widget build(BuildContext context) {
    if (checking || installing) {
      return const SizedBox(
        width: kSpinnerSm,
        height: kSpinnerSm,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (!connected) return const Icon(Icons.cloud_off_outlined);
    if (statusUnsupported) return const Icon(Icons.system_update_outlined);
    final scan = result;
    if (scan == null) return const Icon(Icons.notifications_active_outlined);
    if (!scan.ok) return const Icon(Icons.error_outline);
    final missing = _missingAgents(scan);
    if (_agentsNeedingHookWork(scan).isNotEmpty ||
        missing.length == scan.statuses.length) {
      return const Icon(Icons.info_outline);
    }
    return const Icon(Icons.task_alt);
  }
}

class _AgentHooksSummary extends StatelessWidget {
  final bool connected;
  final bool checking;
  final bool installing;
  final AgentHookInstallResult? result;
  final bool statusUnsupported;
  final String tokenLabel;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _AgentHooksSummary({
    required this.connected,
    required this.checking,
    required this.installing,
    required this.result,
    required this.statusUnsupported,
    required this.tokenLabel,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = _summaryAccent(context, this);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Material(
        key: const ValueKey<String>('agent-hooks-summary'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_summaryIcon(this), color: accent),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Terminal agent alerts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _summaryTitle(this),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _summarySubtitle(this),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  _SummaryChip(
                    label: _hookChipLabel(this),
                    accent: accent,
                    showDot: true,
                  ),
                  _SummaryChip(label: tokenLabel),
                ],
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: Icon(
                      statusUnsupported
                          ? Icons.system_update_outlined
                          : Icons.bolt_outlined,
                    ),
                    label: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final Color? accent;
  final bool showDot;

  const _SummaryChip({required this.label, this.accent, this.showDot = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = accent ?? scheme.onSurfaceVariant;
    final background = accent == null
        ? scheme.surfaceContainerHighest
        : accent!.withAlpha(AppBannerOpacity.wash);
    final borderColor = accent == null
        ? scheme.outlineVariant
        : accent!.withAlpha(AppBannerOpacity.border);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

String? _summaryActionLabel(AppState appState) {
  if (appState.connectionState != BackendConnectionState.connected) return null;
  final hooks = appState.agentHooks;
  if (hooks.checking || hooks.installing) return null;
  if (hooks.statusUnsupported) return null;
  final result = hooks.lastResult;
  if (result == null ||
      !result.ok ||
      _agentsNeedingHookWork(result).isNotEmpty) {
    return 'Install hooks';
  }
  if (appState.publishTokens.loaded && appState.publishTokens.items.isEmpty) {
    return 'Create token';
  }
  return null;
}

Color _summaryAccent(BuildContext context, _AgentHooksSummary summary) {
  final scheme = Theme.of(context).colorScheme;
  if (!summary.connected) return scheme.onSurfaceVariant;
  if (summary.statusUnsupported) return scheme.error;
  if (summary.checking || summary.installing) return scheme.tertiary;
  final result = summary.result;
  if (result == null) return scheme.tertiary;
  if (!result.ok) return scheme.error;
  if (_agentsNeedingHookWork(result).isNotEmpty) return scheme.tertiary;
  if (_missingAgents(result).length == result.statuses.length) {
    return scheme.onSurfaceVariant;
  }
  return scheme.primary;
}

IconData _summaryIcon(_AgentHooksSummary summary) {
  if (!summary.connected) return Icons.cloud_off_outlined;
  if (summary.statusUnsupported) return Icons.system_update_outlined;
  if (summary.checking || summary.installing) return Icons.sync;
  final result = summary.result;
  if (result == null) return Icons.notifications_active_outlined;
  if (!result.ok) return Icons.error_outline;
  if (_agentsNeedingHookWork(result).isNotEmpty) return Icons.info_outline;
  if (_missingAgents(result).length == result.statuses.length) {
    return Icons.info_outline;
  }
  return Icons.task_alt;
}

String _summaryTitle(_AgentHooksSummary summary) {
  if (!summary.connected) return 'Backend offline';
  if (summary.statusUnsupported) return 'Agent alerts need backend update';
  if (summary.checking) return 'Checking agent hooks';
  if (summary.installing) return 'Installing agent hooks';
  final result = summary.result;
  if (result == null) return 'Agent alerts not checked';
  if (!result.ok) return 'Hook scan failed';
  final missing = _missingAgents(result);
  if (missing.length == result.statuses.length) return 'No agent configs found';
  if (_agentsNeedingHookWork(result).isNotEmpty) return 'Hook setup needed';
  return 'Agent alerts ready';
}

String _summarySubtitle(_AgentHooksSummary summary) {
  if (!summary.connected) {
    return 'Connect to a backend before configuring Claude/Codex alerts.';
  }
  if (summary.statusUnsupported) {
    return 'Update the backend, then scan Claude/Codex hook config.';
  }
  if (summary.checking) return 'Reading Claude Code and Codex config.';
  if (summary.installing) {
    return 'Writing safe Stop hooks into available agent configs.';
  }
  final result = summary.result;
  if (result == null) {
    return 'Scan the backend to enable finish alerts for terminal-launched agents.';
  }
  if (!result.ok) return 'Open the installer log below for details.';
  final missing = _missingAgents(result);
  if (missing.length == result.statuses.length) {
    return 'Open Claude or Codex once on the backend, then scan again.';
  }
  final needsWork = _agentsNeedingHookWork(result);
  if (needsWork.isNotEmpty) {
    return 'Install hooks so available agents can notify this phone when they stop.';
  }
  if (missing.isNotEmpty) {
    return 'Configured agents can notify this phone when they stop.';
  }
  return 'Claude/Codex completion notifications are configured on this backend.';
}

String _hookChipLabel(_AgentHooksSummary summary) {
  if (!summary.connected) return 'Offline';
  if (summary.statusUnsupported) return 'Cannot scan';
  if (summary.checking) return 'Checking';
  if (summary.installing) return 'Installing';
  final result = summary.result;
  if (result == null) return 'Not checked';
  if (!result.ok) return 'Scan failed';
  final missing = _missingAgents(result);
  if (missing.length == result.statuses.length) return 'No configs';
  if (_agentsNeedingHookWork(result).isNotEmpty) return 'Needs setup';
  return 'Hooks current';
}

String _credentialChipLabel(AppState appState) {
  final tokens = appState.publishTokens;
  if (appState.connectionState != BackendConnectionState.connected) {
    return 'Tokens unavailable';
  }
  if (tokens.loading) return 'Checking tokens';
  if (tokens.error != null) return 'Token check failed';
  if (!tokens.loaded) return 'Tokens not checked';
  final count = tokens.items.length;
  if (count == 0) return 'No tokens';
  if (count == 1) return '1 token';
  return '$count tokens';
}

String _installTitle({
  required bool connected,
  required bool checking,
  required bool installing,
  required AgentHookInstallResult? result,
  required bool statusUnsupported,
}) {
  if (!connected) return 'Backend disconnected';
  if (checking) return 'Checking hooks';
  if (installing) return 'Installing hooks';
  if (statusUnsupported) return 'Backend update required';
  final scan = result;
  if (scan == null) return 'Install hooks';
  if (!scan.ok) return 'Hook scan failed';
  if (_agentsNeedingHookWork(scan).isNotEmpty) {
    return 'Hook scan needs attention';
  }
  final missing = _missingAgents(scan);
  if (missing.length == scan.statuses.length) return 'No agent configs found';
  return 'Hooks current';
}

String _installSubtitle({
  required bool connected,
  required bool checking,
  required bool installing,
  required AgentHookInstallResult? result,
  required bool statusUnsupported,
}) {
  if (!connected) return 'Connect to a backend before installing hooks';
  if (checking) return 'Reading Claude Code and Codex config';
  if (installing) return 'Scanning Claude Code and Codex config';
  if (statusUnsupported) {
    return 'This backend is too old for agent hook setup';
  }
  final scan = result;
  if (scan == null) {
    return 'Enable finish alerts from terminal-launched agents';
  }
  if (!scan.ok) return 'Open the installer log below for details';
  final changed = scan.statuses.where((s) => s.available && s.changed).length;
  final needsWork = _agentsNeedingHookWork(scan);
  if (needsWork.isNotEmpty) {
    return '${needsWork.join(', ')} needs install or update';
  }
  final missing = _missingAgents(scan);
  if (missing.length == scan.statuses.length) {
    return 'Open Claude or Codex once on the backend, then scan again';
  }
  if (changed > 0 && missing.isNotEmpty) {
    return '$changed agent config updated; ${missing.join(', ')} not found';
  }
  if (changed > 0) return '$changed agent config updated';
  if (missing.isNotEmpty) {
    return 'Configured agents are ready; ${missing.join(', ')} not found';
  }
  return 'Claude Code and Codex are ready on this backend';
}

IconData _credentialIcon(AppState appState) {
  final tokens = appState.publishTokens;
  if (appState.connectionState != BackendConnectionState.connected) {
    return Icons.key_off_outlined;
  }
  if (tokens.loading) return Icons.sync;
  if (tokens.error != null) return Icons.error_outline;
  if (!tokens.loaded) return Icons.key_outlined;
  if (tokens.items.isEmpty) return Icons.add_moderator_outlined;
  return Icons.verified_user_outlined;
}

String _credentialSummary(AppState appState) {
  final tokens = appState.publishTokens;
  if (appState.connectionState != BackendConnectionState.connected) {
    return 'Connect to manage webhook tokens';
  }
  if (tokens.loading) return 'Checking webhook tokens';
  if (tokens.error != null) return 'Could not load webhook tokens';
  if (!tokens.loaded) return 'Tokens are checked after connection';
  final count = tokens.items.length;
  if (count == 0) return 'Create a token for agent and CI status posts';
  if (count == 1) return '1 webhook token ready';
  return '$count webhook tokens ready';
}

List<String> _missingAgents(AgentHookInstallResult result) {
  return [
    for (final status in result.statuses)
      if (!status.available) _agentLabel(status.agent),
  ];
}

List<String> _agentsNeedingHookWork(AgentHookInstallResult result) {
  return [
    for (final status in result.statuses)
      if (status.available &&
          (status.state == 'not-installed' ||
              status.state == 'stale' ||
              status.state == 'error'))
        _agentLabel(status.agent),
  ];
}

class _ResultSection extends StatelessWidget {
  final AgentHookInstallResult result;

  const _ResultSection(this.result);

  @override
  Widget build(BuildContext context) {
    final statuses = result.statuses;
    return InsetSection(
      title: 'Last scan',
      children: [
        if (statuses.isEmpty)
          ListTile(
            leading: Icon(
              result.ok ? Icons.check_circle_outline : Icons.error_outline,
            ),
            title: Text(result.ok ? 'Completed' : 'Failed'),
            subtitle: Text('Exit code ${result.exitCode ?? 'unknown'}'),
          )
        else
          for (final status in statuses) _AgentStatusTile(status: status),
        if (result.stderr.trim().isNotEmpty)
          ExpansionTile(
            leading: const Icon(Icons.terminal_outlined),
            title: const Text('Installer log'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    result.stderr.trim(),
                    style: AppText.monoCaption(context),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _AgentStatusTile extends StatelessWidget {
  final AgentHookStatus status;

  const _AgentStatusTile({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _summaryFor(status);
    final detail = status.message.trim();
    return ListTile(
      leading: Icon(_iconFor(status)),
      title: Text(_agentLabel(status.agent)),
      subtitle: Text(
        detail.isEmpty ? summary : detail,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        summary,
        style: theme.textTheme.labelMedium?.copyWith(
          color: _statusColor(context, status),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _agentLabel(String agent) {
  switch (agent) {
    case 'claude-code':
      return 'Claude Code';
    case 'codex':
      return 'Codex';
    default:
      return agent;
  }
}

IconData _iconFor(AgentHookStatus status) {
  if (!status.available) return Icons.info_outline;
  if (status.state == 'error') return Icons.error_outline;
  if (status.state == 'not-installed' || status.state == 'stale') {
    return Icons.info_outline;
  }
  if (status.changed) return Icons.task_alt;
  return Icons.check_circle_outline;
}

Color _statusColor(BuildContext context, AgentHookStatus status) {
  final scheme = Theme.of(context).colorScheme;
  if (!status.available) return scheme.onSurfaceVariant;
  if (status.state == 'error') return scheme.error;
  if (status.state == 'not-installed' || status.state == 'stale') {
    return scheme.tertiary;
  }
  if (status.changed) return scheme.primary;
  return scheme.onSurfaceVariant;
}

String _summaryFor(AgentHookStatus status) {
  if (!status.available) return 'Config not found';
  if (status.state == 'error') return status.message;
  if (status.state == 'not-installed') return 'Not installed';
  if (status.state == 'stale') return 'Update needed';
  if (status.changed) {
    return status.state == 'installed' ? 'Installed' : 'Updated';
  }
  return 'Already current';
}
