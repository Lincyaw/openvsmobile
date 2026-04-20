import 'github_auth_models.dart';

class GitHubRepositoryContext {
  final int? id;
  final String githubHost;
  final String owner;
  final String name;
  final String fullName;
  final String remoteName;
  final String remoteUrl;
  final String repoRoot;
  final bool isPrivate;

  const GitHubRepositoryContext({
    required this.id,
    required this.githubHost,
    required this.owner,
    required this.name,
    required this.fullName,
    required this.remoteName,
    required this.remoteUrl,
    required this.repoRoot,
    required this.isPrivate,
  });

  factory GitHubRepositoryContext.fromJson(Map<String, dynamic> json) {
    return GitHubRepositoryContext(
      id: _readNullableInt(json['id']),
      githubHost: (json['github_host'] as String?)?.trim() ?? 'github.com',
      owner: _readOwner(json['owner']),
      name: (json['name'] as String?)?.trim() ?? '',
      fullName: (json['full_name'] as String?)?.trim() ?? '',
      remoteName: (json['remote_name'] as String?)?.trim() ?? '',
      remoteUrl: (json['remote_url'] as String?)?.trim() ?? '',
      repoRoot: (json['repo_root'] as String?)?.trim() ?? '',
      isPrivate: json['private'] == true,
    );
  }
}

class GitHubCurrentRepoContext {
  final String status;
  final String? errorCode;
  final GitHubRepositoryContext? repository;
  final GitHubAuthStatus? auth;
  final String? message;

  const GitHubCurrentRepoContext({
    required this.status,
    required this.errorCode,
    required this.repository,
    required this.auth,
    required this.message,
  });

  bool get isOk => status == 'ok';

  bool get needsAuthAction =>
      status == 'not_authenticated' || status == 'reauth_required';

  bool get isRepoUnavailable =>
      status == 'repo_not_github' ||
      status == 'repo_access_unavailable' ||
      status == 'app_not_installed_for_repo';

  factory GitHubCurrentRepoContext.fromJson(Map<String, dynamic> json) {
    return GitHubCurrentRepoContext(
      status: (json['status'] as String?)?.trim() ?? 'repo_not_github',
      errorCode: (json['error_code'] as String?)?.trim(),
      repository: json['repository'] is Map<String, dynamic>
          ? GitHubRepositoryContext.fromJson(
              json['repository'] as Map<String, dynamic>,
            )
          : null,
      auth: json['auth'] is Map<String, dynamic>
          ? GitHubAuthStatus.fromJson(json['auth'] as Map<String, dynamic>)
          : null,
      message: (json['message'] as String?)?.trim(),
    );
  }
}

class GitHubAccount {
  final String login;
  final int id;
  final String name;
  final String avatarUrl;
  final String htmlUrl;

  const GitHubAccount({
    required this.login,
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.htmlUrl,
  });

