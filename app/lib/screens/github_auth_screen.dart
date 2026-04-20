import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/github_auth_models.dart';
import '../providers/github_auth_provider.dart';
import '../services/browser_launcher.dart';

typedef GitHubUrlOpener = Future<bool> Function(String url);

class GitHubAuthScreen extends StatefulWidget {
  final GitHubUrlOpener? onOpenUrl;

  const GitHubAuthScreen({super.key, this.onOpenUrl});

  @override
  State<GitHubAuthScreen> createState() => _GitHubAuthScreenState();
}

class _GitHubAuthScreenState extends State<GitHubAuthScreen> {
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    final provider = context.read<GitHubAuthProvider>();
    Future<void>.microtask(provider.initialize);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GitHubAuthProvider>();
    final notice = provider.notice;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GitHub Device Flow'),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: provider.isBusy ? null : () => provider.loadStatus(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (notice != null) ...[
            _NoticeCard(notice: notice),
            const SizedBox(height: 16),
          ],
          _OverviewCard(provider: provider),
          const SizedBox(height: 16),
          if (provider.isPending && provider.pendingFlow != null)
            _PendingCard(
              flow: provider.pendingFlow!,
              secondsRemaining: provider.secondsRemaining,
              pollingLabel: provider.pollingLabel,
            )
          else if (provider.isConnected && provider.status != null)
            _ConnectedCard(
              provider: provider,
              status: provider.status!,
              repoAvailability: provider.repoAvailability,
            )
          else if (provider.isBusy)
            const _LoadingCard()
          else if (provider.isError)
            const _ErrorCard()
          else
            const _IdleCard(),
          const SizedBox(height: 16),
          _ActionCard(provider: provider, onOpenUrl: widget.onOpenUrl),
        ],
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  final GitHubAuthProvider provider;

  const _OverviewCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Flow overview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _MetaRow(
              label: 'Status',
              value: switch (provider.viewState) {
                GitHubAuthViewState.idle => 'Not connected',
                GitHubAuthViewState.loading => 'Loading',
                GitHubAuthViewState.pending =>
                  'Device authorization in progress',
                GitHubAuthViewState.connected => 'Connected',
                GitHubAuthViewState.error => 'Action required',
                GitHubAuthViewState.disconnecting => 'Disconnecting',
              },
            ),
            const SizedBox(height: 8),
            _MetaRow(
              label: 'Host',
              value:
                  provider.status?.githubHost ??
                  provider.pendingFlow?.githubHost ??
                  'github.com',
            ),
            const SizedBox(height: 8),
            _MetaRow(
              label: 'Workspace',
              value: provider.workspacePath.isEmpty
                  ? 'No workspace selected'
                  : provider.workspacePath,
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  final GitHubDeviceCode flow;
  final int secondsRemaining;
  final String pollingLabel;

  const _PendingCard({
    required this.flow,
    required this.secondsRemaining,
    required this.pollingLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device authorization in progress',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              flow.userCode,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(letterSpacing: 2),
            ),
            const SizedBox(height: 8),
            SelectableText(flow.verificationUri),
            const SizedBox(height: 12),
            _MetaRow(
              label: 'Countdown',
              value: _formatCountdown(secondsRemaining),
            ),
            const SizedBox(height: 8),
            _MetaRow(label: 'Polling status', value: pollingLabel),
            const SizedBox(height: 8),
            Text(
              'The device code stays only in memory for this flow and is never persisted by the Flutter app.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds remaining';
  }
}

class _ConnectedCard extends StatelessWidget {
  final GitHubAuthProvider provider;
  final GitHubAuthStatus status;
  final GitHubRepoAvailability repoAvailability;

  const _ConnectedCard({
    required this.provider,
    required this.status,
    required this.repoAvailability,
  });

  @override
  Widget build(BuildContext context) {
    final expiryFormat = DateFormat.yMd().add_Hm();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connected', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  child: Text(
                    (status.accountLogin?.isNotEmpty ?? false)
                        ? status.accountLogin!.substring(0, 1).toUpperCase()
                        : '?',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.accountLabel(),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('Host: ${status.githubHost}'),
                      Text(
                        status.accountId != null
                            ? 'Account ID: ${status.accountId}'
                            : 'Account ID not provided by backend',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Avatar images are not available because the current backend status contract does not expose an avatar URL.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (status.accessTokenExpiresAt != null)
              _MetaRow(
                label: 'Access token expires',
                value: expiryFormat.format(
                  status.accessTokenExpiresAt!.toLocal(),
                ),
              ),
            if (status.refreshTokenExpiresAt != null) ...[
              const SizedBox(height: 8),
              _MetaRow(
                label: 'Refresh token expires',
                value: expiryFormat.format(
                  status.refreshTokenExpiresAt!.toLocal(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Workspace repo status',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              repoAvailability.title,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(repoAvailability.message),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final GitHubAuthProvider provider;
  final GitHubUrlOpener? onOpenUrl;

  const _ActionCard({required this.provider, this.onOpenUrl});

  @override
  Widget build(BuildContext context) {
    final verificationUri = provider.pendingFlow?.verificationUri;
    final userCode = provider.pendingFlow?.userCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: provider.isBusy || provider.isPending
                  ? null
                  : () => provider.startDeviceFlow(),
              icon: const Icon(Icons.login),
              label: const Text('Connect GitHub'),
            ),
            OutlinedButton.icon(
              onPressed: verificationUri == null
                  ? null
                  : () => _openGitHub(context, verificationUri),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open GitHub'),
            ),
            OutlinedButton.icon(
              onPressed: userCode == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: userCode));
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('GitHub device code copied.'),
                        ),
                      );
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy code'),
            ),
            OutlinedButton.icon(
              onPressed:
                  provider.isBusy ||
                      (!provider.isPending && !provider.isConnected)
                  ? null
                  : () {
                      if (provider.isPending) {
                        provider.cancelPendingFlow();
                      } else {
                        provider.disconnect();
                      }
                    },
              icon: Icon(provider.isPending ? Icons.cancel : Icons.link_off),
              label: Text(provider.isPending ? 'Cancel' : 'Disconnect'),
            ),
            TextButton.icon(
              onPressed: provider.canRetry ? () => provider.retry() : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGitHub(BuildContext context, String verificationUri) async {
    final opener =
        onOpenUrl ??
        (String url) async {
          final launcher = context.read<BrowserLauncher>();
          return launcher.openUrl(url);
        };
    final success = await opener(verificationUri);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Opened GitHub in your browser.'
              : 'Could not open a browser automatically. Use the copied link instead.',
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final GitHubAuthNotice notice;

  const _NoticeCard({required this.notice});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = notice.isError
        ? colorScheme.errorContainer
        : colorScheme.secondaryContainer;
    final foreground = notice.isError
        ? colorScheme.onErrorContainer
        : colorScheme.onSecondaryContainer;

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: DefaultTextStyle(
        style: TextStyle(color: foreground),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notice.title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: foreground),
            ),
            const SizedBox(height: 8),
            Text(notice.message),
          ],
        ),
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  const _IdleCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Not connected. Start the GitHub Device Flow to receive a code, open GitHub, and approve this server.',
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Action required. Review the message above, then retry the GitHub Device Flow or disconnect the stale session.',
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Checking the current GitHub auth state...')),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 132,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}
