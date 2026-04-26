enum ChatContextAttachmentSource { github }

enum GitHubAttachmentKind {
  issue,
  issueComment,
  pullRequest,
  pullRequestComment,
  pullRequestFile,
}

/// A reference to external context (currently only GitHub items) that the
/// chat surfaces attach to the next message sent to Claude. The mobile app
/// no longer constructs these from in-app browsers; instead Claude /
/// workbuddy surface GitHub state through the chat itself.
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
}