  factory GitHubAccount.fromJson(Map<String, dynamic> json) {
    return GitHubAccount(
      login: (json['login'] as String?)?.trim() ?? '',
      id: _readInt(json['id']),
      name: (json['name'] as String?)?.trim() ?? '',
      avatarUrl: (json['avatar_url'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
    );
  }
}

class GitHubAccountContext {
  final GitHubRepositoryContext repository;
  final GitHubAccount account;

  const GitHubAccountContext({required this.repository, required this.account});

  factory GitHubAccountContext.fromJson(Map<String, dynamic> json) {
    return GitHubAccountContext(
      repository: GitHubRepositoryContext.fromJson(
        json['repository'] as Map<String, dynamic>? ?? const {},
      ),
      account: GitHubAccount.fromJson(
        json['account'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }
}

class GitHubActor {
  final String login;
  final int id;
  final String avatarUrl;
  final String htmlUrl;

  const GitHubActor({
    required this.login,
    required this.id,
    required this.avatarUrl,
    required this.htmlUrl,
  });

  factory GitHubActor.fromJson(Map<String, dynamic> json) {
    return GitHubActor(
      login: (json['login'] as String?)?.trim() ?? '',
      id: _readInt(json['id']),
      avatarUrl: (json['avatar_url'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
    );
  }
}

class GitHubLabel {
  final String name;
  final String color;

  const GitHubLabel({required this.name, required this.color});

  factory GitHubLabel.fromJson(Map<String, dynamic> json) {
    return GitHubLabel(
      name: (json['name'] as String?)?.trim() ?? '',
      color: (json['color'] as String?)?.trim() ?? '',
    );
  }
}

class GitHubPullRequestRef {
  final String label;
  final String ref;
  final String sha;

  const GitHubPullRequestRef({
    required this.label,
    required this.ref,
    required this.sha,
  });

  factory GitHubPullRequestRef.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestRef(
      label: (json['label'] as String?)?.trim() ?? '',
      ref: (json['ref'] as String?)?.trim() ?? '',
      sha: (json['sha'] as String?)?.trim() ?? '',
    );
  }
}

class GitHubPullRequestCheckRun {
  final String name;
  final String status;
  final String conclusion;
  final String detailsUrl;
  final DateTime? startedAt;
  final DateTime? completedAt;

  const GitHubPullRequestCheckRun({
    required this.name,
    required this.status,
    required this.conclusion,
    required this.detailsUrl,
    required this.startedAt,
    required this.completedAt,
  });

  factory GitHubPullRequestCheckRun.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestCheckRun(
      name: (json['name'] as String?)?.trim() ?? '',
      status: (json['status'] as String?)?.trim() ?? '',
      conclusion: (json['conclusion'] as String?)?.trim() ?? '',
      detailsUrl: (json['details_url'] as String?)?.trim() ?? '',
      startedAt: _readDateTime(json['started_at']),
      completedAt: _readDateTime(json['completed_at']),
    );
  }
}

class GitHubPullRequestChecks {
  final String state;
  final int totalCount;
  final int successCount;
  final int pendingCount;
  final int failureCount;
  final List<GitHubPullRequestCheckRun> checks;

  const GitHubPullRequestChecks({
    required this.state,
    required this.totalCount,
    required this.successCount,
    required this.pendingCount,
    required this.failureCount,
    required this.checks,
  });

  factory GitHubPullRequestChecks.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestChecks(
      state: (json['state'] as String?)?.trim() ?? 'unknown',
      totalCount: _readInt(json['total_count']),
      successCount: _readInt(json['success_count']),
      pendingCount: _readInt(json['pending_count']),
      failureCount: _readInt(json['failure_count']),
      checks: _mapList(
        json['checks'],
        (item) => GitHubPullRequestCheckRun.fromJson(item),
      ),
    );
  }
}

class GitHubIssue {
  final int number;
  final String title;
  final String state;
  final String body;
  final String htmlUrl;
  final int commentsCount;
  final bool locked;
  final GitHubActor? author;
  final List<GitHubActor> assignees;
  final List<GitHubLabel> labels;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? closedAt;

  const GitHubIssue({
    required this.number,
    required this.title,
    required this.state,
    required this.body,
    required this.htmlUrl,
    required this.commentsCount,
    required this.locked,
    required this.author,
    required this.assignees,
    required this.labels,
    required this.createdAt,
    required this.updatedAt,
    required this.closedAt,
  });

  factory GitHubIssue.fromJson(Map<String, dynamic> json) {
    return GitHubIssue(
      number: _readInt(json['number']),
      title: (json['title'] as String?)?.trim() ?? '',
      state: (json['state'] as String?)?.trim() ?? '',
      body: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
      commentsCount: _readInt(json['comments_count']),
      locked: json['locked'] == true,
      author: json['author'] is Map<String, dynamic>
          ? GitHubActor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      assignees: _mapList(
        json['assignees'],
        (item) => GitHubActor.fromJson(item),
      ),
      labels: _mapList(json['labels'], (item) => GitHubLabel.fromJson(item)),
      createdAt: _readDateTime(json['created_at']),
      updatedAt: _readDateTime(json['updated_at']),
      closedAt: _readDateTime(json['closed_at']),
    );
  }
}

class GitHubIssueComment {
  final int id;
  final String body;
  final String htmlUrl;
  final GitHubActor? author;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const GitHubIssueComment({
    required this.id,
    required this.body,
    required this.htmlUrl,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
  });

  factory GitHubIssueComment.fromJson(Map<String, dynamic> json) {
    return GitHubIssueComment(
      id: _readInt(json['id']),
      body: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
      author: json['author'] is Map<String, dynamic>
          ? GitHubActor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      createdAt: _readDateTime(json['created_at']),
      updatedAt: _readDateTime(json['updated_at']),
    );
  }
}

class GitHubIssueDetail {
  final GitHubIssue issue;
  final List<GitHubIssueComment> comments;

  const GitHubIssueDetail({required this.issue, required this.comments});

  factory GitHubIssueDetail.fromJson(Map<String, dynamic> json) {
    return GitHubIssueDetail(
      issue: GitHubIssue.fromJson(
        json['issue'] as Map<String, dynamic>? ?? const {},
      ),
      comments: _mapList(
        json['comments'],
        (item) => GitHubIssueComment.fromJson(item),
      ),
    );
  }
}

class GitHubPullRequest {
  final int number;
  final String title;
  final String state;
  final String body;
  final String htmlUrl;
  final bool draft;
  final bool merged;
  final bool? mergeable;
  final String mergeableState;
  final int commentsCount;
  final int reviewCommentsCount;
  final int commitsCount;
  final int additions;
  final int deletions;
  final int changedFiles;
  final GitHubActor? author;
  final List<GitHubActor> assignees;
  final List<GitHubLabel> labels;
  final GitHubPullRequestRef baseRef;
  final GitHubPullRequestRef headRef;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? closedAt;
  final DateTime? mergedAt;
  final GitHubPullRequestChecks? checks;

  const GitHubPullRequest({
    required this.number,
    required this.title,
    required this.state,
    required this.body,
    required this.htmlUrl,
    required this.draft,
    required this.merged,
    required this.mergeable,
    required this.mergeableState,
    required this.commentsCount,
    required this.reviewCommentsCount,
    required this.commitsCount,
    required this.additions,
    required this.deletions,
    required this.changedFiles,
    required this.author,
    required this.assignees,
    required this.labels,
    required this.baseRef,
    required this.headRef,
    required this.createdAt,
    required this.updatedAt,
    required this.closedAt,
    required this.mergedAt,
    required this.checks,
  });

  factory GitHubPullRequest.fromJson(Map<String, dynamic> json) {
    final mergeableValue = json['mergeable'];
    bool? mergeable;
    if (mergeableValue is bool) {
      mergeable = mergeableValue;
    }

    return GitHubPullRequest(
      number: _readInt(json['number']),
      title: (json['title'] as String?)?.trim() ?? '',
      state: (json['state'] as String?)?.trim() ?? '',
      body: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
      draft: json['draft'] == true,
      merged: json['merged'] == true,
      mergeable: mergeable,
      mergeableState: (json['mergeable_state'] as String?)?.trim() ?? '',
      commentsCount: _readInt(json['comments_count']),
      reviewCommentsCount: _readInt(json['review_comments_count']),
      commitsCount: _readInt(json['commits_count']),
      additions: _readInt(json['additions']),
      deletions: _readInt(json['deletions']),
      changedFiles: _readInt(json['changed_files']),
      author: json['author'] is Map<String, dynamic>
          ? GitHubActor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      assignees: _mapList(
        json['assignees'],
        (item) => GitHubActor.fromJson(item),
      ),
      labels: _mapList(json['labels'], (item) => GitHubLabel.fromJson(item)),
      baseRef: GitHubPullRequestRef.fromJson(
        json['base_ref'] as Map<String, dynamic>? ?? const {},
      ),
      headRef: GitHubPullRequestRef.fromJson(
        json['head_ref'] as Map<String, dynamic>? ?? const {},
      ),
      createdAt: _readDateTime(json['created_at']),
      updatedAt: _readDateTime(json['updated_at']),
      closedAt: _readDateTime(json['closed_at']),
      mergedAt: _readDateTime(json['merged_at']),
      checks: json['checks'] is Map<String, dynamic>
          ? GitHubPullRequestChecks.fromJson(
              json['checks'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

class GitHubPullRequestFile {
  final String sha;
  final String filename;
  final String status;
  final int additions;
  final int deletions;
  final int changes;
  final String blobUrl;
  final String rawUrl;
  final String patch;
  final String previousFilename;

  const GitHubPullRequestFile({
    required this.sha,
    required this.filename,
    required this.status,
    required this.additions,
    required this.deletions,
    required this.changes,
    required this.blobUrl,
    required this.rawUrl,
    required this.patch,
    required this.previousFilename,
  });

  factory GitHubPullRequestFile.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestFile(
      sha: (json['sha'] as String?)?.trim() ?? '',
      filename: (json['filename'] as String?)?.trim() ?? '',
      status: (json['status'] as String?)?.trim() ?? '',
      additions: _readInt(json['additions']),
      deletions: _readInt(json['deletions']),
      changes: _readInt(json['changes']),
      blobUrl: (json['blob_url'] as String?)?.trim() ?? '',
      rawUrl: (json['raw_url'] as String?)?.trim() ?? '',
      patch: (json['patch'] as String?) ?? '',
      previousFilename: (json['previous_filename'] as String?)?.trim() ?? '',
    );
  }
}

class GitHubPullRequestComment {
  final int id;
  final String body;
  final String htmlUrl;
  final String path;
  final String diffHunk;
  final String commitId;
  final String originalCommitId;
  final int position;
  final int originalPosition;
  final int line;
  final int originalLine;
  final String side;
  final int startLine;
  final String startSide;
  final int inReplyToId;
  final GitHubActor? author;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const GitHubPullRequestComment({
    required this.id,
    required this.body,
    required this.htmlUrl,
    required this.path,
    required this.diffHunk,
    required this.commitId,
    required this.originalCommitId,
    required this.position,
    required this.originalPosition,
    required this.line,
    required this.originalLine,
    required this.side,
    required this.startLine,
    required this.startSide,
    required this.inReplyToId,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isInline => path.isNotEmpty || line > 0 || diffHunk.isNotEmpty;

  factory GitHubPullRequestComment.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestComment(
      id: _readInt(json['id']),
      body: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
      path: (json['path'] as String?)?.trim() ?? '',
      diffHunk: (json['diff_hunk'] as String?) ?? '',
      commitId: (json['commit_id'] as String?)?.trim() ?? '',
      originalCommitId: (json['original_commit_id'] as String?)?.trim() ?? '',
      position: _readInt(json['position']),
      originalPosition: _readInt(json['original_position']),
      line: _readInt(json['line']),
      originalLine: _readInt(json['original_line']),
      side: (json['side'] as String?)?.trim() ?? '',
      startLine: _readInt(json['start_line']),
      startSide: (json['start_side'] as String?)?.trim() ?? '',
      inReplyToId: _readInt(json['in_reply_to_id']),
      author: json['author'] is Map<String, dynamic>
          ? GitHubActor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      createdAt: _readDateTime(json['created_at']),
      updatedAt: _readDateTime(json['updated_at']),
    );
  }
}

class GitHubPullRequestReview {
  final int id;
  final String body;
  final String state;
  final String commitId;
  final String htmlUrl;
  final GitHubActor? author;
  final DateTime? submittedAt;

  const GitHubPullRequestReview({
    required this.id,
    required this.body,
    required this.state,
    required this.commitId,
    required this.htmlUrl,
    required this.author,
    required this.submittedAt,
  });

  factory GitHubPullRequestReview.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestReview(
      id: _readInt(json['id']),
      body: (json['body'] as String?)?.trim() ?? '',
      state: (json['state'] as String?)?.trim() ?? '',
      commitId: (json['commit_id'] as String?)?.trim() ?? '',
      htmlUrl: (json['html_url'] as String?)?.trim() ?? '',
      author: json['author'] is Map<String, dynamic>
          ? GitHubActor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      submittedAt: _readDateTime(json['submitted_at']),
    );
  }
}

class GitHubPullRequestDetail {
  final GitHubPullRequest pullRequest;
  final List<GitHubPullRequestFile> files;
  final List<GitHubPullRequestComment> comments;
  final List<GitHubPullRequestReview> reviews;

  const GitHubPullRequestDetail({
    required this.pullRequest,
    required this.files,
    required this.comments,
    required this.reviews,
  });

  factory GitHubPullRequestDetail.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestDetail(
      pullRequest: GitHubPullRequest.fromJson(
        json['pull_request'] as Map<String, dynamic>? ?? const {},
      ),
      files: _mapList(
        json['files'],
        (item) => GitHubPullRequestFile.fromJson(item),
      ),
      comments: _mapList(
        json['comments'],
        (item) => GitHubPullRequestComment.fromJson(item),
      ),
      reviews: _mapList(
        json['reviews'],
        (item) => GitHubPullRequestReview.fromJson(item),
      ),
    );
  }
}

class GitHubPullRequestConversation {
  final List<GitHubPullRequestComment> comments;
  final List<GitHubPullRequestReview> reviews;

  const GitHubPullRequestConversation({
    required this.comments,
    required this.reviews,
  });

  factory GitHubPullRequestConversation.fromJson(Map<String, dynamic> json) {
    return GitHubPullRequestConversation(
      comments: _mapList(
        json['comments'],
        (item) => GitHubPullRequestComment.fromJson(item),
      ),
      reviews: _mapList(
        json['reviews'],
        (item) => GitHubPullRequestReview.fromJson(item),
      ),
    );
  }
}

class GitHubResolveLocalFileResult {
  final String repoRoot;
  final String relativePath;
  final String localPath;
  final bool exists;

  const GitHubResolveLocalFileResult({
    required this.repoRoot,
    required this.relativePath,
    required this.localPath,
    required this.exists,
  });

  factory GitHubResolveLocalFileResult.fromJson(Map<String, dynamic> json) {
    return GitHubResolveLocalFileResult(
      repoRoot: (json['repo_root'] as String?)?.trim() ?? '',
      relativePath: (json['relative_path'] as String?)?.trim() ?? '',
      localPath: (json['local_path'] as String?)?.trim() ?? '',
      exists: json['exists'] == true,
    );
  }
}

class GitHubCollaborationFilter {
  final String state;
  final bool assignedToMe;
  final bool createdByMe;
  final bool mentioned;
  final bool needsReview;
  final int? page;
  final int? perPage;

  const GitHubCollaborationFilter({
    this.state = '',
    this.assignedToMe = false,
    this.createdByMe = false,
    this.mentioned = false,
    this.needsReview = false,
    this.page,
    this.perPage,
  });

  GitHubCollaborationFilter copyWith({
    String? state,
    bool? assignedToMe,
    bool? createdByMe,
    bool? mentioned,
    bool? needsReview,
    int? page,
    int? perPage,
  }) {
    return GitHubCollaborationFilter(
      state: state ?? this.state,
      assignedToMe: assignedToMe ?? this.assignedToMe,
      createdByMe: createdByMe ?? this.createdByMe,
      mentioned: mentioned ?? this.mentioned,
      needsReview: needsReview ?? this.needsReview,
      page: page ?? this.page,
      perPage: perPage ?? this.perPage,
    );
  }

  Map<String, String> toQueryParameters({bool includeNeedsReview = true}) {
    final params = <String, String>{};
    if (state.trim().isNotEmpty) {
      params['state'] = state.trim();
    }
    if (assignedToMe) {
      params['assigned_to_me'] = 'true';
    }
    if (createdByMe) {
      params['created_by_me'] = 'true';
    }
    if (mentioned) {
      params['mentioned'] = 'true';
    }
    if (includeNeedsReview && needsReview) {
      params['needs_review'] = 'true';
    }
    if (page != null && page! > 0) {
      params['page'] = '${page!}';
    }
    if (perPage != null && perPage! > 0) {
      params['per_page'] = '${perPage!}';
    }
    return params;
  }
}

class GitHubIssueCommentInput {
  final String body;

  const GitHubIssueCommentInput({required this.body});
}

class GitHubPullRequestCommentInput {
  final String body;
  final String path;
  final String commitId;
  final String side;
  final String startSide;
  final int? line;
  final int? startLine;
  final int? inReplyTo;

  const GitHubPullRequestCommentInput({
    required this.body,
    this.path = '',
    this.commitId = '',
    this.side = '',
    this.startSide = '',
    this.line,
    this.startLine,
    this.inReplyTo,
  });

  Map<String, dynamic> toJson(String workspacePath) {
    return <String, dynamic>{
      'workspace_path': workspacePath,
      'body': body,
      if (path.trim().isNotEmpty) 'path': path.trim(),
      if (commitId.trim().isNotEmpty) 'commit_id': commitId.trim(),
      if (side.trim().isNotEmpty) 'side': side.trim(),
      if (startSide.trim().isNotEmpty) 'start_side': startSide.trim(),
      if (line != null && line! > 0) 'line': line,
      if (startLine != null && startLine! > 0) 'start_line': startLine,
      if (inReplyTo != null && inReplyTo! > 0) 'in_reply_to': inReplyTo,
    };
  }
}

class GitHubPullRequestReviewDraftComment {
  final String body;
  final String path;
  final String side;
  final String startSide;
  final int? line;
  final int? startLine;

  const GitHubPullRequestReviewDraftComment({
    required this.body,
    this.path = '',
    this.side = '',
    this.startSide = '',
    this.line,
    this.startLine,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'body': body,
      if (path.trim().isNotEmpty) 'path': path.trim(),
      if (side.trim().isNotEmpty) 'side': side.trim(),
      if (startSide.trim().isNotEmpty) 'start_side': startSide.trim(),
      if (line != null && line! > 0) 'line': line,
      if (startLine != null && startLine! > 0) 'start_line': startLine,
    };
  }
}

class GitHubPullRequestReviewInput {
  final String event;
  final String body;
  final String commitId;
  final List<GitHubPullRequestReviewDraftComment> comments;

  const GitHubPullRequestReviewInput({
    required this.event,
    this.body = '',
    this.commitId = '',
    this.comments = const [],
  });

  Map<String, dynamic> toJson(String workspacePath) {
    return <String, dynamic>{
      'workspace_path': workspacePath,
      'event': event.trim().toUpperCase(),
      if (body.trim().isNotEmpty) 'body': body.trim(),
      if (commitId.trim().isNotEmpty) 'commit_id': commitId.trim(),
      if (comments.isNotEmpty)
        'comments': comments.map((comment) => comment.toJson()).toList(),
    };
  }
}

class GitHubCollaborationException implements Exception {
  final int statusCode;
  final String errorCode;
  final String message;

  const GitHubCollaborationException({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  bool get needsAuthAction =>
      errorCode == 'not_authenticated' || errorCode == 'reauth_required';

  String toDisplayMessage() {
    switch (errorCode) {
      case 'github_auth_disabled':
        return 'GitHub collaboration is not enabled on this server.';
      case 'not_authenticated':
        return 'GitHub is not connected on this server yet.';
      case 'reauth_required':
        return 'Your GitHub session expired. Reconnect to continue.';
      case 'repo_not_github':
        return 'The current workspace is not backed by a GitHub repository.';
      case 'repo_access_unavailable':
        return 'The connected account cannot access this repository.';
      case 'app_not_installed_for_repo':
        return 'The configured GitHub App is not installed for this repository.';
      case 'not_found':
        return 'The requested GitHub resource could not be found.';
      default:
        return message;
    }
  }

  @override
  String toString() {
    return 'GitHubCollaborationException($statusCode, $errorCode): $message';
  }
}

List<T> _mapList<T>(
  Object? value,
  T Function(Map<String, dynamic> item) builder,
) {
  if (value is! List) {
    return List<T>.empty(growable: false);
  }
  return value
      .whereType<Map<String, dynamic>>()
      .map(builder)
      .toList(growable: false);
}

String _readOwner(Object? rawOwner) {
  if (rawOwner is String) {
    return rawOwner.trim();
  }
  if (rawOwner is Map<String, dynamic>) {
    return (rawOwner['login'] as String?)?.trim() ?? '';
  }
  return '';
}

int _readInt(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

int? _readNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  return _readInt(value);
}

DateTime? _readDateTime(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}
