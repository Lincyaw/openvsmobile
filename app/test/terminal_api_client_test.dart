import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vscode_mobile/services/terminal_api_client.dart';

class _StopDial implements Exception {}

void main() {
  test('listSessions parses bridge terminal metadata', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/terminal/sessions');
      expect(request.headers['Authorization'], 'Bearer secret');
      return http.Response(
        jsonEncode([
          {
            'id': 'term-1',
            'name': 'Workspace',
            'cwd': '/workspace',
            'profile': 'bash',
            'state': 'running',
          },
        ]),
        200,
      );
    });
    final api = TerminalApiClient(
      baseUrl: 'http://localhost:8080',
      token: 'secret',
      client: client,
    );

    final sessions = await api.listSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.id, 'term-1');
    expect(sessions.single.cwd, '/workspace');
    expect(sessions.single.isRunning, isTrue);
  });

  test('createSession accepts nested session envelopes', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/terminal/create');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['cwd'], '/repo');
      expect(body['rows'], 24);
      expect(body['cols'], 80);

      return http.Response(
        jsonEncode({
          'session': {
            'id': 'term-2',
            'name': 'Repo',
            'cwd': '/repo',
            'profile': 'bash',
            'state': 'running',
          },
        }),
        200,
      );
    });
    final api = TerminalApiClient(
      baseUrl: 'http://localhost:8080',
      token: 'secret',
      client: client,
    );

    final session = await api.createSession(
      workDir: '/repo',
      rows: 24,
      cols: 80,
    );

    expect(session.id, 'term-2');
    expect(session.name, 'Repo');
  });

  test('renameSession posts to the bridge rename endpoint', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/terminal/rename');
      expect(jsonDecode(request.body), {'id': 'term-1', 'name': 'Renamed'});
      return http.Response(
        jsonEncode({
          'id': 'term-1',
          'name': 'Renamed',
          'cwd': '/workspace',
          'profile': 'bash',
          'state': 'running',
          'rows': 30,
          'cols': 90,
        }),
        200,
      );
    });
    final api = TerminalApiClient(
      baseUrl: 'http://localhost:8080',
      token: 'secret',
      client: client,
    );

    final session = await api.renameSession('term-1', 'Renamed');

    expect(session.name, 'Renamed');
    expect(session.rows, 30);
    expect(session.cols, 90);
  });

  test('splitSession accepts wrapped envelopes', () async {
    final client = MockClient((http.Request request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/terminal/split');
      expect(jsonDecode(request.body), {'parentId': 'term-1', 'name': 'Split'});
      return http.Response(
        jsonEncode({
          'session': {
            'id': 'term-2',
            'name': 'Split',
            'cwd': '/workspace',
            'profile': 'bash',
            'state': 'running',
          },
        }),
        200,
      );
    });
    final api = TerminalApiClient(
      baseUrl: 'http://localhost:8080',
      token: 'secret',
      client: client,
    );

    final session = await api.splitSession('term-1', name: 'Split');

    expect(session.id, 'term-2');
    expect(session.name, 'Split');
  });

  test('connectTerminalWebSocket uses bridge session path and token query', () {
    Uri? captured;
    final api = TerminalApiClient(
      baseUrl: 'https://example.com/api',
      token: 'secret',
      channelFactory: (uri) {
        captured = uri;
        throw _StopDial();
      },
    );

    expect(
      () => api.connectTerminalWebSocket('term-9'),
      throwsA(isA<_StopDial>()),
    );
    expect(
      captured.toString(),
      'wss://example.com/api/ws/terminal/term-9?token=secret',
    );
  });

  test('connectEventsWebSocket uses the unified bridge events stream', () {
    Uri? captured;
    final api = TerminalApiClient(
      baseUrl: 'https://example.com/api',
      token: 'secret',
      channelFactory: (uri) {
        captured = uri;
        throw _StopDial();
      },
    );

    expect(() => api.connectEventsWebSocket(), throwsA(isA<_StopDial>()));
    expect(
      captured.toString(),
      'wss://example.com/api/bridge/ws/events?token=secret',
    );
  });
}
