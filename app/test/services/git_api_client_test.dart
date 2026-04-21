import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/git_models.dart';
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

    final GitRepositoryState repository = await client.getRepository('/workspace/repo');

    expect(repository.branch, 'main');
    expect(repository.upstream, 'origin/main');
    expect(repository.ahead, 2);
    expect(repository.behind, 1);
    expect(repository.remotes, hasLength(2));
    expect(repository.staged.single.path, 'lib/staged.dart');
    expect(repository.unstaged.single.path, 'lib/unstaged.dart');
    expect(repository.untracked.single.path, 'lib/new.dart');
    expect(repository.conflicts.single.path, 'lib/conflicted.dart');
    expect(repository.mergeChanges.single.path, 'lib/merge_only.dart');
    expect(repository.stagedCount, 1);
    expect(repository.unstagedCount, 2);
    expect(repository.untrackedCount, 1);
    expect(repository.conflictCount, 1);
    expect(repository.groups.map((group) => group.title).toList(), <String>[
      'Conflicts',
      'Staged Changes',
      'Changes',
      'Untracked',
    ]);
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
        expect(body['file'], 'lib/new.dart');
        return http.Response(jsonEncode(_stagedRepositoryDocument), 200);
      }),
    );

    final GitRepositoryState repository = await client.stageFile(
      '/workspace/repo',
      'lib/new.dart',
    );

    expect(repository.staged.single.path, 'lib/new.dart');
    expect(repository.conflicts, isEmpty);
    expect(repository.mergeChanges, isEmpty);
  });

  test('GitApiClient routes diff requests through /bridge/git/diff', () async {
    final settings = await _createSettings();
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/bridge/git/diff');
        expect(request.url.queryParameters['path'], '/workspace/repo');
        expect(request.url.queryParameters['file'], 'lib/feature.dart');
        expect(request.url.queryParameters['staged'], 'true');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'path': 'lib/feature.dart',
            'diff': 'diff --git a/lib/feature.dart b/lib/feature.dart\n+hello',
            'staged': true,
          }),
          200,
        );
      }),
    );

    final GitDiffDocument diff = await client.getDiff(
      '/workspace/repo',
      'lib/feature.dart',
      staged: true,
    );

    expect(diff.path, 'lib/feature.dart');
    expect(diff.staged, isTrue);
    expect(diff.diff, contains('diff --git a/lib/feature.dart b/lib/feature.dart'));
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

    expect(
      () => client.commit('/workspace/repo', 'ship bridge git'),
      throwsA(
        isA<Object>().having(
          (error) => error.toString(),
          'message',
          allOf(
            contains('merge_conflict'),
            contains('Resolve conflicts before committing.'),
          ),
        ),
      ),
    );
  });

  test('GitApiClient surfaces structured bridge errors from diff requests', () async {
    final settings = await _createSettings();
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.url.path, '/bridge/git/diff');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'git_repository_unavailable',
            'message': 'failed to load diff for lib/feature.dart',
          }),
          502,
        );
      }),
    );

    expect(
      () => client.getDiff('/workspace/repo', 'lib/feature.dart'),
      throwsA(
        isA<Object>().having(
          (error) => error.toString(),
          'message',
          allOf(
            contains('git_repository_unavailable'),
            contains('failed to load diff for lib/feature.dart'),
          ),
        ),
      ),
    );
  });
}
