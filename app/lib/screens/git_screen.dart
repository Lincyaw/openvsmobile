import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/git_models.dart';
import '../providers/git_provider.dart';
import '../providers/workspace_provider.dart';
import 'diff_screen.dart';

class GitScreen extends StatefulWidget {
  const GitScreen({super.key});

  @override
  State<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends State<GitScreen> {
  final TextEditingController _commitMessageController = TextEditingController();
  int _handledFeedbackNonce = 0;

  @override
  void initState() {
    super.initState();
    _commitMessageController.addListener(_onCommitMessageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final workDir = context.read<WorkspaceProvider>().currentPath;
      final gitProvider = context.read<GitProvider>();
      gitProvider.setWorkDir(workDir);
      gitProvider.refreshRepository();
    });
  }

  @override
  void dispose() {
    _commitMessageController
      ..removeListener(_onCommitMessageChanged)
      ..dispose();
    super.dispose();
  }

  void _onCommitMessageChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GitProvider>(
      builder: (context, gitProvider, _) {
        final repository =
            gitProvider.repository ?? GitRepositoryState.empty(gitProvider.workDir);

        _showOperationFeedback(context, gitProvider);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Git'),
            actions: [
              _ToolbarAction(
                icon: Icons.download,
                tooltip: 'Fetch',
                isRunning: gitProvider.isRunning(GitOperationType.fetch),
                onPressed: gitProvider.isRunning(GitOperationType.fetch)
                    ? null
                    : gitProvider.fetch,
              ),
              _ToolbarAction(
                icon: Icons.sync,
                tooltip: 'Pull',
                isRunning: gitProvider.isRunning(GitOperationType.pull),
                onPressed: gitProvider.isRunning(GitOperationType.pull)
                    ? null
                    : gitProvider.pull,
              ),
              _ToolbarAction(
                icon: Icons.publish,
                tooltip: 'Push',
                isRunning: gitProvider.isRunning(GitOperationType.push),
                onPressed: gitProvider.isRunning(GitOperationType.push)
                    ? null
                    : gitProvider.push,
              ),
              _ToolbarAction(
                icon: Icons.refresh,
                tooltip: 'Refresh',
                isRunning: gitProvider.isRunning(GitOperationType.refresh),
                onPressed: gitProvider.isRunning(GitOperationType.refresh)
                    ? null
                    : gitProvider.refreshRepository,
              ),
            ],
          ),
          body: Column(
            children: [
              _RepoHeader(
                repository: repository,
                onBranchTap: () => _showBranchSheet(context, gitProvider),
                onInfoTap: () => _showRepoInfoSheet(context, repository),
              ),
              if (gitProvider.activeOperationLabel != null)
                _OperationStatusCard(label: gitProvider.activeOperationLabel!),
              if (gitProvider.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline),
                          const SizedBox(width: 8),
                          Expanded(child: Text(gitProvider.error!)),
                        ],
                      ),
                    ),
                  ),
                ),
              if (repository.stagedCount > 0)
                _CommitCard(
                  controller: _commitMessageController,
                  stagedCount: repository.stagedCount,
                  isSubmitting: gitProvider.isRunning(GitOperationType.commit),
                  onCommit: () async {
                    final message = _commitMessageController.text.trim();
                    if (message.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Commit message cannot be empty'),
                        ),
                      );
                      return;
                    }
                    await gitProvider.commit(message);
                    if (!mounted) {
                      return;
                    }
                    if (gitProvider.error == null) {
                      _commitMessageController.clear();
                    }
                  },
                ),
              Expanded(
                child: gitProvider.isLoading && repository.changeCount == 0
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: gitProvider.refreshRepository,
                        child: _RepositoryChangesList(repository: repository),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showOperationFeedback(BuildContext context, GitProvider gitProvider) {
    final feedback = gitProvider.feedback;
    if (feedback == null || feedback.nonce == _handledFeedbackNonce) {
      return;
    }
    _handledFeedbackNonce = feedback.nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(feedback.message),
          backgroundColor: feedback.kind == GitFeedbackKind.error
              ? Theme.of(context).colorScheme.error
              : null,
        ),
      );
      gitProvider.clearFeedback();
    });
  }

  void _showBranchSheet(BuildContext context, GitProvider gitProvider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BranchSwitcherSheet(gitProvider: gitProvider),
    );
  }

  void _showRepoInfoSheet(BuildContext context, GitRepositoryState repository) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _RepoInfoSheet(repository: repository),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isRunning;
  final VoidCallback? onPressed;

  const _ToolbarAction({
    required this.icon,
    required this.tooltip,
    required this.isRunning,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (isRunning) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Tooltip(
          message: tooltip,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _OperationStatusCard extends StatelessWidget {
  final String label;

  const _OperationStatusCard({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact repo header: branch picker + horizontal stat badges.
class _RepoHeader extends StatelessWidget {
  final GitRepositoryState repository;
  final VoidCallback onBranchTap;
  final VoidCallback onInfoTap;

  const _RepoHeader({
    required this.repository,
    required this.onBranchTap,
    required this.onInfoTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final branch = repository.branch.isEmpty ? '…' : repository.branch;

    return Container(
      color: colorScheme.surfaceContainerHighest.withAlpha(60),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // Branch picker button
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onBranchTap,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: colorScheme.primaryContainer.withAlpha(120),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.call_split,
                      size: 14,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        branch,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Horizontal scrolling stat badges
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (repository.ahead > 0)
                    _StatBadge(
                      icon: Icons.arrow_upward,
                      value: repository.ahead,
                      color: Colors.blue,
                    ),
                  if (repository.behind > 0)
                    _StatBadge(
                      icon: Icons.arrow_downward,
                      value: repository.behind,
                      color: Colors.orange,
                    ),
                  if (repository.stagedCount > 0)
                    _StatBadge(
                      icon: Icons.check_circle_outline,
                      value: repository.stagedCount,
                      color: Colors.green,
                    ),
                  if (repository.unstagedCount > 0)
                    _StatBadge(
                      icon: Icons.edit,
                      value: repository.unstagedCount,
                      color: Colors.deepOrange,
                    ),
                  if (repository.untrackedCount > 0)
                    _StatBadge(
                      icon: Icons.add,
                      value: repository.untrackedCount,
                      color: Colors.grey,
                    ),
                  if (repository.conflictCount > 0)
                    _StatBadge(
                      icon: Icons.warning_amber_rounded,
                      value: repository.conflictCount,
                      color: Colors.red,
                    ),
                  if (repository.totalChanges == 0)
                    _StatBadge(
                      icon: Icons.check,
                      value: null,
                      label: 'clean',
                      color: Colors.green,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Info button for upstream/remotes
          IconButton(
            icon: const Icon(Icons.info_outline, size: 18),
            tooltip: 'Repository info',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onInfoTap,
          ),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final IconData icon;
  final int? value;
  final String? label;
  final Color color;

  const _StatBadge({
    required this.icon,
    this.value,
    this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: color.withAlpha(30),
        border: Border.all(color: color.withAlpha(80), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 2),
          Text(
            value != null ? '$value' : label!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for switching branches.
class _BranchSwitcherSheet extends StatefulWidget {
  final GitProvider gitProvider;

  const _BranchSwitcherSheet({required this.gitProvider});

  @override
  State<_BranchSwitcherSheet> createState() => _BranchSwitcherSheetState();
}

class _BranchSwitcherSheetState extends State<_BranchSwitcherSheet> {
  bool _loading = true;
  List<String> _branches = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    try {
      final info = await widget.gitProvider.apiClient.getBranches(
        widget.gitProvider.workDir,
      );
      if (!mounted) return;
      setState(() {
        _branches = info.branches;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.gitProvider.repository?.branch ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Switch Branch',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Failed to load branches: $_error',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              )
            else if (_branches.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No branches found')),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _branches.length,
                  itemBuilder: (context, index) {
                    final branch = _branches[index];
                    final isCurrent = branch == current;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isCurrent ? Icons.check : Icons.call_split,
                        size: 18,
                        color: isCurrent
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        branch,
                        style: TextStyle(
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.normal,
                          color: isCurrent
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      onTap: isCurrent
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              await widget.gitProvider.apiClient.checkout(
                                widget.gitProvider.workDir,
                                branch,
                              );
                              await widget.gitProvider.refreshRepository();
                            },
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet showing upstream and remotes info.
class _RepoInfoSheet extends StatelessWidget {
  final GitRepositoryState repository;

  const _RepoInfoSheet({required this.repository});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              repository.branch.isEmpty ? 'Repository Info' : repository.branch,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (repository.upstream.isNotEmpty) ...[
              _InfoRow(label: 'Upstream', value: repository.upstream),
              const SizedBox(height: 8),
            ],
            if (repository.ahead > 0 || repository.behind > 0)
              _InfoRow(
                label: 'Sync',
                value: '${repository.ahead} ahead, ${repository.behind} behind',
              ),
            if (repository.remotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Remotes', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final remote in repository.remotes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        remote.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (remote.fetchUrl.isNotEmpty)
                        Text(
                          remote.fetchUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (remote.pushUrl.isNotEmpty &&
                          remote.pushUrl != remote.fetchUrl)
                        Text(
                          remote.pushUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

class _CommitCard extends StatelessWidget {
  final TextEditingController controller;
  final int stagedCount;
  final bool isSubmitting;
  final VoidCallback onCommit;

  const _CommitCard({
    required this.controller,
    required this.stagedCount,
    required this.isSubmitting,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
    final trimmedMessage = controller.text.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$stagedCount staged file${stagedCount == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                enabled: !isSubmitting,
                decoration: InputDecoration(
                  hintText: 'Commit message',
                  border: const OutlineInputBorder(),
                  helperText: trimmedMessage.isEmpty
                      ? 'Enter a commit message before committing.'
                      : 'Ready to commit your staged changes.',
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: isSubmitting || trimmedMessage.isEmpty ? null : onCommit,
                icon: isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(isSubmitting ? 'Committing...' : 'Commit'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepositoryChangesList extends StatelessWidget {
  final GitRepositoryState repository;

  const _RepositoryChangesList({required this.repository});

  @override
  Widget build(BuildContext context) {
    if (repository.isClean) {
      return ListView(
        children: const [
          SizedBox(height: 140),
          Center(child: Text('Working tree clean')),
        ],
      );
    }

    return ListView(
      children: repository.groups
          .map((group) => _ChangeSection(group: group))
          .toList(),
    );
  }
}

class _ChangeSection extends StatelessWidget {
  final GitChangeGroup group;

  const _ChangeSection({required this.group});

  @override
  Widget build(BuildContext context) {
    if (group.changes.isEmpty) {
      return const SizedBox.shrink();
    }

    final isConflictSection = group.key == 'conflicts';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        color: isConflictSection
            ? Theme.of(context).colorScheme.errorContainer.withAlpha(120)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isConflictSection) ...[
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      '${group.title} (${group.changes.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                group.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final entry in group.changes)
                _ChangeTile(group: group, entry: entry),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeTile extends StatelessWidget {
  final GitChangeGroup group;
  final GitChange entry;

  const _ChangeTile({required this.group, required this.entry});

  @override
  Widget build(BuildContext context) {
    final isConflict = group.key == 'conflicts';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: isConflict
            ? Theme.of(context).colorScheme.errorContainer.withAlpha(160)
            : Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(90),
        border: Border.all(
          color: isConflict
              ? Theme.of(context).colorScheme.error
              : Colors.transparent,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Icon(
          isConflict ? Icons.warning_amber_rounded : Icons.circle,
          size: isConflict ? 20 : 12,
          color: _accentColor(group.accent),
        ),
        title: Text(entry.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              entry.isRename ? '${entry.originalPath} -> ${entry.path}' : entry.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              _statusText(entry),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (isConflict)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Resolve in diff view before staging a final version.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        trailing: _ActionButton(group: group, entry: entry),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DiffScreen(
                filePath: entry.path,
                staged: group.primaryAction == GitChangeAction.unstage,
                isConflict: isConflict,
              ),
            ),
          );
        },
      ),
    );
  }

  String _statusText(GitChange change) {
    final pieces = <String>[change.statusLabel];
    if (change.indexStatus.isNotEmpty) {
      pieces.add('index ${change.indexStatus}');
    }
    if (change.workingTreeStatus.isNotEmpty) {
      pieces.add('worktree ${change.workingTreeStatus}');
    }
    return pieces.join(' • ');
  }

  Color _accentColor(GitGroupAccent accent) {
    switch (accent) {
      case GitGroupAccent.success:
        return Colors.green;
      case GitGroupAccent.info:
        return Colors.orange;
      case GitGroupAccent.warning:
        return Colors.deepOrange;
      case GitGroupAccent.danger:
        return Colors.red;
      case GitGroupAccent.neutral:
        return Colors.blue;
    }
  }
}

class _ActionButton extends StatelessWidget {
  final GitChangeGroup group;
  final GitChange entry;

  const _ActionButton({required this.group, required this.entry});

  @override
  Widget build(BuildContext context) {
    final gitProvider = context.watch<GitProvider>();
    final disableActions = gitProvider.hasActiveOperation;

    switch (group.primaryAction) {
      case GitChangeAction.stage:
        return IconButton(
          icon: const Icon(Icons.add_circle_outline, color: Colors.green),
          tooltip: 'Stage',
          onPressed: disableActions ? null : () => gitProvider.stageFile(entry.path),
        );
      case GitChangeAction.unstage:
        return IconButton(
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          tooltip: 'Unstage',
          onPressed: disableActions ? null : () => gitProvider.unstageFile(entry.path),
        );
      case GitChangeAction.resolve:
        return TextButton.icon(
          onPressed: disableActions
              ? null
              : () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DiffScreen(
                  filePath: entry.path,
                  staged: false,
                  isConflict: true,
                ),
              ),
            );
          },
          icon: const Icon(Icons.visibility),
          label: const Text('Resolve'),
        );
    }
  }
}
