import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/services/github_auth_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService();
    await settings.save('http://localhost:8080', 'secret');
  });

  test('startDeviceFlow posts request and parses response', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/github/auth/device/start');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(jsonDecode(request.body), <String, dynamic>{
        'github_host': 'github.com',
      });
      return http.Response(
        jsonEncode(<String, dynamic>{
          'github_host': 'github.com',
          'device_code': 'device-1',
          'user_code': 'ABCD-EFGH',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 5,
        }),
        200,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);
    final response = await apiClient.startDeviceFlow(githubHost: 'github.com');

    expect(response.githubHost, 'github.com');
    expect(response.deviceCode, 'device-1');
    expect(response.userCode, 'ABCD-EFGH');
  });

  test('pollDeviceFlow parses authorized payload', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/github/auth/device/poll');
      expect(jsonDecode(request.body), <String, dynamic>{
        'github_host': 'github.com',
        'device_code': 'device-1',
      });
      return http.Response(
        jsonEncode(<String, dynamic>{
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
        200,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);
    final response = await apiClient.pollDeviceFlow(
      githubHost: 'github.com',
      deviceCode: 'device-1',
    );

    expect(response.auth?.accountLogin, 'octocat');
    expect(response.isAuthorized, isTrue);
  });

  test('getStatus includes query string and maps success body', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/github/auth/status');
      expect(request.url.queryParameters['github_host'], 'github.com');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'authenticated': true,
          'github_host': 'github.com',
          'account_login': 'octocat',
          'account_id': 9,
          'access_token_expires_at': '2026-04-20T12:05:00Z',
          'refresh_token_expires_at': '2026-04-20T13:00:00Z',
          'needs_refresh': true,
          'needs_reauth': false,
        }),
        200,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);
    final response = await apiClient.getStatus(githubHost: 'github.com');

    expect(response.authenticated, isTrue);
    expect(response.needsRefresh, isTrue);
    expect(response.accountLogin, 'octocat');
  });

  test('disconnect posts host and parses response', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/github/auth/disconnect');
      expect(jsonDecode(request.body), <String, dynamic>{
        'github_host': 'github.com',
      });
      return http.Response(
        jsonEncode(<String, dynamic>{
          'disconnected': true,
          'github_host': 'github.com',
        }),
        200,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);
    final response = await apiClient.disconnect(githubHost: 'github.com');

    expect(response.disconnected, isTrue);
    expect(response.githubHost, 'github.com');
  });

  test('maps 401 not_authenticated to a structured exception', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error_code': 'not_authenticated',
          'message': 'github not authenticated',
        }),
        401,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);

    await expectLater(
      () => apiClient.getStatus(githubHost: 'github.com'),
      throwsA(
        isA<GitHubAuthApiException>()
            .having((e) => e.errorCode, 'errorCode', 'not_authenticated')
            .having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
  });

  test('maps service disabled errors to clear display text', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error_code': 'github_auth_disabled',
          'message': 'github auth is not configured',
        }),
        503,
      );
    });

    final apiClient = GitHubAuthApiClient(settings: settings, client: client);

    await expectLater(
      () => apiClient.startDeviceFlow(githubHost: 'github.com'),
      throwsA(
        isA<GitHubAuthApiException>().having(
          (e) => e.toDisplayMessage(),
          'displayMessage',
          'GitHub sign-in is not enabled on this server.',
        ),
      ),
    );
  });

  test(
    'maps device-flow error payloads even when the HTTP status is 200',
    () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': 'error',
            'error_code': 'access_denied',
            'message': 'github access denied',
          }),
          200,
        );
      });

      final apiClient = GitHubAuthApiClient(settings: settings, client: client);

      await expectLater(
        () => apiClient.pollDeviceFlow(
          githubHost: 'github.com',
          deviceCode: 'device-1',
        ),
        throwsA(
          isA<GitHubAuthApiException>()
              .having((e) => e.errorCode, 'errorCode', 'access_denied')
              .having(
                (e) => e.toDisplayMessage(),
                'displayMessage',
                'GitHub authorization was denied. Start again and approve the request.',
              ),
        ),
      );
    },
  );
}
