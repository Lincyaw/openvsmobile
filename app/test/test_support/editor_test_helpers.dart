import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vscode_mobile/models/diagnostic.dart';
import 'package:vscode_mobile/models/editor_models.dart';
import 'package:vscode_mobile/models/search_result.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/editor_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<SettingsService> createTestSettings({
  String serverUrl = 'http://server.test',
  String token = 'dev-token',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsService();
  await settings.load();
  await settings.save(serverUrl, token);
  return settings;
}

Future<void> settleAsync([int turns = 6]) async {
  for (var index = 0; index < turns; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> pumpEditorUi(
  WidgetTester tester, {
  Duration settleFor = const Duration(milliseconds: 350),
}) async {
  await tester.pump();
  await tester.pump(settleFor);
}

Future<void> disposeEditorHarness(
  EditorProvider provider,
  FakeEditorApiClient editorApi,
  WidgetTester? tester,
) async {
  if (tester != null) {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
  provider.dispose();
  if (!editorApi.eventsChannel.sink.isClosed) {
    await editorApi.eventsChannel.sink.close();
  }
}

class RecordingJsonSink implements WebSocketSink {
  final List<dynamic> sentMessages = <dynamic>[];
  bool isClosed = false;

  @override
  void add(dynamic event) {
    if (isClosed) {
      return;
    }
    sentMessages.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final dynamic event in stream) {
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

class RecordingJsonChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  RecordingJsonChannel()
    : _controller = StreamController<dynamic>.broadcast(),
      _sink = RecordingJsonSink();

  final StreamController<dynamic> _controller;
  final RecordingJsonSink _sink;
  bool _isDisposed = false;

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
  RecordingJsonSink get sink => _sink;

  void serverSendJson(Map<String, dynamic> payload) {
    if (_isDisposed || _controller.isClosed) {
      return;
    }
    _controller.add(jsonEncode(payload));
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _sink.close();
    await _controller.close();
  }
}

class FakeFileApiClient extends ApiClient {
  FakeFileApiClient({
    Map<String, String>? seedFiles,
    Map<String, List<Diagnostic>>? seedDiagnostics,
    List<Map<String, dynamic>>? seedFileSearchResults,
    List<ContentSearchResult>? seedContentSearchResults,
    SettingsService? settings,
    super.client,
  }) : files = Map<String, String>.from(seedFiles ?? const <String, String>{}),
       diagnosticsByPath = Map<String, List<Diagnostic>>.from(
         seedDiagnostics ?? const <String, List<Diagnostic>>{},
       ),
       fileSearchResults = List<Map<String, dynamic>>.from(
         seedFileSearchResults ?? const <Map<String, dynamic>>[],
       ),
       contentSearchResults = List<ContentSearchResult>.from(
         seedContentSearchResults ?? const <ContentSearchResult>[],
       ),
       super(settings: settings ?? SettingsService());

  final Map<String, String> files;
  final Map<String, List<Diagnostic>> diagnosticsByPath;
  final List<Map<String, dynamic>> lifecycleCalls = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> fileSearchResults;
  final List<ContentSearchResult> contentSearchResults;

  @override
  Future<String> readFile(String path) async {
    lifecycleCalls.add(<String, dynamic>{'method': 'readFile', 'path': path});
    return files[path] ?? '';
  }

  @override
  Future<void> writeFile(String path, String content) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'writeFile',
      'path': path,
      'content': content,
    });
    files[path] = content;
  }

  @override
  Future<List<Diagnostic>> getDiagnostics({
    String? filePath,
    String workDir = '/',
  }) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'getDiagnostics',
      'path': filePath,
      'workDir': workDir,
    });
    return List<Diagnostic>.from(
      diagnosticsByPath[filePath] ?? const <Diagnostic>[],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> searchFiles(
    String query,
    String path,
  ) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'searchFiles',
      'query': query,
      'path': path,
    });
    return List<Map<String, dynamic>>.from(fileSearchResults);
  }

  @override
  Future<List<ContentSearchResult>> searchContent(
    String query,
    String path,
  ) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'searchContent',
      'query': query,
      'path': path,
    });
    return List<ContentSearchResult>.from(contentSearchResults);
  }
}

class FakeEditorApiClient extends EditorApiClient {
  FakeEditorApiClient({
    BridgeCapabilitiesDocument? capabilities,
    Map<String, String>? seedDocuments,
    RecordingJsonChannel? eventsChannel,
    SettingsService? settings,
  }) : _capabilities = capabilities ?? defaultCapabilities(),
       documents = Map<String, String>.from(
         seedDocuments ?? const <String, String>{},
       ),
       eventsChannel = eventsChannel ?? RecordingJsonChannel(),
       super(settings: settings ?? SettingsService());

  final Map<String, String> documents;
  final RecordingJsonChannel eventsChannel;
  final List<Map<String, dynamic>> lifecycleCalls = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> rpcCalls = <Map<String, dynamic>>[];
  final Map<String, int> versionsByPath = <String, int>{};

