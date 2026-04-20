import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/git_models.dart';
import '../providers/git_provider.dart';
import '../providers/workspace_provider.dart';

class GitScreen extends StatefulWidget {
  const GitScreen({super.key});

  @override
  State<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends State<GitScreen> {
  final TextEditingController _commitMessageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final workDir = context.read<WorkspaceProvider>().currentPath;
      final gitProvider = context.read<GitProvider>();
      gitProvider.setWorkDir(workDir);
      gitProvider.refreshRepository();
    });
  }

  @override
  void dispose() {
    _commitMessageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GitProvider>(
      builder: (context, gitProvider, _) {
        final repository =
            gitProvider.repository ?? GitRepositoryState.empty(gitProvider.workDir);
        final branchLabel = repository.branch.isEmpty ? 'Git' : repository.branch;

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
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Fetch',
                onPressed: gitProvider.isLoading ? null : gitProvider.fetch,
              ),
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Pull',
                onPressed: gitProvider.isLoading ? null : gitProvider.pull,
              ),
              IconButton(
                icon: const Icon(Icons.publish),
                tooltip: 'Push',
                onPressed: gitProvider.isLoading ? null : gitProvider.push,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: gitProvider.isLoading
                    ? null
                    : gitProvider.refreshRepository,
              ),
            ],
          ),
          body: Column(
            children: [
              _RepositorySummary(repository: repository),
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
              if (repository.staged.isNotEmpty)
                _CommitCard(
                  controller: _commitMessageController,
                  stagedCount: repository.staged.length,
                  enabled: !gitProvider.isLoading,
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
                  _CountChip(label: 'Staged', value: repository.staged.length),
                  _CountChip(
                    label: 'Unstaged',
                    value: repository.unstaged.length,
                  ),
                  _CountChip(
                    label: 'Untracked',
                    value: repository.untracked.length,
                  ),
                  _CountChip(
                    label: 'Conflicts',
                    value: repository.conflicts.length,
                  ),
                  _CountChip(
                    label: 'Merge',
                    value: repository.mergeChanges.length,
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

  const _CountChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label $value'));
  }
}

class _CommitCard extends StatelessWidget {
  final TextEditingController controller;
  final int stagedCount;
  final bool enabled;
  final VoidCallback onCommit;

  const _CommitCard({
    required this.controller,
    required this.stagedCount,
    required this.enabled,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
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
                enabled: enabled,
                decoration: const InputDecoration(
                  hintText: 'Commit message',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: enabled ? onCommit : null,
                icon: const Icon(Icons.check),
                label: const Text('Commit'),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${group.title} (${group.changes.length})',
                style: Theme.of(context).textTheme.titleSmall,
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.circle,
        size: 12,
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
        ],
      ),
      trailing: _ActionButton(group: group, entry: entry),
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
    final gitProvider = context.read<GitProvider>();

    switch (group.primaryAction) {
      case GitChangeAction.stage:
        return IconButton(
          icon: const Icon(Icons.add_circle_outline, color: Colors.green),
          tooltip: 'Stage',
          onPressed: () => gitProvider.stageFile(entry.path),
        );
      case GitChangeAction.unstage:
        return IconButton(
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          tooltip: 'Unstage',
          onPressed: () => gitProvider.unstageFile(entry.path),
        );
      case GitChangeAction.discard:
        return IconButton(
          icon: const Icon(Icons.restore, color: Colors.red),
          tooltip: 'Discard',
          onPressed: () => gitProvider.discardFile(entry.path),
        );
    }
  }
}
