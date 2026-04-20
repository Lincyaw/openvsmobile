import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/github_auth_models.dart';
import '../services/git_api_client.dart';
import '../services/github_auth_api_client.dart';

const _defaultGitHubHost = 'github.com';

enum GitHubAuthPhase { idle, loading, pending, connected, error, disconnecting }

enum GitHubAuthViewState {
  idle,
  loading,
  pending,
  connected,
  error,
  disconnecting,
}

typedef OneShotTimerFactory =
    Timer Function(Duration duration, void Function() callback);
typedef PeriodicTimerFactory =
    Timer Function(Duration duration, void Function(Timer timer) callback);

class GitHubAuthNotice {
  final String title;
  final String message;
  final bool isError;

  const GitHubAuthNotice({
    required this.title,
    required this.message,
    this.isError = true,
  });
}

class GitHubAuthProvider extends ChangeNotifier {
  final GitHubAuthApiClient _apiClient;
  final GitApiClient? _gitApiClient;
  final OneShotTimerFactory _oneShotTimerFactory;
  final PeriodicTimerFactory _periodicTimerFactory;

  GitHubAuthProvider({
    required GitHubAuthApiClient apiClient,
    GitApiClient? gitApiClient,
    OneShotTimerFactory? oneShotTimerFactory,
    PeriodicTimerFactory? periodicTimerFactory,
  }) : _apiClient = apiClient,
       _gitApiClient = gitApiClient,
       _oneShotTimerFactory = oneShotTimerFactory ?? Timer.new,
       _periodicTimerFactory = periodicTimerFactory ?? Timer.periodic;

  GitHubAuthPhase _phase = GitHubAuthPhase.idle;
  GitHubAuthStatus? _status;
  GitHubDeviceCode? _deviceCode;
  GitHubRepoAvailability _repoAvailability =
      const GitHubRepoAvailability.unknown();
  GitHubAuthNotice? _notice;
  String? _errorCode;
  String? _errorMessage;
  String _workspacePath = '';
  int _secondsRemaining = 0;
  String _pollingLabel = 'Not polling yet.';
  bool _isPollingRequestInFlight = false;
  Timer? _pollTimer;
  Timer? _countdownTimer;
  bool _initialized = false;

