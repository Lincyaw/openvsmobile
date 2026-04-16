import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/git_provider.dart';
import '../providers/workspace_provider.dart';
import '../providers/file_provider.dart';
import '../models/git_models.dart';
import '../widgets/app_bar_menu.dart';
import 'diff_screen.dart';

class GitScreen extends StatefulWidget {
  const GitScreen({super.key});

  @override
  State<GitScreen> createState() => _GitScreenState();
}

enum _GitTab { changes, log, branches }

class _GitScreenState extends State<GitScreen> {
  _GitTab _currentTab = _GitTab.changes;
  String? _lastWorkDir;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncWorkDirAndRefresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncWorkDirAndRefresh();
  }

  void _syncWorkDirAndRefresh() {
    final workDir = context.read<WorkspaceProvider>().currentPath;
    if (_lastWorkDir == workDir) return;
    _lastWorkDir = workDir;
    final gitProvider = context.read<GitProvider>();
    gitProvider.setWorkDir(workDir);
    // Defer refresh to avoid notifyListeners during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) gitProvider.refreshAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final wsName = context.select<WorkspaceProvider, String>(
      (ws) => ws.displayName,
    );

    return Consumer<GitProvider>(
      builder: (context, gitProvider, child) {
        final branchName = gitProvider.branchInfo?.current ?? '...';

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.commit, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        branchName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Text(
                  wsName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: () => gitProvider.refreshAll(),
              ),
              const AppBarMenu(),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    _TabChip(
                      label: 'Changes',
                      selected: _currentTab == _GitTab.changes,
                      onTap: () =>
                          setState(() => _currentTab = _GitTab.changes),
                    ),
                    const SizedBox(width: 8),
                    _TabChip(
                      label: 'Log',
                      selected: _currentTab == _GitTab.log,
                      onTap: () => setState(() => _currentTab = _GitTab.log),
                    ),
                    const SizedBox(width: 8),
                    _TabChip(
                      label: 'Branches',
                      selected: _currentTab == _GitTab.branches,
                      onTap: () =>
                          setState(() => _currentTab = _GitTab.branches),
                    ),
                  ],
                ),
              ),
              if (gitProvider.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              gitProvider.error!,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: gitProvider.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: () => gitProvider.refreshAll(),
                        child: _buildTabContent(gitProvider),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTabContent(GitProvider provider) {
    switch (_currentTab) {
      case _GitTab.changes:
        return _ChangesView(entries: provider.statusEntries);
      case _GitTab.log:
        return _LogView(entries: provider.logEntries);
      case _GitTab.branches:
        return _BranchesView(branchInfo: provider.branchInfo);
    }
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _ChangesView extends StatefulWidget {
  final List<GitStatusEntry> entries;

  const _ChangesView({required this.entries});

  @override
  State<_ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends State<_ChangesView> {
  final TextEditingController _commitMessageController =
      TextEditingController();

  @override
  void dispose() {
    _commitMessageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  'Working tree clean',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final stagedCount = widget.entries.where((e) => e.staged).length;

    return ListView.builder(
      itemCount: widget.entries.length + (stagedCount > 0 ? 1 : 0),
      itemBuilder: (context, index) {
        // Show commit section at the top when there are staged files.
        if (stagedCount > 0 && index == 0) {
          return _buildCommitSection(context, stagedCount);
        }

        final entryIndex = stagedCount > 0 ? index - 1 : index;
        final entry = widget.entries[entryIndex];
        return ListTile(
          leading: _StatusIcon(status: entry.status),
          title: Text(
            entry.path.split('/').last,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            entry.path,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: Icon(
              entry.staged
                  ? Icons.remove_circle_outline
                  : Icons.add_circle_outline,
              color: entry.staged ? Colors.orange : Colors.green,
            ),
            tooltip: entry.staged ? 'Unstage' : 'Stage',
            onPressed: () {
              final gitProvider = context.read<GitProvider>();
              if (entry.staged) {
                gitProvider.unstageFile(entry.path).then((_) {
                  if (context.mounted && gitProvider.error != null) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(gitProvider.error!)));
                  }
                });
              } else {
                gitProvider.stageFile(entry.path).then((_) {
                  if (context.mounted && gitProvider.error != null) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(gitProvider.error!)));
                  }
                });
              }
            },
          ),
          onTap: () {
            final gitProvider = context.read<GitProvider>();
            gitProvider.loadDiff(file: entry.path, staged: entry.staged).then((
              _,
            ) {
              if (context.mounted) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DiffScreen(
                      fileName: entry.path.split('/').last,
                      diffContent: gitProvider.currentDiff ?? '',
                    ),
                  ),
                );
              }
            });
          },
        );
      },
    );
  }

  Widget _buildCommitSection(BuildContext context, int stagedCount) {
    return Padding(
      padding: const EdgeInsets.all(12),
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
                controller: _commitMessageController,
                decoration: const InputDecoration(
                  hintText: 'Commit message',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 3,
                minLines: 1,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Commit'),
                onPressed: () {
                  final message = _commitMessageController.text.trim();
                  if (message.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Commit message cannot be empty'),
                      ),
                    );
                    return;
                  }
                  final gitProvider = context.read<GitProvider>();
                  gitProvider.commit(message).then((_) {
                    if (context.mounted) {
                      if (gitProvider.error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(gitProvider.error!)),
                        );
                      } else {
                        _commitMessageController.clear();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Commit successful')),
                        );
                      }
                    }
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final String status;

  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;

    switch (status) {
      case 'modified':
        icon = Icons.edit;
        color = Colors.orange;
        break;
      case 'added':
        icon = Icons.add_circle;
        color = Colors.green;
        break;
      case 'deleted':
        icon = Icons.remove_circle;
        color = Colors.red;
        break;
      case 'renamed':
        icon = Icons.drive_file_rename_outline;
        color = Colors.blue;
        break;
      case 'untracked':
        icon = Icons.help_outline;
        color = Colors.grey;
        break;
      default:
        icon = Icons.circle;
        color = Colors.grey;
    }

    return Icon(icon, color: color, size: 24);
  }
}

