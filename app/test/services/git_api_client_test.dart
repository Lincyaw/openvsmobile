import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

const Map<String, dynamic> _repositoryDocument = <String, dynamic>{
  'path': '/workspace/repo',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 2,
  'behind': 1,
  'remotes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'origin',
      'fetchUrl': 'git@github.com:Lincyaw/openvsmobile.git',
      'pushUrl': 'git@github.com:Lincyaw/openvsmobile.git',
    },
    <String, dynamic>{
      'name': 'upstream',
      'fetchUrl': 'https://github.com/gitpod-io/openvscode-server.git',
      'pushUrl': 'no_push',
    },
  ],
  'staged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/staged.dart', 'status': 'modified'},
  ],
  'unstaged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/unstaged.dart', 'status': 'deleted'},
  ],
  'untracked': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/new.dart', 'status': 'untracked'},
  ],
  'conflicts': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/conflicted.dart', 'status': 'both_modified'},
  ],
  'mergeChanges': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/merge_only.dart', 'status': 'added_by_them'},
  ],
};

const Map<String, dynamic> _stagedRepositoryDocument = <String, dynamic>{
  'path': '/workspace/repo',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 2,
  'behind': 1,
  'remotes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'origin',
      'fetchUrl': 'git@github.com:Lincyaw/openvsmobile.git',
      'pushUrl': 'git@github.com:Lincyaw/openvsmobile.git',
    },
  ],
  'staged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/new.dart', 'status': 'added'},
  ],
  'unstaged': <Map<String, dynamic>>[],
  'untracked': <Map<String, dynamic>>[],
  'conflicts': <Map<String, dynamic>>[],
  'mergeChanges': <Map<String, dynamic>>[],
};

Future<SettingsService> _createSettings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsService();
  await settings.load();
  await settings.save('http://server.test', 'dev-token');
  return settings;
}

Future<dynamic> _invokeAsync(List<Future<dynamic> Function()> candidates) async {
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return await candidate();
    } on NoSuchMethodError catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? StateError('No supported invocation matched');
}

Map<String, dynamic> _toJsonObject(dynamic value) {
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GitApiClient parses bridge repository documents with grouped sections', () async {
    final settings = await _createSettings();
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/bridge/git/repository');
        expect(request.url.queryParameters['path'], '/workspace/repo');
        return http.Response(jsonEncode(_repositoryDocument), 200);
      }),
    );

    final dynamic repository = await _invokeAsync(<Future<dynamic> Function()>[
      () => (client as dynamic).getRepository('/workspace/repo'),
      () => (client as dynamic).getRepositoryState('/workspace/repo'),
    ]);

    final decoded = _toJsonObject(repository);
    expect(decoded['branch'], 'main');
    expect(decoded['upstream'], 'origin/main');
    expect(decoded['ahead'], 2);
    expect(decoded['behind'], 1);
    expect((decoded['remotes'] as List<dynamic>).length, 2);
    expect((decoded['staged'] as List<dynamic>).single['path'], 'lib/staged.dart');
    expect((decoded['unstaged'] as List<dynamic>).single['path'], 'lib/unstaged.dart');
    expect((decoded['untracked'] as List<dynamic>).single['path'], 'lib/new.dart');
    expect((decoded['conflicts'] as List<dynamic>).single['path'], 'lib/conflicted.dart');
    expect((decoded['mergeChanges'] as List<dynamic>).single['path'], 'lib/merge_only.dart');
  });

  test('GitApiClient command calls use bridge endpoints and return refreshed repository state', () async {
    final settings = await _createSettings();
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/bridge/git/stage');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['path'], '/workspace/repo');
        expect(body['file'] ?? body['paths'], isNotNull);
        return http.Response(jsonEncode(_stagedRepositoryDocument), 200);
      }),
    );

    final dynamic repository = await _invokeAsync(<Future<dynamic> Function()>[
      () => (client as dynamic).stage('/workspace/repo', 'lib/new.dart'),
      () => (client as dynamic).stageFile('/workspace/repo', 'lib/new.dart'),
    ]);

    final decoded = _toJsonObject(repository);
    expect((decoded['staged'] as List<dynamic>).single['path'], 'lib/new.dart');
    expect(decoded['conflicts'], isEmpty);
    expect(decoded['mergeChanges'], isEmpty);
  });

  test('GitApiClient surfaces structured bridge errors from command endpoints', () async {
    final settings = await _createSettings();
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/bridge/git/commit');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'merge_conflict',
            'message': 'Resolve conflicts before committing.',
          }),
          409,
        );
      }),
    );

    try {
      await _invokeAsync(<Future<dynamic> Function()>[
        () => (client as dynamic).commit('/workspace/repo', 'ship bridge git'),
      ]);
      fail('Expected a structured bridge error');
    } catch (error) {
      expect(error.toString(), contains('merge_conflict'));
      expect(error.toString(), contains('Resolve conflicts before committing.'));
    }
  });
}
