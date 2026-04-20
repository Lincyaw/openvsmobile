import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/github_collaboration_provider.dart';
import 'github_auth_screen.dart';
import 'github_issue_detail_screen.dart';
import 'github_pull_request_detail_screen.dart';

class GitHubCollaborationScreen extends StatefulWidget {
  const GitHubCollaborationScreen({super.key});

  @override
  State<GitHubCollaborationScreen> createState() =>
      _GitHubCollaborationScreenState();
}

class _GitHubCollaborationScreenState extends State<GitHubCollaborationScreen> {
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    Future<void>.microtask(
      context.read<GitHubCollaborationProvider>().initialize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GitHubCollaborationProvider>();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('GitHub Collaboration'),
          actions: [
            IconButton(
              tooltip: 'GitHub auth',
              onPressed: () => _openGitHubAuth(context),
              icon: const Icon(Icons.manage_accounts_outlined),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: provider.isLoadingRepo
                  ? null
                  : () => provider.refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Issues', icon: Icon(Icons.bug_report_outlined)),
              Tab(text: 'Pull Requests', icon: Icon(Icons.merge_type)),
            ],
          ),
        ),
        body: Column(
          children: [
            _RepoSummaryCard(provider: provider),
            Expanded(
              child: TabBarView(
                children: [
                  _IssueListTab(provider: provider),
                  _PullRequestListTab(provider: provider),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openGitHubAuth(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const GitHubAuthScreen()));
  }
}

class _RepoSummaryCard extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _RepoSummaryCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final repo = provider.repoContext?.repository;
    final auth = provider.repoContext?.auth;
    final account = provider.accountContext?.account;
    final status =
        provider.repoContext?.status ??
        (provider.isLoadingRepo ? 'loading' : 'unavailable');

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    repo?.fullName.isNotEmpty == true
                        ? repo!.fullName
                        : 'Current workspace repository',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _StatusChip(status: status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              repo?.remoteUrl.isNotEmpty == true
                  ? repo!.remoteUrl
                  : provider.workspacePath.isNotEmpty
                  ? provider.workspacePath
                  : 'No workspace selected',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              account != null
                  ? 'Signed in as ${account.login}'
                  : auth?.accountLogin != null && auth!.accountLogin!.isNotEmpty
                  ? 'Signed in as ${auth.accountLogin}'
                  : 'GitHub account unavailable',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (provider.repoLoadError != null) ...[
              const SizedBox(height: 8),
              Text(
                provider.repoLoadError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else if ((provider.repoContext?.message ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(provider.repoContext!.message!),
            ],
          ],
        ),
      ),
    );
  }
}

class _IssueListTab extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _IssueListTab({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _IssueFilterBar(provider: provider),
        Expanded(child: _IssueListBody(provider: provider)),
      ],
    );
  }
}

class _IssueFilterBar extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _IssueFilterBar({required this.provider});

  @override
  Widget build(BuildContext context) {
    final filter = provider.issueFilter;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _StateChip(
            label: 'All',
            selected: filter.state.isEmpty,
            onSelected: (_) =>
                provider.updateIssueFilter(filter.copyWith(state: '')),
          ),
          _StateChip(
            label: 'Open',
            selected: filter.state == 'open',
            onSelected: (_) =>
                provider.updateIssueFilter(filter.copyWith(state: 'open')),
          ),
          _StateChip(
            label: 'Closed',
            selected: filter.state == 'closed',
            onSelected: (_) =>
                provider.updateIssueFilter(filter.copyWith(state: 'closed')),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Assigned to me'),
            selected: filter.assignedToMe,
            onSelected: (value) => provider.updateIssueFilter(
              filter.copyWith(assignedToMe: value),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Created by me'),
            selected: filter.createdByMe,
            onSelected: (value) =>
                provider.updateIssueFilter(filter.copyWith(createdByMe: value)),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Mentioned'),
            selected: filter.mentioned,
            onSelected: (value) =>
                provider.updateIssueFilter(filter.copyWith(mentioned: value)),
          ),
        ],
      ),
    );
  }
}

