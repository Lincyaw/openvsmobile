import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/chat_context_attachment.dart';
import '../models/github_collaboration_models.dart';
import '../navigation/github_chat_navigation.dart';
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
                    _IssueHeader(
                      issue: detail.issue,
                      onAiOverview: () => _openIssueAi(
                        detail,
                        action: 'issue_overview',
                        prompt:
                            'Summarize the key context and next steps for this GitHub issue.',
                      ),
                      onAiReply: () => _openIssueAi(
                        detail,
                        action: 'issue_reply',
                        prompt:
                            'Draft a helpful response or implementation plan for this GitHub issue.',
                      ),
                    ),
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
                        (comment) => _IssueCommentCard(
                          comment: comment,
                          onAiReply: () => _openIssueCommentAi(detail, comment),
                        ),
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

  Future<void> _openIssueAi(
    GitHubIssueDetail detail, {
    required String action,
    required String prompt,
  }) async {
    final repository = context
        .read<GitHubCollaborationProvider>()
        .repoContext
        ?.repository;
    if (repository == null) {
      return;
    }

    await openChatWithGitHubAttachment(
      context,
      prompt: prompt,
      attachment: GitHubChatAttachment.issueBody(
        repository: repository,
        issue: detail.issue,
        action: action,
      ),
    );
  }

  Future<void> _openIssueCommentAi(
    GitHubIssueDetail detail,
    GitHubIssueComment comment,
  ) async {
    final repository = context
        .read<GitHubCollaborationProvider>()
        .repoContext
        ?.repository;
    if (repository == null) {
      return;
    }

    await openChatWithGitHubAttachment(
      context,
      prompt: 'Draft a response to this GitHub issue comment.',
      attachment: GitHubChatAttachment.issueComment(
        repository: repository,
        issue: detail.issue,
        comment: comment,
      ),
    );
  }
}

class _IssueHeader extends StatelessWidget {
  final GitHubIssue issue;
  final VoidCallback onAiOverview;
  final VoidCallback onAiReply;

  const _IssueHeader({
    required this.issue,
    required this.onAiOverview,
    required this.onAiReply,
  });

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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onAiOverview,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Summarize issue'),
                ),
                OutlinedButton.icon(
                  onPressed: onAiReply,
                  icon: const Icon(Icons.mode_comment_outlined),
                  label: const Text('Draft reply'),
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
  final VoidCallback onAiReply;

  const _IssueCommentCard({required this.comment, required this.onAiReply});

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    comment.author?.login.isNotEmpty == true
                        ? comment.author!.login
                        : 'Unknown author',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: onAiReply,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Check comment'),
                ),
              ],
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
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Add a comment',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: isSubmitting ? null : onSubmit,
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