  BridgeCapabilitiesDocument _capabilities;
  List<Diagnostic> diagnosticsResponse = const <Diagnostic>[];
  EditorCompletionList completionResponse = const EditorCompletionList(
    isIncomplete: false,
    items: <EditorCompletionItem>[],
  );
  EditorHover hoverResponse = const EditorHover(contents: 'hover');
  List<EditorLocation> definitionResponse = const <EditorLocation>[];
  List<EditorLocation> referencesResponse = const <EditorLocation>[];
  EditorSignatureHelp? signatureHelpResponse;
  List<EditorTextEdit> formattingResponse = const <EditorTextEdit>[];
  List<EditorCodeAction> codeActionsResponse = const <EditorCodeAction>[];
  EditorWorkspaceEdit renameResponse = const EditorWorkspaceEdit(
    changes: <String, List<EditorTextEdit>>{},
  );
  List<Map<String, dynamic>> documentSymbolsResponse =
      const <Map<String, dynamic>>[];

  Future<DocumentSnapshot> Function(String path, int version, String? content)?
  openDocumentHandler;
  Future<DocumentSnapshot> Function(
    String path,
    int version,
    List<DocumentChange> changes,
  )?
  changeDocumentHandler;
  Future<DocumentSnapshot> Function(String path)? saveDocumentHandler;
  Future<void> Function(String path)? closeDocumentHandler;

  set capabilitiesDocument(BridgeCapabilitiesDocument value) {
    _capabilities = value;
  }

  @override
  Future<BridgeCapabilitiesDocument> getCapabilities() async => _capabilities;

  Map<String, dynamic> _workDirField(String? workDir) => workDir == null
      ? const <String, dynamic>{}
      : <String, dynamic>{'workDir': workDir};

  Map<String, dynamic> _contentField(String? content) => content == null
      ? const <String, dynamic>{}
      : <String, dynamic>{'content': content};

  @override
  WebSocketChannel connectEventsWebSocket() => eventsChannel;

  @override
  Future<DocumentSnapshot> openDocument({
    required String path,
    required int version,
    String? content,
  }) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'doc/open',
      'path': path,
      'version': version,
      ..._contentField(content),
    });
    if (openDocumentHandler != null) {
      return openDocumentHandler!(path, version, content);
    }
    if (content != null) {
      documents[path] = content;
    }
    versionsByPath[path] = version;
    return DocumentSnapshot(
      path: path,
      version: version,
      content: documents[path] ?? content ?? '',
    );
  }

  @override
  Future<DocumentSnapshot> changeDocument({
    required String path,
    required int version,
    required List<DocumentChange> changes,
  }) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'doc/change',
      'path': path,
      'version': version,
      'changes': changes
          .map((DocumentChange change) => change.toJson())
          .toList(),
    });
    if (changeDocumentHandler != null) {
      return changeDocumentHandler!(path, version, changes);
    }
    final fullReplacement = changes.lastWhere(
      (DocumentChange change) => change.range == null,
      orElse: () => DocumentChange.fullReplacement(documents[path] ?? ''),
    );
    documents[path] = fullReplacement.text;
    versionsByPath[path] = version;
    return DocumentSnapshot(
      path: path,
      version: version,
      content: documents[path] ?? '',
    );
  }

  @override
  Future<DocumentSnapshot> saveDocument(String path) async {
    lifecycleCalls.add(<String, dynamic>{'method': 'doc/save', 'path': path});
    if (saveDocumentHandler != null) {
      return saveDocumentHandler!(path);
    }
    return DocumentSnapshot(
      path: path,
      version: versionsByPath[path] ?? 1,
      content: documents[path] ?? '',
    );
  }

  @override
  Future<void> closeDocument(String path) async {
    lifecycleCalls.add(<String, dynamic>{'method': 'doc/close', 'path': path});
    if (closeDocumentHandler != null) {
      await closeDocumentHandler!(path);
    }
  }

  @override
  Future<List<Diagnostic>> diagnostics({
    required String path,
    required int version,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'diagnostics',
      'path': path,
      'version': version,
      ..._workDirField(workDir),
    });
    return List<Diagnostic>.from(diagnosticsResponse);
  }

  @override
  Future<EditorCompletionList> completion({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'completion',
      'path': path,
      'version': version,
      'position': position.toJson(),
      ..._workDirField(workDir),
    });
    return completionResponse;
  }

  @override
  Future<EditorHover> hover({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'hover',
      'path': path,
      'version': version,
      'position': position.toJson(),
      ..._workDirField(workDir),
    });
    return hoverResponse;
  }

  @override
  Future<List<EditorLocation>> definition({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'definition',
      'path': path,
      'version': version,
      'position': position.toJson(),
      ..._workDirField(workDir),
    });
    return List<EditorLocation>.from(definitionResponse);
  }

  @override
  Future<List<EditorLocation>> references({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'references',
      'path': path,
      'version': version,
      'position': position.toJson(),
      ..._workDirField(workDir),
    });
    return List<EditorLocation>.from(referencesResponse);
  }

  @override
  Future<EditorSignatureHelp?> signatureHelp({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'signatureHelp',
      'path': path,
      'version': version,
      'position': position.toJson(),
      ..._workDirField(workDir),
    });
    return signatureHelpResponse;
  }

  @override
  Future<List<EditorTextEdit>> formatting({
    required String path,
    required int version,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'formatting',
      'path': path,
      'version': version,
      ..._workDirField(workDir),
    });
    return List<EditorTextEdit>.from(formattingResponse);
  }

  @override
  Future<List<EditorCodeAction>> codeActions({
    required String path,
    required int version,
    required DocumentRange range,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'codeActions',
      'path': path,
      'version': version,
      'range': range.toJson(),
      ..._workDirField(workDir),
    });
    return List<EditorCodeAction>.from(codeActionsResponse);
  }

  @override
  Future<EditorWorkspaceEdit> rename({
    required String path,
    required int version,
    required DocumentPosition position,
    required String newName,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'rename',
      'path': path,
      'version': version,
      'position': position.toJson(),
      'newName': newName,
      ..._workDirField(workDir),
    });
    return renameResponse;
  }

  @override
  Future<List<Map<String, dynamic>>> documentSymbols({
    required String path,
    required int version,
    String? workDir,
  }) async {
    rpcCalls.add(<String, dynamic>{
      'method': 'documentSymbols',
      'path': path,
      'version': version,
      ..._workDirField(workDir),
    });
    return List<Map<String, dynamic>>.from(documentSymbolsResponse);
  }

  Future<void> disposeFakes() async {
    await Future<void>.delayed(Duration.zero);
    await eventsChannel.dispose();
    await Future<void>.delayed(Duration.zero);
  }
}