class _IssueListBody extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _IssueListBody({required this.provider});

  @override
  Widget build(BuildContext context) {
    if (provider.needsAuthAction) {
      return _AuthRequiredView(
        label: provider.repoStatusMessage,
        onOpenAuth: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const GitHubAuthScreen())),
      );
    }
    if (provider.isRepoUnavailable && !provider.canLoadCollaboration) {
      return _EmptyState(
        icon: Icons.link_off,
        title: 'GitHub collaboration unavailable',
        message: provider.repoStatusMessage,
      );
    }
    if (provider.isLoadingIssues && provider.issues.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.issuesLoadError != null) {
      return _EmptyState(
        icon: Icons.error_outline,
        title: 'Failed to load issues',
        message: provider.issuesLoadError!,
      );
    }
    if (provider.issues.isEmpty) {
      return const _EmptyState(
        icon: Icons.bug_report_outlined,
        title: 'No issues match these filters',
        message: 'Pull to refresh or change the filters.',
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.loadIssues(),
      child: ListView.separated(
        itemCount: provider.issues.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final issue = provider.issues[index];
          return ListTile(
            leading: Icon(
              issue.state == 'open'
                  ? Icons.radio_button_checked
                  : Icons.check_circle_outline,
            ),
            title: Text('#${issue.number} ${issue.title}'),
            subtitle: Text(
              issue.author?.login.isNotEmpty == true
                  ? 'by ${issue.author!.login} · ${issue.commentsCount} comments'
                  : '${issue.commentsCount} comments',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      GitHubIssueDetailScreen(issueNumber: issue.number),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _PullRequestListTab extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _PullRequestListTab({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PullRequestFilterBar(provider: provider),
        Expanded(child: _PullRequestListBody(provider: provider)),
      ],
    );
  }
}

class _PullRequestFilterBar extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _PullRequestFilterBar({required this.provider});

  @override
  Widget build(BuildContext context) {
    final filter = provider.pullFilter;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _StateChip(
            label: 'All',
            selected: filter.state.isEmpty,
            onSelected: (_) =>
                provider.updatePullFilter(filter.copyWith(state: '')),
          ),
          _StateChip(
            label: 'Open',
            selected: filter.state == 'open',
            onSelected: (_) =>
                provider.updatePullFilter(filter.copyWith(state: 'open')),
          ),
          _StateChip(
            label: 'Closed',
            selected: filter.state == 'closed',
            onSelected: (_) =>
                provider.updatePullFilter(filter.copyWith(state: 'closed')),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Assigned to me'),
            selected: filter.assignedToMe,
            onSelected: (value) =>
                provider.updatePullFilter(filter.copyWith(assignedToMe: value)),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Created by me'),
            selected: filter.createdByMe,
            onSelected: (value) =>
                provider.updatePullFilter(filter.copyWith(createdByMe: value)),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Mentioned'),
            selected: filter.mentioned,
            onSelected: (value) =>
                provider.updatePullFilter(filter.copyWith(mentioned: value)),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Needs review'),
            selected: filter.needsReview,
            onSelected: (value) =>
                provider.updatePullFilter(filter.copyWith(needsReview: value)),
          ),
        ],
      ),
    );
  }
}

class _PullRequestListBody extends StatelessWidget {
  final GitHubCollaborationProvider provider;

  const _PullRequestListBody({required this.provider});

  @override
  Widget build(BuildContext context) {
    if (provider.needsAuthAction) {
      return _AuthRequiredView(
        label: provider.repoStatusMessage,
        onOpenAuth: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const GitHubAuthScreen())),
      );
    }
    if (provider.isRepoUnavailable && !provider.canLoadCollaboration) {
      return _EmptyState(
        icon: Icons.link_off,
        title: 'GitHub collaboration unavailable',
        message: provider.repoStatusMessage,
      );
    }
    if (provider.isLoadingPulls && provider.pulls.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.pullsLoadError != null) {
      return _EmptyState(
        icon: Icons.error_outline,
        title: 'Failed to load pull requests',
        message: provider.pullsLoadError!,
      );
    }
    if (provider.pulls.isEmpty) {
      return const _EmptyState(
        icon: Icons.merge_type,
        title: 'No pull requests match these filters',
        message: 'Pull to refresh or change the filters.',
      );
    }

    return RefreshIndicator(
      onRefresh: () => provider.loadPullRequests(),
      child: ListView.separated(
        itemCount: provider.pulls.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final pull = provider.pulls[index];
          return ListTile(
            leading: Icon(
              pull.merged
                  ? Icons.done_all
                  : pull.state == 'open'
                  ? Icons.merge_type
                  : Icons.inventory_2_outlined,
            ),
            title: Text('#${pull.number} ${pull.title}'),
            subtitle: Text(
              '${pull.headRef.ref} -> ${pull.baseRef.ref} · ${pull.changedFiles} files',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GitHubPullRequestDetailScreen(
                    pullRequestNumber: pull.number,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AuthRequiredView extends StatelessWidget {
  final String label;
  final VoidCallback onOpenAuth;

  const _AuthRequiredView({required this.label, required this.onOpenAuth});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'GitHub authentication required',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(label, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpenAuth,
              icon: const Icon(Icons.manage_accounts_outlined),
              label: const Text('Open GitHub auth'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(status.replaceAll('_', ' ')),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _StateChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const _StateChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
      ),
    );
  }
}
