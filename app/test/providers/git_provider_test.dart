import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

const Map<String, dynamic> _initialRepositoryDocument = <String, dynamic>{
  'path': '/workspace/repo',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 0,
  'behind': 0,
  'remotes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'origin',
      'fetchUrl': 'git@github.com:Lincyaw/openvsmobile.git',
      'pushUrl': 'git@github.com:Lincyaw/openvsmobile.git',
    },
  ],
  'staged': <Map<String, dynamic>>[],
  'unstaged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/feature.dart', 'status': 'modified'},
  ],
  'untracked': <Map<String, dynamic>>[],
  'conflicts': <Map<String, dynamic>>[],
  'mergeChanges': <Map<String, dynamic>>[],
};

const Map<String, dynamic> _updatedRepositoryDocument = <String, dynamic>{
  'path': '/workspace/repo',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 1,
  'behind': 0,
  'remotes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'origin',
      'fetchUrl': 'git@github.com:Lincyaw/openvsmobile.git',
      'pushUrl': 'git@github.com:Lincyaw/openvsmobile.git',
    },
  ],
  'staged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/feature.dart', 'status': 'modified'},
  ],
  'unstaged': <Map<String, dynamic>>[],
  'untracked': <Map<String, dynamic>>[],
  'conflicts': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/conflicted.dart', 'status': 'both_modified'},
  ],
  'mergeChanges': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/merge_only.dart', 'status': 'added_by_them'},
  ],
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

Future<void> _invokeRefresh(dynamic provider) async {
  await _invokeAsync(<Future<dynamic> Function()>[
    () => (provider as dynamic).refreshRepository(),
    () => (provider as dynamic).loadRepository(),
    () => (provider as dynamic).refreshAll(),
  ]);
}

Future<void> _invokeBridgeEvent(dynamic provider, Map<String, dynamic> event) async {
  await _invokeAsync(<Future<dynamic> Function()>[
    () async => (provider as dynamic).handleBridgeEvent(event),
    () async => (provider as dynamic).onBridgeEvent(event),
    () async => (provider as dynamic).processBridgeEvent(event),
    () async => (provider as dynamic).applyBridgeEvent(event),
  ]);
}

Map<String, dynamic> _repositoryFromProvider(dynamic provider) {
  final getters = <dynamic Function()>[
    () => (provider as dynamic).repository,
    () => (provider as dynamic).repositoryState,
    () => (provider as dynamic).repositoryDocument,
  ];
  for (final getter in getters) {
    try {
      final dynamic value = getter();
      if (value != null) {
        return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
      }
    } on NoSuchMethodError {
      continue;
    }
  }
  throw StateError('Provider does not expose a repository document');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GitProvider refreshes a bridge-backed repository document', () async {
    final settings = await _createSettings();
    var repositoryFetches = 0;
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        if (request.method == 'GET' &&
            request.url.path == '/bridge/git/repository') {
          repositoryFetches += 1;
          return http.Response(jsonEncode(_initialRepositoryDocument), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );

    final dynamic provider = GitProvider(apiClient: client);
    (provider as dynamic).setWorkDir('/workspace/repo');

    await _invokeRefresh(provider);

    final repository = _repositoryFromProvider(provider);
    expect(repositoryFetches, 1);
    expect(repository['branch'], 'main');
    expect((repository['unstaged'] as List<dynamic>).single['path'], 'lib/feature.dart');
  });

  test('GitProvider refreshes after bridge git repositoryChanged events', () async {
    final settings = await _createSettings();
    var repositoryFetches = 0;
    final client = GitApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        if (request.method == 'GET' &&
            request.url.path == '/bridge/git/repository') {
          repositoryFetches += 1;
          final body = repositoryFetches == 1
              ? _initialRepositoryDocument
              : _updatedRepositoryDocument;
          return http.Response(jsonEncode(body), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );

    final dynamic provider = GitProvider(apiClient: client);
    (provider as dynamic).setWorkDir('/workspace/repo');

    await _invokeRefresh(provider);
    await _invokeBridgeEvent(provider, <String, dynamic>{
      'type': 'bridge/git/repositoryChanged',
      'payload': <String, dynamic>{'path': '/workspace/repo'},
    });
    await Future<void>.delayed(Duration.zero);

    final repository = _repositoryFromProvider(provider);
    expect(repositoryFetches, greaterThanOrEqualTo(2));
    expect(repository['ahead'], 1);
    expect((repository['staged'] as List<dynamic>).single['path'], 'lib/feature.dart');
    expect((repository['conflicts'] as List<dynamic>).single['path'], 'lib/conflicted.dart');
    expect((repository['mergeChanges'] as List<dynamic>).single['path'], 'lib/merge_only.dart');
  });
}
