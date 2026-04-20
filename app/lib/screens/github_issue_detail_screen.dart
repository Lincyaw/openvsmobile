import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/github_collaboration_models.dart';
import '../providers/github_collaboration_provider.dart';

class GitHubIssueDetailScreen extends StatefulWidget {
  final int issueNumber;

  const GitHubIssueDetailScreen({super.key, required this.issueNumber});

  @override
  State<GitHubIssueDetailScreen> createState() =>
      _GitHubIssueDetailScreenState();
}

class _GitHubIssueDetailScreenState extends State<GitHubIssueDetailScreen> {
  final TextEditingController _commentController = TextEditingController();
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    final provider = context.read<GitHubCollaborationProvider>();
    Future<void>.microtask(
      () => provider.loadIssueDetail(widget.issueNumber, forceRefresh: true),
    );
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GitHubCollaborationProvider>();
    final detail = provider.issueDetailFor(widget.issueNumber);
    final isLoading = provider.isLoadingIssueDetail(widget.issueNumber);
    final error = provider.issueDetailErrorFor(widget.issueNumber);
    final submitError = provider.issueSubmitErrorFor(widget.issueNumber);
    final isSubmitting = provider.isSubmittingIssueComment(widget.issueNumber);

    return Scaffold(
      appBar: AppBar(
        title: Text('Issue #${widget.issueNumber}'),
        actions: [
          IconButton(
            tooltip: 'Refresh issue',
            onPressed: isLoading
                ? null
                : () => provider.loadIssueDetail(
                    widget.issueNumber,
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
            return _IssueErrorView(message: error);
          }
          if (detail == null) {
            return const _IssueErrorView(
              message: 'Issue details are unavailable right now.',
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
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _IssueHeader(issue: detail.issue),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: MarkdownBody(
                          data: detail.issue.body.isNotEmpty
                              ? detail.issue.body
                              : '_No description provided._',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Comments',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (detail.comments.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No comments yet.'),
                        ),
                      )
                    else
                      ...detail.comments.map(
                        (comment) => _IssueCommentCard(comment: comment),
                      ),
                  ],
                ),
              ),
              _IssueCommentComposer(
                controller: _commentController,
                isSubmitting: isSubmitting,
                onSubmit: () async {
                  final success = await provider.submitIssueComment(
                    widget.issueNumber,
                    _commentController.text,
                  );
                  if (!mounted) {
                    return;
                  }
                  final messenger = ScaffoldMessenger.of(this.context);
                  if (success) {
                    _commentController.clear();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Issue comment posted')),
                    );
                  } else {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          provider.issueSubmitErrorFor(widget.issueNumber) ??
                              'Failed to post issue comment.',
                        ),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _IssueHeader extends StatelessWidget {
  final GitHubIssue issue;

  const _IssueHeader({required this.issue});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMd().add_Hm();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '#${issue.number} ${issue.title}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(issue.state)),
                if (issue.author != null)
                  Chip(label: Text('Author: ${issue.author!.login}')),
                Chip(label: Text('${issue.commentsCount} comments')),
                if (issue.updatedAt != null)
                  Chip(
                    label: Text(
                      'Updated ${dateFormat.format(issue.updatedAt!.toLocal())}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueCommentCard extends StatelessWidget {
  final GitHubIssueComment comment;

  const _IssueCommentCard({required this.comment});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMd().add_Hm();
    return Card(
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
            if (comment.createdAt != null)
              Text(
                dateFormat.format(comment.createdAt!.toLocal()),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            MarkdownBody(
              data: comment.body.isNotEmpty ? comment.body : '_Empty comment._',
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueCommentComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSubmitting;
  final Future<void> Function() onSubmit;

  const _IssueCommentComposer({
    required this.controller,
    required this.isSubmitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Add a comment',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: isSubmitting ? null : () => onSubmit(),
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Post'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueErrorView extends StatelessWidget {
  final String message;

  const _IssueErrorView({required this.message});

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
              'Failed to load issue',
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
