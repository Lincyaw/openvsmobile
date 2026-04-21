import 'github_collaboration_models.dart';

enum ChatContextAttachmentSource { github }

enum GitHubAttachmentKind {
  issue,
  issueComment,
  pullRequest,
  pullRequestComment,
  pullRequestFile,
}

class ChatContextAttachment {
  final ChatContextAttachmentSource source;
  final GitHubAttachmentKind kind;
  final String actionLabel;
  final String reference;
  final String title;
  final String body;
  final String? repositoryFullName;
  final String? path;
  final String? authorLogin;
  final String? url;

  const ChatContextAttachment({
    required this.source,
    required this.kind,
    required this.actionLabel,
    required this.reference,
    required this.title,
    required this.body,
    this.repositoryFullName,
    this.path,
    this.authorLogin,
    this.url,
  });

  String get sourceLabel => 'GitHub';

  String get kindLabel => switch (kind) {
    GitHubAttachmentKind.issue => 'Issue',
    GitHubAttachmentKind.issueComment => 'Issue comment',
    GitHubAttachmentKind.pullRequest => 'Pull request',
    GitHubAttachmentKind.pullRequestComment => 'PR review comment',
    GitHubAttachmentKind.pullRequestFile => 'PR file',
  };

  List<String> get previewDetails => <String>[
    if (repositoryFullName != null && repositoryFullName!.isNotEmpty)
      repositoryFullName!,
    reference,
    if (path != null && path!.isNotEmpty) 'Path: $path',
    if (authorLogin != null && authorLogin!.isNotEmpty) 'Author: $authorLogin',
    if (body.isNotEmpty) excerpt(body),
  ];

  Map<String, dynamic> toTransportJson() {
    return <String, dynamic>{
      'source': 'github',
      'kind': _kindTransportValue(kind),
      'action': actionLabel,
      'reference': reference,
      'title': title,
      'body': body,
      if (repositoryFullName != null && repositoryFullName!.isNotEmpty)
        'repository': repositoryFullName,
      if (path != null && path!.isNotEmpty) 'path': path,
      if (authorLogin != null && authorLogin!.isNotEmpty) 'author': authorLogin,
      if (url != null && url!.isNotEmpty) 'url': url,
    };
  }

  static String excerpt(String text, {int maxLength = 280}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength - 1)}...';
  }

  static String _kindTransportValue(GitHubAttachmentKind kind) {
    return switch (kind) {
      GitHubAttachmentKind.issue => 'issue',
      GitHubAttachmentKind.issueComment => 'issue_comment',
      GitHubAttachmentKind.pullRequest => 'pull_request',
      GitHubAttachmentKind.pullRequestComment => 'pull_request_comment',
      GitHubAttachmentKind.pullRequestFile => 'pull_request_file',
    };
  }
}

class GitHubChatAttachment extends ChatContextAttachment {
  const GitHubChatAttachment({
    required super.kind,
    required super.actionLabel,
    required super.reference,
    required super.title,
    required super.body,
    super.repositoryFullName,
    super.path,
    super.authorLogin,
    super.url,
  }) : super(source: ChatContextAttachmentSource.github);

  factory GitHubChatAttachment.issueBody({
    required GitHubRepositoryContext repository,
    required GitHubIssue issue,
    required String action,
  }) {
    return GitHubChatAttachment(
      kind: GitHubAttachmentKind.issue,
      actionLabel: _actionLabel(action, fallback: 'Summarize issue'),
      reference: 'Issue #${issue.number}',
      title: issue.title,
      body: ChatContextAttachment.excerpt(issue.body),
      repositoryFullName: repository.fullName,
      authorLogin: issue.author?.login,
      url: issue.htmlUrl,
    );
  }

  factory GitHubChatAttachment.issueComment({
    required GitHubRepositoryContext repository,
    required GitHubIssue issue,
    required GitHubIssueComment comment,
  }) {
    return GitHubChatAttachment(
      kind: GitHubAttachmentKind.issueComment,
      actionLabel: 'Check comment',
      reference: 'Issue #${issue.number}',
      title: issue.title,
      body: ChatContextAttachment.excerpt(comment.body),
      repositoryFullName: repository.fullName,
      authorLogin: comment.author?.login,
      url: comment.htmlUrl.isNotEmpty ? comment.htmlUrl : issue.htmlUrl,
    );
  }

  factory GitHubChatAttachment.pullRequestBody({
    required GitHubRepositoryContext repository,
    required GitHubPullRequest pullRequest,
    required String action,
  }) {
    return GitHubChatAttachment(
      kind: GitHubAttachmentKind.pullRequest,
      actionLabel: _actionLabel(action, fallback: 'Summarize PR'),
      reference: 'PR #${pullRequest.number}',
      title: pullRequest.title,
      body: ChatContextAttachment.excerpt(pullRequest.body),
      repositoryFullName: repository.fullName,
      authorLogin: pullRequest.author?.login,
      url: pullRequest.htmlUrl,
    );
  }

  factory GitHubChatAttachment.pullRequestComment({
    required GitHubRepositoryContext repository,
    required GitHubPullRequest pullRequest,
    required GitHubPullRequestComment comment,
  }) {
    return GitHubChatAttachment(
      kind: GitHubAttachmentKind.pullRequestComment,
      actionLabel: 'Check comment',
      reference: 'PR #${pullRequest.number}',
      title: pullRequest.title,
      body: ChatContextAttachment.excerpt(comment.body),
      repositoryFullName: repository.fullName,
      path: comment.path,
      authorLogin: comment.author?.login,
      url: comment.htmlUrl.isNotEmpty ? comment.htmlUrl : pullRequest.htmlUrl,
    );
  }

  factory GitHubChatAttachment.pullRequestFile({
    required GitHubRepositoryContext repository,
    required GitHubPullRequest pullRequest,
    required GitHubPullRequestFile file,
  }) {
    return GitHubChatAttachment(
      kind: GitHubAttachmentKind.pullRequestFile,
      actionLabel: 'Review file',
      reference: 'PR #${pullRequest.number}',
      title: pullRequest.title,
      body: ChatContextAttachment.excerpt(file.patch),
      repositoryFullName: repository.fullName,
      path: file.filename,
      url: pullRequest.htmlUrl,
    );
  }

  static String _actionLabel(String action, {required String fallback}) {
    switch (action) {
      case 'issue_reply':
        return 'Draft reply';
      case 'pull_request_review':
        return 'AI review';
      default:
        return fallback;
    }
  }
}
