import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vscode_mobile/models/terminal_session.dart';
import 'package:vscode_mobile/services/terminal_api_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RecordingTerminalSink implements WebSocketSink {
  final List<dynamic> sentMessages = <dynamic>[];
  bool isClosed = false;

  @override
  void add(dynamic event) {
    sentMessages.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    isClosed = true;
  }

  @override
  Future<void> get done async {}
}

class RecordingTerminalChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  RecordingTerminalChannel()
    : _controller = StreamController<dynamic>.broadcast(),
      _sink = RecordingTerminalSink();

  final StreamController<dynamic> _controller;
  final RecordingTerminalSink _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  RecordingTerminalSink get sink => _sink;

  void serverSend(Map<String, dynamic> payload) {
    _controller.add(jsonEncode(payload));
  }

  void serverReady([TerminalSession? session]) {
    serverSend(<String, dynamic>{
      'type': 'ready',
      if (session != null) 'session': sessionToJson(session),
    });
  }

  void serverOutput(String text) {
    serverSend(<String, dynamic>{
      'type': 'output',
      'data': base64Encode(utf8.encode(text)),
    });
  }

  void serverError(String message) {
    serverSend(<String, dynamic>{'type': 'error', 'error': message});
  }

  void serverExit(TerminalSession session) {
    serverSend(<String, dynamic>{
      'type': 'exit',
      'session': sessionToJson(session),
    });
  }

  Future<void> closeStream() async {
    await _controller.close();
  }
}

class FakeTerminalApiClient extends TerminalApiClient {
  FakeTerminalApiClient({
    List<TerminalSession>? seedSessions,
    RecordingTerminalChannel? eventsChannel,
  }) : _eventsChannel = eventsChannel ?? RecordingTerminalChannel(),
       super(
         baseUrl: 'http://server.test',
         token: 'secret',
         client: MockClient((http.Request request) async {
           throw StateError(
             'Unexpected HTTP request in FakeTerminalApiClient: '
             '${request.method} ${request.url}',
           );
         }),
       ) {
    for (final session in seedSessions ?? const <TerminalSession>[]) {
      sessionsById[session.id] = session;
    }
  }

  final Map<String, TerminalSession> sessionsById = <String, TerminalSession>{};
  final Map<String, RecordingTerminalChannel> socketsBySessionId =
      <String, RecordingTerminalChannel>{};
  final RecordingTerminalChannel _eventsChannel;

  final List<String> listCalls = <String>[];
  final List<String> attachCalls = <String>[];
  final List<String> closeCalls = <String>[];
  final List<Map<String, String>> renameCalls = <Map<String, String>>[];
  final List<Map<String, String>> splitCalls = <Map<String, String>>[];
  int connectEventsCalls = 0;

  List<TerminalSession> get sessions =>
      sessionsById.values.toList(growable: false);

  RecordingTerminalChannel socketFor(String sessionId) {
    return socketsBySessionId.putIfAbsent(
      sessionId,
      RecordingTerminalChannel.new,
    );
  }

  RecordingTerminalChannel get eventsChannel => _eventsChannel;

  @override
  Future<List<TerminalSession>> listSessions() async {
    listCalls.add('list');
    return sessions;
  }

  @override
  Future<TerminalSession> createSession({
    required String workDir,
    String? name,
    String profile = '',
    int? rows,
    int? cols,
  }) async {
    final id = 'created-${sessionsById.length + 1}';
    final session = TerminalSession(
      id: id,
      name: name ?? 'Terminal ${sessionsById.length + 1}',
      cwd: workDir,
      profile: profile,
      state: 'running',
    );
    sessionsById[id] = session;
    return session;
  }

  @override
  Future<TerminalSession> attachSession(String id) async {
    attachCalls.add(id);
    final session = sessionsById[id];
    if (session == null) {
      throw StateError('Unknown session $id');
    }
    return session;
  }

  @override
  Future<TerminalSession> resizeSession(String id, int rows, int cols) async {
    final session = sessionsById[id];
    if (session == null) {
      throw StateError('Unknown session $id');
    }
    return session;
  }

