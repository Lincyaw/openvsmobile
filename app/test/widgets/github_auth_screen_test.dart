import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_auth_models.dart';
import 'package:vscode_mobile/providers/github_auth_provider.dart';
import 'package:vscode_mobile/screens/github_auth_screen.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/github_auth_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders idle state with connect CTA', (tester) async {
    final provider = await _buildProvider();
    await tester.pumpWidget(_buildApp(provider));

    expect(find.text('Connect GitHub'), findsOneWidget);
    expect(find.textContaining('Not connected.'), findsOneWidget);
  });

  testWidgets('renders pending state with the device code', (tester) async {
    final provider = await _buildProvider(
      phase: GitHubAuthPhase.pending,
      deviceCode: GitHubDeviceCode.fromJson(<String, dynamic>{
        'github_host': 'github.com',
        'device_code': 'device-1',
        'user_code': 'ABCD-EFGH',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900,
        'interval': 5,
      }),
      notice: const GitHubAuthNotice(
        title: 'Device authorization in progress',
        message: 'Waiting for approval.',
        isError: false,
      ),
    );
    await tester.pumpWidget(_buildApp(provider));

    expect(find.text('Device authorization in progress'), findsWidgets);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.textContaining('Waiting for approval.'), findsWidgets);
  });

  testWidgets('renders connected state with repo status and disconnect CTA', (
    tester,
  ) async {
    final provider = await _buildProvider(
      phase: GitHubAuthPhase.connected,
      status: const GitHubAuthStatus(
        authenticated: true,
        githubHost: 'github.com',
        accountLogin: 'octocat',
        accountId: 9,
        accessTokenExpiresAt: null,
        refreshTokenExpiresAt: null,
        needsRefresh: false,
        needsReauth: false,
      ),
      repoAvailability: GitHubRepoAvailability.localGitRepository(
        workspacePath: '/workspace/repo',
      ),
      notice: const GitHubAuthNotice(
        title: 'Connected',
        message: 'GitHub is connected for this server.',
        isError: false,
      ),
    );
    await tester.pumpWidget(_buildApp(provider));

    expect(find.text('@octocat'), findsOneWidget);
    expect(find.text('Workspace repo status'), findsOneWidget);
  });

  testWidgets('renders error state with retry affordance', (tester) async {
    final provider = await _buildProvider(
      phase: GitHubAuthPhase.error,
      notice: const GitHubAuthNotice(
        title: 'Action required',
        message: 'GitHub sign-in is not enabled on this server.',
      ),
    );
    await tester.pumpWidget(_buildApp(provider));

    expect(find.textContaining('Action required'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });
}

Widget _buildApp(_FakeScreenProvider provider) {
  return ChangeNotifierProvider<GitHubAuthProvider>.value(
    value: provider,
    child: const MaterialApp(home: GitHubAuthScreen()),
  );
}

Future<_FakeScreenProvider> _buildProvider({
  GitHubAuthPhase phase = GitHubAuthPhase.idle,
  GitHubDeviceCode? deviceCode,
  GitHubAuthStatus? status,
  GitHubRepoAvailability? repoAvailability,
  GitHubAuthNotice? notice,
}) async {
  final settings = SettingsService();
  await settings.save('http://localhost:8080', 'secret');
  return _FakeScreenProvider(settings)
    ..fakePhase = phase
    ..fakeDeviceCode = deviceCode
    ..fakeStatus = status
    ..fakeRepoAvailability =
        repoAvailability ??
        GitHubRepoAvailability.backendContractMissing(
          workspacePath: '/workspace/repo',
        )
    ..fakeNotice = notice
    ..fakeWorkspacePath = '/workspace/repo';
}

class _FakeScreenProvider extends GitHubAuthProvider {
  _FakeScreenProvider(SettingsService settings)
    : super(
        apiClient: GitHubAuthApiClient(settings: settings),
        gitApiClient: GitApiClient(settings: settings),
      );

  GitHubAuthPhase fakePhase = GitHubAuthPhase.idle;
  GitHubDeviceCode? fakeDeviceCode;
  GitHubAuthStatus? fakeStatus;
  GitHubRepoAvailability fakeRepoAvailability =
      GitHubRepoAvailability.backendContractMissing(
        workspacePath: '/workspace/repo',
      );
  GitHubAuthNotice? fakeNotice;
  String fakeWorkspacePath = '/workspace/repo';

  @override
  Future<void> initialize() async {}

  @override
  GitHubAuthPhase get phase => fakePhase;

  @override
  GitHubAuthViewState get viewState => switch (fakePhase) {
    GitHubAuthPhase.idle => GitHubAuthViewState.idle,
    GitHubAuthPhase.loading => GitHubAuthViewState.loading,
    GitHubAuthPhase.pending => GitHubAuthViewState.pending,
    GitHubAuthPhase.connected => GitHubAuthViewState.connected,
    GitHubAuthPhase.error => GitHubAuthViewState.error,
    GitHubAuthPhase.disconnecting => GitHubAuthViewState.disconnecting,
  };

  @override
  bool get isBusy => false;

  @override
  bool get isPending => fakePhase == GitHubAuthPhase.pending;

  @override
  bool get isConnected => fakePhase == GitHubAuthPhase.connected;

  @override
  bool get canRetry => true;

  @override
  GitHubDeviceCode? get pendingFlow => fakeDeviceCode;

  @override
  GitHubAuthStatus? get status => fakeStatus;

  @override
  GitHubRepoAvailability get repoAvailability => fakeRepoAvailability;

  @override
  GitHubAuthNotice? get notice => fakeNotice;

  @override
  String get workspacePath => fakeWorkspacePath;

  @override
  String get pollingLabel => 'Waiting for approval.';

  @override
  int get secondsRemaining => 900;

  @override
  String accountLabel() => '@${fakeStatus?.accountLogin ?? 'octocat'}';
}
