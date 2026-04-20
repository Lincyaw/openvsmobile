import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:vscode_mobile/models/git_models.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/services/api_client.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GitProvider refreshes a bridge-backed repository document', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_initialRepositoryDocument));

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();

    expect(client.repositoryFetches, 1);
    expect(provider.repository?.branch, 'main');
    expect(provider.repository?.unstaged.single.path, 'lib/feature.dart');
  });

  test('GitProvider refreshes after stage and unstage actions update repository state', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_initialRepositoryDocument))
      ..stageResponses.add(_repo(_updatedRepositoryDocument))
      ..unstageResponses.add(_repo(_initialRepositoryDocument));

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();

    await provider.stageFile('lib/feature.dart');
    expect(provider.repository?.staged.single.path, 'lib/feature.dart');
    expect(provider.repository?.unstaged, isEmpty);
    expect(provider.feedback?.kind, GitFeedbackKind.success);

    await provider.unstageFile('lib/feature.dart');
    expect(provider.repository?.unstaged.single.path, 'lib/feature.dart');
    expect(provider.repository?.staged, isEmpty);
    expect(provider.feedback?.kind, GitFeedbackKind.success);
  });

  test('GitProvider decodes repositoryChanged websocket payloads without forcing a refresh', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_initialRepositoryDocument));

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();

    client.emitEvent(<String, dynamic>{
      'type': 'bridge/git/repositoryChanged',
      'payload': _updatedRepositoryDocument,
    });
    await Future<void>.delayed(Duration.zero);

    expect(provider.repository?.ahead, 1);
    expect(provider.repository?.staged.single.path, 'lib/feature.dart');
    expect(provider.repository?.conflicts.single.path, 'lib/conflicted.dart');
    expect(provider.repository?.mergeChanges.single.path, 'lib/merge_only.dart');
    expect(client.repositoryFetches, 1);
  });

  test('GitProvider exposes running state and success feedback for repository operations', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_initialRepositoryDocument));

    final fetchCompleter = Completer<GitRepositoryState>();
    client.fetchFuture = fetchCompleter.future;

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();

    final future = provider.fetch();
    await Future<void>.delayed(Duration.zero);
    expect(provider.isRunning(GitOperationType.fetch), isTrue);
    expect(provider.activeOperationLabel, contains('Fetching'));

    fetchCompleter.complete(_repo(_updatedRepositoryDocument));
    await future;

    expect(provider.isRunning(GitOperationType.fetch), isFalse);
    expect(provider.feedback?.kind, GitFeedbackKind.success);
    expect(provider.feedback?.message, contains('Fetch completed'));
  });

  test('GitProvider exposes error feedback when an operation fails', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_initialRepositoryDocument))
      ..pushError = const ApiException('Push rejected by remote', 502);

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();
    await provider.push();

    expect(provider.isRunning(GitOperationType.push), isFalse);
    expect(provider.error, contains('Push rejected by remote'));
    expect(provider.feedback?.kind, GitFeedbackKind.error);
  });

  test('GitProvider blocks empty commit messages before hitting the API', () async {
    final settings = await _createSettings();
    final client = _RecordingGitApiClient(settings)
      ..repositoryResponses.add(_repo(_updatedRepositoryDocument));

    final provider = GitProvider(apiClient: client)..setWorkDir('/workspace/repo');
    await provider.refreshRepository();
    await provider.commit('   ');

    expect(client.commitMessages, isEmpty);
    expect(provider.error, 'Commit message cannot be empty');
    expect(provider.feedback?.kind, GitFeedbackKind.error);
  });
}

GitRepositoryState _repo(Map<String, dynamic> json) {
  return GitRepositoryState.fromJson(
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
  );
}

class _RecordingGitApiClient extends GitApiClient {
  _RecordingGitApiClient(SettingsService settings)
      : channel = _FakeWebSocketChannel(),
        super(settings: settings);

  final _FakeWebSocketChannel channel;
  final List<GitRepositoryState> repositoryResponses = <GitRepositoryState>[];
  final List<GitRepositoryState> stageResponses = <GitRepositoryState>[];
  final List<GitRepositoryState> unstageResponses = <GitRepositoryState>[];
  int repositoryFetches = 0;
  Future<GitRepositoryState>? fetchFuture;
  Object? pushError;
  final List<String> commitMessages = <String>[];

  void emitEvent(Map<String, dynamic> event) {
    channel.controller.add(jsonEncode(event));
  }

  @override
  WebSocketChannel connectEventsWebSocket() => channel;

  @override
  Future<GitRepositoryState> getRepository(String path) async {
    repositoryFetches += 1;
    return repositoryResponses.removeAt(0);
  }

  @override
  Future<GitRepositoryState> stageFile(String repoPath, String file) async {
    return stageResponses.removeAt(0);
  }

  @override
  Future<GitRepositoryState> unstageFile(String repoPath, String file) async {
    return unstageResponses.removeAt(0);
  }

  @override
  Future<GitRepositoryState> fetch(String repoPath, {String? remote}) async {
    if (fetchFuture != null) {
      return fetchFuture!;
    }
    return _repo(_updatedRepositoryDocument);
  }

  @override
  Future<GitRepositoryState> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
  }) async {
    if (pushError != null) {
      throw pushError!;
    }
    return _repo(_updatedRepositoryDocument);
  }

  @override
  Future<GitRepositoryState> commit(String repoPath, String message) async {
    commitMessages.add(message);
    return _repo(_updatedRepositoryDocument);
  }
}

class _FakeWebSocketChannel with StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeWebSocketChannel()
      : controller = StreamController<dynamic>.broadcast(sync: true),
        _sinkController = StreamController<dynamic>(sync: true),
        _ready = Completer<void>() {
    _ready.complete();
    _sink = _FakeWebSocketSink(_sinkController.sink);
  }

  final StreamController<dynamic> controller;
  final StreamController<dynamic> _sinkController;
  final Completer<void> _ready;
  late final _FakeWebSocketSink _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  WebSocketSink get sink => _sink;
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._sink);

  bool closed = false;
  final StreamSink<dynamic> _sink;

  @override
  void add(dynamic event) => _sink.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _sink.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<dynamic> stream) => _sink.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
    await _sink.close();
  }

  @override
  Future<void> get done => _sink.done;
}