  GitHubAuthPhase get phase => _phase;
  GitHubAuthViewState get viewState => switch (_phase) {
    GitHubAuthPhase.idle => GitHubAuthViewState.idle,
    GitHubAuthPhase.loading => GitHubAuthViewState.loading,
    GitHubAuthPhase.pending => GitHubAuthViewState.pending,
    GitHubAuthPhase.connected => GitHubAuthViewState.connected,
    GitHubAuthPhase.error => GitHubAuthViewState.error,
    GitHubAuthPhase.disconnecting => GitHubAuthViewState.disconnecting,
  };
  GitHubAuthStatus? get status => _status;
  GitHubDeviceCode? get deviceCode => _deviceCode;
  GitHubDeviceCode? get pendingFlow => _deviceCode;
  GitHubRepoAvailability get repoAvailability => _repoAvailability;
  GitHubAuthNotice? get notice => _notice;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;
  String get workspacePath => _workspacePath;
  int get secondsRemaining => _secondsRemaining;
  int get remainingSeconds => _secondsRemaining;
  String get pollingLabel => _pollingLabel;
  bool get needsReconnect =>
      _status?.needsReauth == true ||
      const {
        'reauth_required',
        'needs_reauth',
        'bad_refresh_token',
        'refresh_not_supported',
        'expired_token',
      }.contains(_errorCode);
  bool get isBusy =>
      _phase == GitHubAuthPhase.loading ||
      _phase == GitHubAuthPhase.disconnecting;
  bool get isPending => _phase == GitHubAuthPhase.pending;
  bool get isConnected => _phase == GitHubAuthPhase.connected;
  bool get isError => _phase == GitHubAuthPhase.error;
  bool get canRetry =>
      _phase == GitHubAuthPhase.error || _phase == GitHubAuthPhase.idle;
  String get statusMessage => _notice?.message ?? _pollingLabel;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await loadStatus();
  }

  Future<void> setWorkspacePath(String path) async {
    if (path == _workspacePath) {
      return;
    }
    _workspacePath = path;
    if (isConnected) {
      await _refreshRepoAvailability();
    } else {
      _repoAvailability = GitHubRepoAvailability.backendContractMissing(
        workspacePath: _workspacePath,
      );
      notifyListeners();
    }
  }

  Future<void> setWorkspace(String path) => setWorkspacePath(path);

  Future<void> loadStatus({bool silent = false}) async {
    if (!silent) {
      _phase = GitHubAuthPhase.loading;
      _notice = null;
      _errorCode = null;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      final nextStatus = await _apiClient.getStatus();
      _status = nextStatus;
      _deviceCode = null;
      _clearTimers();
      _phase = nextStatus.authenticated
          ? GitHubAuthPhase.connected
          : GitHubAuthPhase.idle;
      _notice = _statusNotice(nextStatus);
      _repoAvailability = nextStatus.authenticated
          ? await _computeRepoAvailability(_workspacePath)
          : GitHubRepoAvailability.backendContractMissing(
              workspacePath: _workspacePath,
            );
      _errorCode = nextStatus.needsReauth ? 'needs_reauth' : null;
      _errorMessage = nextStatus.needsReauth ? _notice?.message : null;
    } on GitHubAuthApiException catch (error) {
      _status = null;
      _deviceCode = null;
      _clearTimers();
      if (error.errorCode == 'not_authenticated') {
        _phase = GitHubAuthPhase.idle;
        _notice = const GitHubAuthNotice(
          title: 'Not connected',
          message:
              'GitHub is not connected on this server yet. Start the device flow to continue.',
          isError: false,
        );
      } else {
        _phase = GitHubAuthPhase.error;
        _notice = _noticeForException(error);
      }
      _errorCode = error.errorCode;
      _errorMessage = _notice?.message ?? error.toDisplayMessage();
      _repoAvailability = GitHubRepoAvailability.backendContractMissing(
        workspacePath: _workspacePath,
      );
    }

    notifyListeners();
  }

  Future<void> startDeviceFlow({String? githubHost}) async {
    _clearTimers();
    _phase = GitHubAuthPhase.loading;
    _notice = null;
    _status = null;
    _deviceCode = null;
    _errorCode = null;
    _errorMessage = null;
    notifyListeners();

    try {
      final flow = await _apiClient.startDeviceFlow(
        githubHost: githubHost ?? _defaultGitHubHost,
      );
      _deviceCode = flow;
      _phase = GitHubAuthPhase.pending;
      _pollingLabel = 'Waiting for GitHub approval.';
      _notice = const GitHubAuthNotice(
        title: 'Device authorization in progress',
        message:
            'Open GitHub, enter the device code, and keep this page open while the app polls for approval.',
        isError: false,
      );
      _secondsRemaining = flow.expiresIn;
      _startCountdown();
      _scheduleNextPoll(flow.interval);
    } on GitHubAuthApiException catch (error) {
      _phase = GitHubAuthPhase.error;
      _notice = _noticeForException(error);
      _errorCode = error.errorCode;
      _errorMessage = error.toDisplayMessage();
    }

    notifyListeners();
  }

  Future<void> cancelPending() async {
    cancelPendingFlow();
  }

  void cancelPendingFlow() {
    _clearTimers();
    _deviceCode = null;
    _secondsRemaining = 0;
    _pollingLabel = 'Authorization canceled.';
    _phase = GitHubAuthPhase.idle;
    _notice = const GitHubAuthNotice(
      title: 'Not connected',
      message:
          'GitHub device authorization was canceled. Start again whenever you are ready.',
      isError: false,
    );
    _errorCode = null;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> retry() async {
    if (_phase == GitHubAuthPhase.error || needsReconnect) {
      await startDeviceFlow(
        githubHost: _status?.githubHost ?? _defaultGitHubHost,
      );
      return;
    }
    await loadStatus();
  }

  Future<void> disconnect() async {
    final githubHost =
        _status?.githubHost ?? _deviceCode?.githubHost ?? _defaultGitHubHost;
    if (isPending) {
      cancelPendingFlow();
      return;
    }

    _phase = GitHubAuthPhase.disconnecting;
    notifyListeners();

    try {
      await _apiClient.disconnect(githubHost: githubHost);
      _status = null;
      _deviceCode = null;
      _clearTimers();
      _secondsRemaining = 0;
      _pollingLabel = 'Disconnected.';
      _phase = GitHubAuthPhase.idle;
      _notice = const GitHubAuthNotice(
        title: 'Not connected',
        message:
            'GitHub disconnected. No GitHub token is stored in the Flutter client.',
        isError: false,
      );
      _errorCode = null;
      _errorMessage = null;
      _repoAvailability = GitHubRepoAvailability.backendContractMissing(
        workspacePath: _workspacePath,
      );
    } on GitHubAuthApiException catch (error) {
      _phase = GitHubAuthPhase.error;
      _notice = _noticeForException(error);
      _errorCode = error.errorCode;
      _errorMessage = error.toDisplayMessage();
    }

    notifyListeners();
  }

  String accountLabel() {
    final login = _status?.accountLogin;
    if (login == null || login.isEmpty) {
      return 'Connected account';
    }
    return '@$login';
  }

  GitHubAuthNotice? _statusNotice(GitHubAuthStatus status) {
    if (!status.authenticated) {
      return const GitHubAuthNotice(
        title: 'Not connected',
        message:
            'GitHub is not connected on this server yet. Start the device flow to continue.',
        isError: false,
      );
    }
    if (status.needsReauth) {
      return const GitHubAuthNotice(
        title: 'Action required',
        message:
            'Your GitHub session expired. Disconnect and reconnect to continue.',
      );
    }
    if (status.needsRefresh) {
      return const GitHubAuthNotice(
        title: 'Connected',
        message:
            'GitHub is connected. The server may refresh the token soon because it is close to expiry.',
        isError: false,
      );
    }
    return const GitHubAuthNotice(
      title: 'Connected',
      message: 'GitHub is connected for this server.',
      isError: false,
    );
  }

  GitHubAuthNotice _noticeForException(GitHubAuthApiException error) {
    return GitHubAuthNotice(
      title: 'Action required',
      message: error.toDisplayMessage(),
    );
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = _periodicTimerFactory(const Duration(seconds: 1), (
      timer,
    ) {
      if (_phase != GitHubAuthPhase.pending) {
        timer.cancel();
        return;
      }
      if (_secondsRemaining <= 1) {
        timer.cancel();
        _secondsRemaining = 0;
        _deviceCode = null;
        _phase = GitHubAuthPhase.error;
        _errorCode = 'expired_token';
        _errorMessage =
            'The GitHub device code expired. Start again for a fresh code.';
        _notice = const GitHubAuthNotice(
          title: 'Action required',
          message:
              'The GitHub device code expired. Start again for a fresh code.',
        );
        _clearTimers();
        notifyListeners();
        return;
      }
      _secondsRemaining -= 1;
      notifyListeners();
    });
  }

  void _scheduleNextPoll(int intervalSeconds) {
    final flow = _deviceCode;
    if (flow == null) {
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = _oneShotTimerFactory(
      Duration(seconds: intervalSeconds),
      () async {
        await _poll(flow, intervalSeconds);
      },
    );
  }

  Future<void> _poll(GitHubDeviceCode flow, int currentInterval) async {
    if (_isPollingRequestInFlight || _phase != GitHubAuthPhase.pending) {
      return;
    }

    _isPollingRequestInFlight = true;
    _pollingLabel = 'Checking GitHub for approval...';
    notifyListeners();

    try {
      final response = await _apiClient.pollDeviceFlow(
        githubHost: flow.githubHost,
        deviceCode: flow.deviceCode,
      );
      if (_phase != GitHubAuthPhase.pending) {
        return;
      }

      if (response.isPending) {
        _pollingLabel = 'Still waiting for GitHub approval.';
        _scheduleNextPoll(flow.interval);
        return;
      }

      if (response.isAuthorized && response.auth != null) {
        _clearTimers();
        _status = response.auth;
        _deviceCode = null;
        _secondsRemaining = 0;
        _phase = GitHubAuthPhase.connected;
        _notice = _statusNotice(response.auth!);
        _errorCode = null;
        _errorMessage = null;
        _pollingLabel = 'GitHub connection authorized.';
        _repoAvailability = await _computeRepoAvailability(_workspacePath);
        notifyListeners();
        return;
      }

      if (response.isError) {
        _deviceCode = null;
        _secondsRemaining = 0;
        _clearTimers();
        _phase = GitHubAuthPhase.error;
        _errorCode = response.errorCode ?? 'github_auth_error';
        _errorMessage = GitHubAuthApiException(
          statusCode: 200,
          errorCode: _errorCode!,
          message: response.message ?? 'GitHub authorization failed.',
        ).toDisplayMessage();
        _notice = GitHubAuthNotice(
          title: 'Action required',
          message: _errorMessage!,
        );
        _pollingLabel = 'GitHub authorization failed.';
        notifyListeners();
        return;
      }
    } on GitHubAuthApiException catch (error) {
      if (_phase != GitHubAuthPhase.pending) {
        return;
      }
      if (error.errorCode == 'slow_down') {
        _notice = GitHubAuthNotice(
          title: 'Device authorization in progress',
          message:
              'GitHub asked the app to slow down. Keep the approval page open while polling continues.',
          isError: false,
        );
        _pollingLabel = 'GitHub requested slower polling.';
        _scheduleNextPoll(currentInterval + 5);
      } else if (error.errorCode == 'authorization_pending') {
        _pollingLabel = 'Still waiting for GitHub approval.';
        _scheduleNextPoll(flow.interval);
      } else {
        _deviceCode = null;
        _secondsRemaining = 0;
        _clearTimers();
        _phase = GitHubAuthPhase.error;
        _notice = _noticeForException(error);
        _errorCode = error.errorCode;
        _errorMessage = error.toDisplayMessage();
        _pollingLabel = 'GitHub authorization failed.';
      }
      notifyListeners();
    } finally {
      _isPollingRequestInFlight = false;
    }
  }

  void _clearTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<GitHubRepoAvailability> _computeRepoAvailability(
    String workspacePath,
  ) async {
    final normalizedPath = workspacePath.trim();
    if (normalizedPath.isEmpty || _gitApiClient == null) {
      return GitHubRepoAvailability.backendContractMissing(
        workspacePath: normalizedPath,
      );
    }

    try {
      await _gitApiClient.getBranches(normalizedPath);
      return GitHubRepoAvailability.localGitRepository(
        workspacePath: normalizedPath,
      );
    } catch (error) {
      final details = error.toString();
      if (_looksLikeNotGitRepository(details)) {
        return GitHubRepoAvailability.workspaceNotGitRepository(
          workspacePath: normalizedPath,
          details:
              'The current workspace does not look like a local Git checkout, so remote GitHub access cannot be checked here.',
        );
      }
      return GitHubRepoAvailability.workspaceUnavailable(
        workspacePath: normalizedPath,
        details:
            'The backend auth contract still does not expose GitHub repo-access or app-installation metadata, so only the local Git check is available. Raw error: $details',
      );
    }
  }

  Future<void> _refreshRepoAvailability() async {
    _repoAvailability = GitHubRepoAvailability.checking(
      workspacePath: _workspacePath,
    );
    notifyListeners();
    _repoAvailability = await _computeRepoAvailability(_workspacePath);
    notifyListeners();
  }

  bool _looksLikeNotGitRepository(String details) {
    final normalized = details.toLowerCase();
    return normalized.contains('not a git repository') ||
        normalized.contains('fatal: not a git repository');
  }

  @override
  void dispose() {
    _clearTimers();
    super.dispose();
  }
}
