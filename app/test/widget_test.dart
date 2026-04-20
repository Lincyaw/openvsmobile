import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/providers/github_auth_provider.dart';
import 'package:vscode_mobile/models/github_auth_models.dart';
import 'package:vscode_mobile/screens/more_screen.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/github_auth_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

Future<Widget> buildTestApp() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final settings = SettingsService();
  await settings.save('http://localhost:8080', 'server-token');

  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => GitHubAuthProvider(
          apiClient: _FakeGitHubAuthApiClient(settings),
          gitApiClient: _FakeGitApiClient(settings),
        )..setWorkspacePath('/workspaces/openvsmobile'),
      ),
    ],
    child: const MaterialApp(home: MoreScreen()),
  );
}

void main() {
  testWidgets('More screen renders the GitHub entry', (tester) async {
    await tester.pumpWidget(await buildTestApp());
    await tester.pump();

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Connect GitHub and inspect auth status'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}

class _FakeGitHubAuthApiClient extends GitHubAuthApiClient {
  _FakeGitHubAuthApiClient(SettingsService settings)
    : super(settings: settings);

  @override
  Future<GitHubAuthStatus> getStatus({String githubHost = 'github.com'}) async {
    throw const GitHubAuthApiException(
      statusCode: 401,
      errorCode: 'not_authenticated',
      message: 'github not authenticated',
    );
  }
}

class _FakeGitApiClient extends GitApiClient {
  _FakeGitApiClient(SettingsService settings) : super(settings: settings);
}
