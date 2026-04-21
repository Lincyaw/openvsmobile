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
        final branchLabel = repository.branch.isEmpty ? 'Git' : repository.branch;

        _showOperationFeedback(context, gitProvider);

        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.commit, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(branchLabel, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
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
              _RepositorySummary(repository: repository),
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

class _RepositorySummary extends StatelessWidget {
  final GitRepositoryState repository;

  const _RepositorySummary({required this.repository});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                repository.branch.isEmpty ? 'Repository' : repository.branch,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (repository.upstream.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Upstream: ${repository.upstream}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CountChip(label: 'Ahead', value: repository.ahead),
                  _CountChip(label: 'Behind', value: repository.behind),
                  _CountChip(label: 'Staged', value: repository.stagedCount),
                  _CountChip(label: 'Changes', value: repository.unstagedCount),
                  _CountChip(label: 'Untracked', value: repository.untrackedCount),
                  _CountChip(
                    label: 'Conflicts',
                    value: repository.conflictCount,
                    color: Theme.of(context).colorScheme.errorContainer,
                  ),
                ],
              ),
              if (repository.remotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Remotes',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                for (final remote in repository.remotes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${remote.name}: ${remote.fetchUrl.isNotEmpty ? remote.fetchUrl : remote.pushUrl}',
                      style: Theme.of(context).textTheme.bodySmall,
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

class _CountChip extends StatelessWidget {
  final String label;
  final int value;
  final Color? color;

  const _CountChip({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      backgroundColor: color,
      label: Text('$label $value'),
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
