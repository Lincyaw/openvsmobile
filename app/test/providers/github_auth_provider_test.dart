import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/git_models.dart';
import 'package:vscode_mobile/models/github_auth_models.dart';
import 'package:vscode_mobile/providers/github_auth_provider.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/github_auth_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late _FakeGitHubAuthApiClient authApiClient;
  late _FakeGitApiClient gitApiClient;
  late GitHubAuthProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService();
    await settings.save('http://localhost:8080', 'secret');
    authApiClient = _FakeGitHubAuthApiClient(settings);
    gitApiClient = _FakeGitApiClient(settings);
    provider = GitHubAuthProvider(
      apiClient: authApiClient,
      gitApiClient: gitApiClient,
    );
    await provider.setWorkspacePath('/workspace/repo');
  });

  tearDown(() {
    provider.dispose();
  });

  test('initialize loads connected status and repo availability', () async {
    authApiClient.statusResponse = const GitHubAuthStatus(
      authenticated: true,
      githubHost: 'github.com',
      accountLogin: 'octocat',
      accountId: 9,
      accessTokenExpiresAt: null,
      refreshTokenExpiresAt: null,
      needsRefresh: false,
      needsReauth: true,
    );
    gitApiClient.branchesResponse = const GitBranchInfo(
      current: 'main',
      branches: <String>['main'],
    );

    await provider.initialize();

    expect(provider.phase, GitHubAuthPhase.connected);
    expect(provider.status?.accountLogin, 'octocat');
    expect(provider.notice?.title, 'Action required');
    expect(provider.notice?.message, contains('expired'));
    expect(
      provider.repoAvailability.state,
      GitHubRepoAvailabilityState.localGitRepository,
    );
  });

  test(
    'startDeviceFlow enters pending state then authorizes after polling',
    () {
      fakeAsync((async) {
        authApiClient.startResponse =
            GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
              'github_host': 'github.com',
              'device_code': 'device-1',
              'user_code': 'ABCD-EFGH',
              'verification_uri': 'https://github.com/login/device',
              'expires_in': 900,
              'interval': 5,
            });
        authApiClient.pollResponses.add(
          GitHubAuthPollResponse.fromJson(<String, dynamic>{
            'status': 'authorized',
            'github_host': 'github.com',
            'auth': <String, dynamic>{
              'authenticated': true,
              'github_host': 'github.com',
              'account_login': 'octocat',
              'account_id': 9,
              'needs_refresh': false,
              'needs_reauth': false,
            },
          }),
        );
        gitApiClient.branchesResponse = const GitBranchInfo(
          current: 'main',
          branches: <String>['main'],
        );

        provider.startDeviceFlow();
        async.flushMicrotasks();
        expect(provider.phase, GitHubAuthPhase.pending);
        expect(provider.pendingFlow?.userCode, 'ABCD-EFGH');

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(provider.phase, GitHubAuthPhase.connected);
        expect(provider.status?.accountLogin, 'octocat');
        expect(provider.pendingFlow, isNull);
        expect(provider.pollingLabel, 'GitHub connection authorized.');
      });
    },
  );

  test('poll error stops flow and surfaces recovery notice', () {
    fakeAsync((async) {
      authApiClient.startResponse =
          GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
            'github_host': 'github.com',
            'device_code': 'device-1',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });
      authApiClient.pollResponses.add(
        GitHubAuthPollResponse.fromJson(<String, dynamic>{
          'status': 'error',
          'github_host': 'github.com',
          'error_code': 'access_denied',
          'message': 'github access denied',
        }),
      );

      provider.startDeviceFlow();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      expect(provider.phase, GitHubAuthPhase.error);
      expect(provider.notice?.title, 'Action required');
      expect(provider.notice?.message, contains('denied'));
      expect(provider.pendingFlow, isNull);
      expect(provider.canRetry, isTrue);
    });
  });

  test('cancelPendingFlow clears pending state', () {
    fakeAsync((async) {
      authApiClient.startResponse =
          GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
            'github_host': 'github.com',
            'device_code': 'device-1',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });

      provider.startDeviceFlow();
      async.flushMicrotasks();
      provider.cancelPendingFlow();

      expect(provider.phase, GitHubAuthPhase.idle);
      expect(provider.pendingFlow, isNull);
      expect(provider.notice?.title, 'Not connected');
      expect(provider.notice?.message, contains('canceled'));
      expect(provider.pollingLabel, 'Authorization canceled.');
    });
  });

  test('retry restarts device flow after an error', () {
    fakeAsync((async) {
      authApiClient.startResponse =
          GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
            'github_host': 'github.com',
            'device_code': 'device-1',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });
      authApiClient.pollResponses.add(
        GitHubAuthPollResponse.fromJson(<String, dynamic>{
          'status': 'error',
          'github_host': 'github.com',
          'error_code': 'expired_token',
          'message': 'github device code expired',
        }),
      );

      provider.startDeviceFlow();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(provider.phase, GitHubAuthPhase.error);

      authApiClient.startResponse =
          GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
            'github_host': 'github.com',
            'device_code': 'device-2',
            'user_code': 'ZXCV-BNMK',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });
      provider.retry();
      async.flushMicrotasks();

      expect(provider.phase, GitHubAuthPhase.pending);
      expect(provider.pendingFlow?.deviceCode, 'device-2');
      expect(authApiClient.startCalls, 2);
    });
  });

  test('disconnect clears auth state and returns to idle', () async {
    authApiClient.statusResponse = const GitHubAuthStatus(
      authenticated: true,
      githubHost: 'github.com',
      accountLogin: 'octocat',
      accountId: 9,
      accessTokenExpiresAt: null,
      refreshTokenExpiresAt: null,
      needsRefresh: false,
      needsReauth: false,
    );
    gitApiClient.branchesResponse = const GitBranchInfo(
      current: 'main',
      branches: <String>['main'],
    );
    await provider.initialize();

    await provider.disconnect();

    expect(provider.phase, GitHubAuthPhase.idle);
    expect(provider.status, isNull);
    expect(authApiClient.disconnectCalls, 1);
    expect(provider.notice?.title, 'Not connected');
    expect(provider.notice?.message, contains('disconnected'));
  });

  test('countdown expiry moves provider into retryable error state', () {
    fakeAsync((async) {
      authApiClient.startResponse =
          GitHubDeviceFlowStartResponse.fromJson(<String, dynamic>{
            'github_host': 'github.com',
            'device_code': 'device-1',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 2,
            'interval': 5,
          });
      authApiClient.pollResponses.add(
        GitHubAuthPollResponse.fromJson(<String, dynamic>{
          'status': 'pending',
          'github_host': 'github.com',
        }),
      );

      provider.startDeviceFlow();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(provider.phase, GitHubAuthPhase.error);
      expect(provider.pendingFlow, isNull);
      expect(provider.notice?.title, 'Action required');
      expect(provider.notice?.message, contains('expired'));
      expect(provider.canRetry, isTrue);
    });
  });
}

