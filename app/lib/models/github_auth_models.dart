class GitHubDeviceFlowStartResponse {
  final String githubHost;
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;

  const GitHubDeviceFlowStartResponse({
    required this.githubHost,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  factory GitHubDeviceFlowStartResponse.fromJson(Map<String, dynamic> json) {
    return GitHubDeviceFlowStartResponse(
      githubHost: (json['github_host'] as String?)?.trim() ?? 'github.com',
      deviceCode: (json['device_code'] as String?)?.trim() ?? '',
      userCode: (json['user_code'] as String?)?.trim() ?? '',
      verificationUri: (json['verification_uri'] as String?)?.trim() ?? '',
      expiresIn: _readInt(json['expires_in']),
      interval: _readInt(json['interval'], fallback: 5),
    );
  }
}

typedef GitHubDeviceCode = GitHubDeviceFlowStartResponse;

enum GitHubAuthPollStatus { pending, authorized, error }

class GitHubAuthStatus {
  final bool authenticated;
  final String githubHost;
  final String? accountLogin;
  final int? accountId;
  final DateTime? accessTokenExpiresAt;
  final DateTime? refreshTokenExpiresAt;
  final bool needsRefresh;
  final bool needsReauth;

  const GitHubAuthStatus({
    required this.authenticated,
    required this.githubHost,
    this.accountLogin,
    this.accountId,
    this.accessTokenExpiresAt,
    this.refreshTokenExpiresAt,
    required this.needsRefresh,
    required this.needsReauth,
  });

  bool get hasAccount =>
      (accountLogin?.isNotEmpty ?? false) || accountId != null;

  factory GitHubAuthStatus.fromJson(Map<String, dynamic> json) {
    return GitHubAuthStatus(
      authenticated: json['authenticated'] == true,
      githubHost: (json['github_host'] as String?)?.trim() ?? 'github.com',
      accountLogin: (json['account_login'] as String?)?.trim(),
      accountId: _readNullableInt(json['account_id']),
      accessTokenExpiresAt: _readDateTime(json['access_token_expires_at']),
      refreshTokenExpiresAt: _readDateTime(json['refresh_token_expires_at']),
      needsRefresh: json['needs_refresh'] == true,
      needsReauth: json['needs_reauth'] == true,
    );
  }
}

class GitHubAuthPollResponse {
  final GitHubAuthPollStatus status;
  final String githubHost;
  final GitHubAuthStatus? auth;
  final String? errorCode;
  final String? message;

  const GitHubAuthPollResponse({
    required this.status,
    required this.githubHost,
    this.auth,
    this.errorCode,
    this.message,
  });

  bool get isPending => status == GitHubAuthPollStatus.pending;
  bool get isAuthorized => status == GitHubAuthPollStatus.authorized;
  bool get isError => status == GitHubAuthPollStatus.error;

  factory GitHubAuthPollResponse.fromJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] as String?)?.trim() ?? 'error';
    return GitHubAuthPollResponse(
      status: switch (rawStatus) {
        'pending' => GitHubAuthPollStatus.pending,
        'authorized' => GitHubAuthPollStatus.authorized,
        _ => GitHubAuthPollStatus.error,
      },
      githubHost: (json['github_host'] as String?)?.trim() ?? 'github.com',
      auth: json['auth'] is Map<String, dynamic>
          ? GitHubAuthStatus.fromJson(json['auth'] as Map<String, dynamic>)
          : null,
      errorCode: (json['error_code'] as String?)?.trim(),
      message: (json['message'] as String?)?.trim(),
    );
  }
}

typedef GitHubPollResponse = GitHubAuthPollResponse;

class GitHubDisconnectResponse {
  final bool disconnected;
  final String githubHost;

  const GitHubDisconnectResponse({
    required this.disconnected,
    required this.githubHost,
  });

  factory GitHubDisconnectResponse.fromJson(Map<String, dynamic> json) {
    return GitHubDisconnectResponse(
      disconnected: json['disconnected'] == true,
      githubHost: (json['github_host'] as String?)?.trim() ?? 'github.com',
    );
  }
}

enum GitHubRepoAvailabilityState {
  unknown,
  checking,
  backendContractMissing,
  localGitRepository,
  workspaceNotGitRepository,
  workspaceUnavailable,
}

class GitHubRepoAvailability {
  final GitHubRepoAvailabilityState state;
  final String title;
  final String message;
  final String? workspacePath;

  const GitHubRepoAvailability({
    required this.state,
    required this.title,
    required this.message,
    this.workspacePath,
  });

  const GitHubRepoAvailability.unknown({this.workspacePath})
    : state = GitHubRepoAvailabilityState.unknown,
      title = 'Workspace repo status unavailable',
      message = 'The app has not checked the current workspace repo yet.';

  const GitHubRepoAvailability.checking({this.workspacePath})
    : state = GitHubRepoAvailabilityState.checking,
      title = 'Checking workspace repo',
      message =
          'Inspecting the current workspace to see whether Git is available.';

  factory GitHubRepoAvailability.backendContractMissing({
    required String workspacePath,
  }) {
    return GitHubRepoAvailability(
      state: GitHubRepoAvailabilityState.backendContractMissing,
      title: 'Repo access cannot be confirmed yet',
      message:
          'The current backend auth contract does not expose GitHub App installation or repo-access metadata for $workspacePath, so the app can only confirm the local workspace path.',
      workspacePath: workspacePath,
    );
  }

  factory GitHubRepoAvailability.localGitRepository({
    required String workspacePath,
  }) {
    return GitHubRepoAvailability(
      state: GitHubRepoAvailabilityState.localGitRepository,
      title: 'Local Git repository detected',
      message:
          'Git is available in $workspacePath, but the backend still does not expose whether the connected GitHub account or app can access that repository remotely.',
      workspacePath: workspacePath,
    );
  }

  factory GitHubRepoAvailability.workspaceNotGitRepository({
    required String workspacePath,
    required String details,
  }) {
    return GitHubRepoAvailability(
      state: GitHubRepoAvailabilityState.workspaceNotGitRepository,
      title: 'Current workspace is not a Git repository',
      message: '$workspacePath is not reporting Git metadata yet. $details',
      workspacePath: workspacePath,
    );
  }

  factory GitHubRepoAvailability.workspaceUnavailable({
    required String workspacePath,
    required String details,
  }) {
    return GitHubRepoAvailability(
      state: GitHubRepoAvailabilityState.workspaceUnavailable,
      title: 'Workspace repo check failed',
      message:
          'The app could not inspect $workspacePath for Git availability. $details',
      workspacePath: workspacePath,
    );
  }
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