class _LogView extends StatelessWidget {
  final List<GitLogEntry> entries;

  const _LogView({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.history,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  'No commits yet',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final shortHash = entry.hash.length > 7
            ? entry.hash.substring(0, 7)
            : entry.hash;

        return ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              shortHash.substring(0, 2),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          title: Text(
            entry.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '$shortHash - ${entry.author} - ${entry.date}',
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _onLogEntryTap(context, entry),
        );
      },
    );
  }

  void _onLogEntryTap(BuildContext context, GitLogEntry entry) async {
    final gitProvider = context.read<GitProvider>();
    await gitProvider.apiClient.getShowCommit(gitProvider.workDir, entry.hash).then((diff) {
      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DiffScreen(
              fileName: entry.hash.substring(0, 7),
              diffContent: diff,
            ),
          ),
        );
      }
    }).catchError((e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load commit diff: $e')),
        );
      }
    });
  }
}

class _BranchesView extends StatelessWidget {
  final GitBranchInfo? branchInfo;

  const _BranchesView({required this.branchInfo});

  @override
  Widget build(BuildContext context) {
    if (branchInfo == null || branchInfo!.branches.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.account_tree,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  'No branches found',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      itemCount: branchInfo!.branches.length,
      itemBuilder: (context, index) {
        final branch = branchInfo!.branches[index];
        final isCurrent = branch == branchInfo!.current;

        return ListTile(
          leading: Icon(
            isCurrent ? Icons.radio_button_checked : Icons.radio_button_off,
            color: isCurrent
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          title: Text(
            branch,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          trailing: isCurrent
              ? Chip(
                  label: const Text('Current'),
                  labelStyle: const TextStyle(fontSize: 11),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                )
              : TextButton(
                  onPressed: () => _onCheckout(context, branch),
                  child: const Text('Switch'),
                ),
        );
      },
    );
  }

  void _onCheckout(BuildContext context, String branch) async {
    final gitProvider = context.read<GitProvider>();
    await gitProvider.checkoutBranch(branch).then((_) {
      if (context.mounted && gitProvider.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(gitProvider.error!)),
        );
      } else if (context.mounted) {
        // Branch changed the working tree — refresh file tree so UI stays consistent.
        context.read<FileProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Switched to $branch')),
        );
      }
    });
  }
}