BridgeCapabilitiesDocument defaultCapabilities({
  Map<String, dynamic>? overrides,
}) {
  return BridgeCapabilitiesDocument.fromJson(<String, dynamic>{
    'state': 'ready',
    'generation': 'gen-1',
    'protocolVersion': '2026-04-20',
    'bridgeVersion': '0.3.0',
    'capabilities': <String, dynamic>{
      'diagnostics': <String, dynamic>{'enabled': true},
      'completion': <String, dynamic>{'enabled': true, 'textEdit': true},
      'hover': <String, dynamic>{'enabled': true},
      'definition': <String, dynamic>{'enabled': true},
      'references': <String, dynamic>{'enabled': true},
      'signatureHelp': <String, dynamic>{'enabled': true},
      'formatting': <String, dynamic>{'enabled': true},
      'codeActions': <String, dynamic>{'enabled': true},
      'rename': <String, dynamic>{'enabled': true},
      ...?overrides,
    },
  });
}

Diagnostic diagnostic({
  String path = '/workspace/lib/main.dart',
  int startLine = 0,
  int startCharacter = 0,
  int endLine = 0,
  int endCharacter = 1,
  String severity = 'error',
  String message = 'Example problem',
  String source = 'test',
}) {
  return Diagnostic(
    filePath: path,
    range: DocumentRange(
      start: DocumentPosition(line: startLine, character: startCharacter),
      end: DocumentPosition(line: endLine, character: endCharacter),
    ),
    severity: severity,
    message: message,
    source: source,
  );
}

EditorLocation location({
  required String path,
  int startLine = 0,
  int startCharacter = 0,
  int endLine = 0,
  int endCharacter = 1,
}) {
  return EditorLocation(
    uri: Uri.file(path).toString(),
    path: path,
    range: DocumentRange(
      start: DocumentPosition(line: startLine, character: startCharacter),
      end: DocumentPosition(line: endLine, character: endCharacter),
    ),
  );
}

EditorTextEdit textEdit({
  required int startLine,
  required int startCharacter,
  required int endLine,
  required int endCharacter,
  required String newText,
}) {
  return EditorTextEdit(
    range: DocumentRange(
      start: DocumentPosition(line: startLine, character: startCharacter),
      end: DocumentPosition(line: endLine, character: endCharacter),
    ),
    newText: newText,
  );
}

EditorCompletionItem completionItem({
  required String label,
  String detail = '',
  String? insertText,
  EditorTextEdit? primaryEdit,
  List<EditorTextEdit> additionalTextEdits = const <EditorTextEdit>[],
  dynamic documentation,
}) {
  return EditorCompletionItem(
    label: label,
    detail: detail,
    insertText: insertText,
    textEdit: primaryEdit,
    additionalTextEdits: List<EditorTextEdit>.from(additionalTextEdits),
    documentation: documentation,
    raw: <String, dynamic>{'label': label},
  );
}

Widget wrapWithMaterialApp({
  required Widget child,
  List<SingleChildWidget> providers = const <SingleChildWidget>[],
}) {
  return MultiProvider(
    providers: providers,
    child: MaterialApp(home: child),
  );
}
