import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/editor_context.dart';
import '../models/github_collaboration_models.dart';
import '../providers/editor_provider.dart';
import '../providers/github_collaboration_provider.dart';
import 'code_screen.dart';
import 'github_patch_screen.dart';

class GitHubPullRequestDetailScreen extends StatefulWidget {
  final int pullRequestNumber;

  const GitHubPullRequestDetailScreen({
    super.key,
    required this.pullRequestNumber,
  });

  @override
  State<GitHubPullRequestDetailScreen> createState() =>
      _GitHubPullRequestDetailScreenState();
}

class _GitHubPullRequestDetailScreenState
    extends State<GitHubPullRequestDetailScreen> {
  final TextEditingController _reviewController = TextEditingController();
  bool _initialized = false;
  String _selectedReviewEvent = 'COMMENT';
  bool _isResolvingFile = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    final provider = context.read<GitHubCollaborationProvider>();
    Future<void>.microtask(
      () => provider.loadPullRequestDetail(
        widget.pullRequestNumber,
        forceRefresh: true,
      ),
    );
  }

  @override
  void dispose() {
    _reviewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GitHubCollaborationProvider>();
    final detail = provider.pullRequestDetailFor(widget.pullRequestNumber);
    final isLoading = provider.isLoadingPullRequestDetail(
      widget.pullRequestNumber,
    );
    final error = provider.pullRequestDetailErrorFor(widget.pullRequestNumber);
    final isSubmittingReview = provider.isSubmittingPullRequestReview(
      widget.pullRequestNumber,
    );
    final submitError = provider.pullSubmitErrorFor(widget.pullRequestNumber);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text('PR #${widget.pullRequestNumber}'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Files'),
              Tab(text: 'Conversation'),
              Tab(text: 'Checks'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh pull request',
              onPressed: isLoading
                  ? null
                  : () => provider.loadPullRequestDetail(
                      widget.pullRequestNumber,
                      forceRefresh: true,
                    ),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Builder(
          builder: (context) {
            if (isLoading && detail == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (error != null && detail == null) {
              return _PullRequestErrorView(message: error);
            }
            if (detail == null) {
              return const _PullRequestErrorView(
                message: 'Pull request details are unavailable right now.',
              );
            }

            return Column(
              children: [
                if (submitError != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(submitError),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _PullRequestOverviewTab(detail: detail),
                      _PullRequestFilesTab(
                        files: detail.files,
                        isResolvingFile: _isResolvingFile,
                        onOpenFile: (file) => _openFile(provider, file),
                      ),
                      _PullRequestConversationTab(
                        detail: detail,
                        selectedReviewEvent: _selectedReviewEvent,
                        reviewController: _reviewController,
                        isSubmitting: isSubmittingReview,
                        onEventChanged: (value) {
                          setState(() {
                            _selectedReviewEvent = value;
                          });
                        },
                        onSubmit: () => _submitReview(provider),
                      ),
                      _PullRequestChecksTab(detail: detail),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openFile(
    GitHubCollaborationProvider provider,
    GitHubPullRequestFile file,
  ) async {
    setState(() {
      _isResolvingFile = true;
    });

    try {
      final action = await provider.resolvePullRequestFileAction(file);
      if (!mounted) {
        return;
      }
      if (action.shouldOpenLocalFile) {
        final editorProvider = context.read<EditorProvider>();
        await editorProvider.openFile(
          action.localPath,
          cursor: EditorCursor(line: action.line ?? 1, column: 1),
        );
        if (!mounted) {
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: editorProvider,
              child: const CodeScreen(),
            ),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                GitHubPatchScreen(path: action.patchPath, patch: action.patch),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingFile = false;
        });
      }
    }
  }

  Future<void> _submitReview(GitHubCollaborationProvider provider) async {
    final success = await provider.submitPullRequestReview(
      widget.pullRequestNumber,
      GitHubPullRequestReviewInput(
        event: _selectedReviewEvent,
        body: _reviewController.text.trim(),
      ),
    );
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (success) {
      _reviewController.clear();
      messenger.showSnackBar(
        SnackBar(content: Text('Review $_selectedReviewEvent submitted')),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            provider.pullSubmitErrorFor(widget.pullRequestNumber) ??
                'Failed to submit the pull request review.',
          ),
        ),
      );
    }
  }
}

class _PullRequestOverviewTab extends StatelessWidget {
  final GitHubPullRequestDetail detail;

  const _PullRequestOverviewTab({required this.detail});

  @override
  Widget build(BuildContext context) {
    final pull = detail.pullRequest;
    final dateFormat = DateFormat.yMd().add_Hm();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#${pull.number} ${pull.title}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(pull.state)),
                    if (pull.draft) const Chip(label: Text('Draft')),
                    if (pull.merged) const Chip(label: Text('Merged')),
                    Chip(label: Text('${pull.changedFiles} files changed')),
                    Chip(label: Text('${pull.additions} additions')),
                    Chip(label: Text('${pull.deletions} deletions')),
                    if (pull.updatedAt != null)
                      Chip(
                        label: Text(
                          'Updated ${dateFormat.format(pull.updatedAt!.toLocal())}',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Base: ${pull.baseRef.ref}'),
                Text('Head: ${pull.headRef.ref}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: pull.body.isNotEmpty
                  ? pull.body
                  : '_No pull request description provided._',
            ),
          ),
        ),
      ],
    );
  }
}

class _PullRequestFilesTab extends StatelessWidget {
  final List<GitHubPullRequestFile> files;
  final bool isResolvingFile;
  final ValueChanged<GitHubPullRequestFile> onOpenFile;

  const _PullRequestFilesTab({
    required this.files,
    required this.isResolvingFile,
    required this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const Center(child: Text('No changed files reported.'));
    }

    return Stack(
      children: [
        ListView.separated(
          itemCount: files.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final file = files[index];
            return ListTile(
              title: Text(file.filename),
              subtitle: Text(
                '${file.status} · +${file.additions} / -${file.deletions}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpenFile(file),
            );
          },
        ),
        if (isResolvingFile)
          const Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
      ],
    );
  }
}

class _PullRequestConversationTab extends StatelessWidget {
  final GitHubPullRequestDetail detail;
  final String selectedReviewEvent;
  final TextEditingController reviewController;
  final bool isSubmitting;
  final ValueChanged<String> onEventChanged;
  final Future<void> Function() onSubmit;

  const _PullRequestConversationTab({
    required this.detail,
    required this.selectedReviewEvent,
    required this.reviewController,
    required this.isSubmitting,
    required this.onEventChanged,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMd().add_Hm();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Reviews', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (detail.reviews.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No reviews yet.'),
            ),
          )
        else
          ...detail.reviews.map(
            (review) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      review.author?.login.isNotEmpty == true
                          ? review.author!.login
                          : 'Unknown reviewer',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(review.state),
                    if (review.submittedAt != null)
                      Text(
                        dateFormat.format(review.submittedAt!.toLocal()),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (review.body.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      MarkdownBody(data: review.body),
                    ],
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Comments', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (detail.comments.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No review comments yet.'),
            ),
          )
        else
          ...detail.comments.map(
            (comment) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comment.author?.login.isNotEmpty == true
                          ? comment.author!.login
                          : 'Unknown author',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (comment.path.isNotEmpty)
                      Text(
                        comment.path,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (comment.updatedAt != null)
                      Text(
                        dateFormat.format(comment.updatedAt!.toLocal()),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                    MarkdownBody(
                      data: comment.body.isNotEmpty
                          ? comment.body
                          : '_Empty comment._',
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Submit review',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'COMMENT', label: Text('Comment')),
                    ButtonSegment(value: 'APPROVE', label: Text('Approve')),
                    ButtonSegment(
                      value: 'REQUEST_CHANGES',
                      label: Text('Request changes'),
                    ),
                  ],
                  selected: <String>{selectedReviewEvent},
                  onSelectionChanged: (values) => onEventChanged(values.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reviewController,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Review comment',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: isSubmitting ? null : () => onSubmit(),
                    child: isSubmitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit review'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PullRequestChecksTab extends StatelessWidget {
  final GitHubPullRequestDetail detail;

  const _PullRequestChecksTab({required this.detail});

  @override
  Widget build(BuildContext context) {
    final checks = detail.pullRequest.checks;
    if (checks == null) {
      return const Center(child: Text('No checks were reported.'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('State: ${checks.state}')),
                Chip(label: Text('Total: ${checks.totalCount}')),
                Chip(label: Text('Success: ${checks.successCount}')),
                Chip(label: Text('Pending: ${checks.pendingCount}')),
                Chip(label: Text('Failure: ${checks.failureCount}')),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ...checks.checks.map(
          (check) => ListTile(
            leading: Icon(
              check.conclusion == 'success'
                  ? Icons.check_circle_outline
                  : check.status == 'pending'
                  ? Icons.schedule
                  : Icons.error_outline,
            ),
            title: Text(check.name),
            subtitle: Text(
              check.conclusion.isNotEmpty ? check.conclusion : check.status,
            ),
          ),
        ),
      ],
    );
  }
}

class _PullRequestErrorView extends StatelessWidget {
  final String message;

  const _PullRequestErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Failed to load pull request',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
