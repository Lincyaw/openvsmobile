import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/diagnostic.dart';
import '../models/editor_models.dart';
import 'api_client.dart' show ApiException;
import 'settings_service.dart';

typedef EditorChannelFactory = WebSocketChannel Function(Uri uri);

class EditorApiClient {
  EditorApiClient({
    required SettingsService settings,
    http.Client? client,
    EditorChannelFactory? channelFactory,
  }) : _settings = settings,
       _client = client ?? http.Client(),
       _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final SettingsService _settings;
  final http.Client _client;
  final EditorChannelFactory _channelFactory;

  String get baseUrl => _settings.serverUrl;
  String get token => _settings.authToken;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Uri _httpUri(String path, {Map<String, String>? queryParams}) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (queryParams != null && queryParams.isNotEmpty) {
      return Uri.parse('$base$path').replace(queryParameters: queryParams);
    }
    return Uri.parse('$base$path');
  }

  Uri _wsUri(String path) {
    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    return Uri.parse('$base$path?token=$token');
  }

  Future<BridgeCapabilitiesDocument> getCapabilities() async {
    final response = await _client.get(
      _httpUri('/bridge/capabilities'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _ensureSuccess(response, 'load bridge capabilities');
    return BridgeCapabilitiesDocument.fromJson(
      _decodeMap(response.body, 'bridge capabilities'),
    );
  }

  WebSocketChannel connectEventsWebSocket() {
    return _channelFactory(_wsUri('/bridge/ws/events'));
  }

  Future<DocumentSnapshot> openDocument({
    required String path,
    required int version,
    String? content,
  }) async {
    final response = await _post('/bridge/doc/open', <String, dynamic>{
      'path': path,
      'version': version,
      ...?content == null ? null : <String, dynamic>{'content': content},
    }, action: 'open document');
    return DocumentSnapshot.fromJson(
      _decodeMap(response.body, 'document open'),
    );
  }

  Future<DocumentSnapshot> changeDocument({
    required String path,
    required int version,
    required List<DocumentChange> changes,
  }) async {
    final response = await _post('/bridge/doc/change', <String, dynamic>{
      'path': path,
      'version': version,
      'changes': changes.map((change) => change.toJson()).toList(),
    }, action: 'change document');
    return DocumentSnapshot.fromJson(
      _decodeMap(response.body, 'document change'),
    );
  }

  Future<DocumentSnapshot> saveDocument(String path) async {
    final response = await _post('/bridge/doc/save', <String, dynamic>{
      'path': path,
    }, action: 'save document');
    return DocumentSnapshot.fromJson(
      _decodeMap(response.body, 'document save'),
    );
  }

  Future<void> closeDocument(String path) async {
    await _post('/bridge/doc/close', <String, dynamic>{
      'path': path,
    }, action: 'close document');
  }

  Future<List<Diagnostic>> diagnostics({
    required String path,
    required int version,
    String? workDir,
  }) async {
    final response =
        await _post('/bridge/editor/diagnostics', <String, dynamic>{
          'path': path,
          'version': version,
          if (workDir != null && workDir.isNotEmpty) 'workDir': workDir,
        }, action: 'load diagnostics');
    return Diagnostic.listFromReportJson(
      _decodeMap(response.body, 'editor diagnostics report'),
    );
  }

  Future<EditorCompletionList> completion({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/completion',
      _editorPayload(
        path: path,
        version: version,
        position: position,
        workDir: workDir,
      ),
      action: 'request completion',
    );
    return EditorCompletionList.fromJson(
      _decodeMap(response.body, 'completion response'),
    );
  }

  Future<EditorHover> hover({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/hover',
      _editorPayload(
        path: path,
        version: version,
        position: position,
        workDir: workDir,
      ),
      action: 'request hover',
    );
    return EditorHover.fromJson(_decodeMap(response.body, 'hover response'));
  }

  Future<List<EditorLocation>> definition({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) {
    return _locationRequest(
      '/bridge/editor/definition',
      action: 'request definition',
      path: path,
      version: version,
      position: position,
      workDir: workDir,
    );
  }

  Future<List<EditorLocation>> references({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) {
    return _locationRequest(
      '/bridge/editor/references',
      action: 'request references',
      path: path,
      version: version,
      position: position,
      workDir: workDir,
    );
  }

  Future<EditorSignatureHelp?> signatureHelp({
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/signature-help',
      _editorPayload(
        path: path,
        version: version,
        position: position,
        workDir: workDir,
      ),
      action: 'request signature help',
    );
    final decoded = _decodeJson(response.body, 'signature help');
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return EditorSignatureHelp.fromJson(decoded);
  }

  Future<List<EditorTextEdit>> formatting({
    required String path,
    required int version,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/formatting',
      _editorPayload(path: path, version: version, workDir: workDir),
      action: 'request formatting',
    );
    return _decodeList(response.body, 'formatting response')
        .whereType<Map>()
        .map(
          (entry) => EditorTextEdit.fromJson(Map<String, dynamic>.from(entry)),
        )
        .toList();
  }

  Future<List<EditorCodeAction>> codeActions({
    required String path,
    required int version,
    required DocumentRange range,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/code-actions',
      _editorPayload(
        path: path,
        version: version,
        range: range,
        workDir: workDir,
      ),
      action: 'request code actions',
    );
    return _decodeList(response.body, 'code actions response')
        .whereType<Map>()
        .map(
          (entry) =>
              EditorCodeAction.fromJson(Map<String, dynamic>.from(entry)),
        )
        .toList();
  }

  Future<EditorWorkspaceEdit> rename({
    required String path,
    required int version,
    required DocumentPosition position,
    required String newName,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/rename',
      _editorPayload(
        path: path,
        version: version,
        position: position,
        workDir: workDir,
        newName: newName,
      ),
      action: 'rename symbol',
    );
    return EditorWorkspaceEdit.fromJson(
      _decodeMap(response.body, 'rename response'),
    );
  }

  Future<List<Map<String, dynamic>>> documentSymbols({
    required String path,
    required int version,
    String? workDir,
  }) async {
    final response = await _post(
      '/bridge/editor/document-symbols',
      _editorPayload(path: path, version: version, workDir: workDir),
      action: 'request document symbols',
    );
    return _decodeList(response.body, 'document symbols response')
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Future<List<EditorLocation>> _locationRequest(
    String endpoint, {
    required String action,
    required String path,
    required int version,
    required DocumentPosition position,
    String? workDir,
  }) async {
    final response = await _post(
      endpoint,
      _editorPayload(
        path: path,
        version: version,
        position: position,
        workDir: workDir,
      ),
      action: action,
    );
    return _decodeList(response.body, 'location response')
        .whereType<Map>()
        .map(
          (entry) => EditorLocation.fromJson(Map<String, dynamic>.from(entry)),
        )
        .toList();
  }

  Map<String, dynamic> _editorPayload({
    required String path,
    required int version,
    DocumentPosition? position,
    DocumentRange? range,
    String? workDir,
    String? newName,
  }) {
    return <String, dynamic>{
      'path': path,
      'version': version,
      if (position != null) 'position': position.toJson(),
      if (range != null) 'range': range.toJson(),
      if (workDir != null && workDir.isNotEmpty) 'workDir': workDir,
      if (newName != null && newName.isNotEmpty) 'newName': newName,
    };
  }

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> payload, {
    required String action,
  }) async {
    final response = await _client.post(
      _httpUri(path),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _ensureSuccess(response, action);
    return response;
  }

  void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw ApiException(
      'Failed to $action: ${_extractErrorMessage(response.body)}',
      response.statusCode,
    );
  }

  Map<String, dynamic> _decodeMap(String body, String action) {
    final decoded = _decodeJson(body, action);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw StateError('unexpected $action payload: $decoded');
  }

  List<dynamic> _decodeList(String body, String action) {
    final decoded = _decodeJson(body, action);
    if (decoded is List<dynamic>) {
      return decoded;
    }
    throw StateError('unexpected $action payload: $decoded');
  }

  dynamic _decodeJson(String body, String action) {
    try {
      return jsonDecode(body);
    } catch (error) {
      throw StateError('failed to decode $action: $error');
    }
  }

  String _extractErrorMessage(String body) {
    if (body.isEmpty) {
      return 'unexpected empty response';
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code'] as String?;
        final message = decoded['message'] as String?;
        if (code != null &&
            code.isNotEmpty &&
            message != null &&
            message.isNotEmpty) {
          return '$code: $message';
        }
        if (message != null && message.isNotEmpty) {
          return message;
        }
        if (code != null && code.isNotEmpty) {
          return code;
        }
      }
    } catch (_) {
      // Fall back to the raw response body.
    }
    return body;
  }

  void dispose() {
    _client.close();
  }
}