class _FakeGitHubAuthApiClient extends GitHubAuthApiClient {
  GitHubDeviceFlowStartResponse? startResponse;
  GitHubAuthStatus? statusResponse;
  final List<GitHubAuthPollResponse> pollResponses = <GitHubAuthPollResponse>[];
  int startCalls = 0;
  int disconnectCalls = 0;

  _FakeGitHubAuthApiClient(SettingsService settings)
    : super(settings: settings);

  @override
  Future<GitHubDeviceFlowStartResponse> startDeviceFlow({
    String? githubHost,
  }) async {
    startCalls += 1;
    return startResponse!;
  }

  @override
  Future<GitHubAuthPollResponse> pollDeviceFlow({
    String? githubHost,
    required String deviceCode,
  }) async {
    if (pollResponses.isEmpty) {
      return GitHubAuthPollResponse.fromJson(<String, dynamic>{
        'status': 'pending',
        'github_host': githubHost ?? 'github.com',
      });
    }
    return pollResponses.removeAt(0);
  }

  @override
  Future<GitHubAuthStatus> getStatus({String githubHost = 'github.com'}) async {
    if (statusResponse == null) {
      throw const GitHubAuthApiException(
        statusCode: 401,
        errorCode: 'not_authenticated',
        message: 'github not authenticated',
      );
    }
    return statusResponse!;
  }

  @override
  Future<GitHubDisconnectResponse> disconnect({String? githubHost}) async {
    disconnectCalls += 1;
    return GitHubDisconnectResponse(
      disconnected: true,
      githubHost: githubHost ?? 'github.com',
    );
  }
}

class _FakeGitApiClient extends GitApiClient {
  GitBranchInfo? branchesResponse;
  Object? branchesError;

  _FakeGitApiClient(SettingsService settings) : super(settings: settings);

  @override
  Future<GitBranchInfo> getBranches(String path) async {
    if (branchesError != null) {
      throw branchesError!;
    }
    return branchesResponse ??
        const GitBranchInfo(current: 'main', branches: <String>['main']);
  }
}