  @override
  Future<TerminalSession> renameSession(String id, String name) async {
    renameCalls.add(<String, String>{'id': id, 'name': name});
    final current = sessionsById[id];
    if (current == null) {
      throw StateError('Unknown session $id');
    }
    final updated = TerminalSession(
      id: current.id,
      name: name,
      cwd: current.cwd,
      profile: current.profile,
      state: current.state,
      exitCode: current.exitCode,
    );
    sessionsById[id] = updated;
    return updated;
  }

  @override
  Future<TerminalSession> splitSession(String parentId, {String? name}) async {
    splitCalls.add(<String, String>{'parentId': parentId});
    final parent = sessionsById[parentId];
    if (parent == null) {
      throw StateError('Unknown session $parentId');
    }
    final split = TerminalSession(
      id: 'split-${sessionsById.length + 1}',
      name: name ?? '${parent.name} split',
      cwd: parent.cwd,
      profile: parent.profile,
      state: 'running',
    );
    sessionsById[split.id] = split;
    return split;
  }

  @override
  Future<TerminalSession> closeSession(String id) async {
    closeCalls.add(id);
    final session = sessionsById.remove(id);
    if (session == null) {
      throw StateError('Unknown session $id');
    }
    return TerminalSession(
      id: session.id,
      name: session.name,
      cwd: session.cwd,
      profile: session.profile,
      state: 'exited',
      exitCode: session.exitCode,
    );
  }

  @override
  WebSocketChannel connectTerminalWebSocket(String id) => socketFor(id);

  @override
  WebSocketChannel connectEventsWebSocket() {
    connectEventsCalls += 1;
    return _eventsChannel;
  }

  void emitEvent(String type, Map<String, dynamic> payload) {
    _eventsChannel.serverSend(<String, dynamic>{
      'type': type,
      'payload': payload,
    });
  }

  Future<void> disposeFakes() async {
    for (final channel in socketsBySessionId.values) {
      await channel.closeStream();
    }
    await _eventsChannel.closeStream();
  }
}

TerminalSession terminalSession({
  required String id,
  required String name,
  String cwd = '/workspace',
  String profile = 'bash',
  String state = 'running',
  int? exitCode,
}) {
  return TerminalSession(
    id: id,
    name: name,
    cwd: cwd,
    profile: profile,
    state: state,
    exitCode: exitCode,
  );
}

Map<String, dynamic> sessionToJson(TerminalSession session) {
  return <String, dynamic>{
    'id': session.id,
    'name': session.name,
    'cwd': session.cwd,
    'profile': session.profile,
    'state': session.state,
    if (session.exitCode != null) 'exitCode': session.exitCode,
  };
}

Future<dynamic> invokeAnyAsync(
  List<Future<dynamic> Function()> candidates,
) async {
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return await candidate();
    } on NoSuchMethodError catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? StateError('No dynamic invocation matched');
}

dynamic readAny(List<dynamic Function()> candidates) {
  Object? lastError;
  for (final candidate in candidates) {
    try {
      return candidate();
    } on NoSuchMethodError catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? StateError('No dynamic getter matched');
}

String? readStringProperty(dynamic target, List<String> names) {
  for (final name in names) {
    try {
      final value = readAny(<dynamic Function()>[
        () => (target as dynamic).toJson()[name],
        () => (target as dynamic).toMap()[name],
        () => (target as dynamic).__getattribute__(name),
      ]);
      if (value != null) {
        return '$value';
      }
    } on NoSuchMethodError {
      try {
        final value = switch (name) {
          'id' => (target as dynamic).id,
          'name' => (target as dynamic).name,
          'state' => (target as dynamic).state,
          'status' => (target as dynamic).status,
          'output' => (target as dynamic).output,
          'backlog' => (target as dynamic).backlog,
          'buffer' => (target as dynamic).buffer,
          'history' => (target as dynamic).history,
          'text' => (target as dynamic).text,
          _ => null,
        };
        if (value != null) {
          return '$value';
        }
      } on NoSuchMethodError {
        continue;
      }
    }
  }
  return null;
}

int? readIntProperty(dynamic target, List<String> names) {
  for (final name in names) {
    try {
      final value = switch (name) {
        'exitCode' => (target as dynamic).exitCode,
        'exitStatus' => (target as dynamic).exitStatus,
        _ => null,
      };
      if (value == null) {
        continue;
      }
      if (value is int) {
        return value;
      }
      return int.tryParse('$value');
    } on NoSuchMethodError {
      continue;
    }
  }
  return null;
}

Future<void> pumpMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
