import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/terminal_session.dart';
import '../services/terminal_api_client.dart';
import '../terminal/terminal_emulator.dart';
import '../terminal/terminal_snapshot.dart';

const Duration _terminalReconnectDelay = Duration(seconds: 2);

enum TerminalConnectionState {
  idle,
  loading,
  ready,
  reconnecting,
  exited,
  error,
}

class TerminalSessionBuffer {
  TerminalSessionBuffer({int rows = 24, int cols = 80})
    : emulator = TerminalEmulator(rows: rows, cols: cols);

  final TerminalEmulator emulator;

  String get text => emulator.plainText;

  bool endsWith(String value) {
    if (value.isEmpty) {
      return true;
    }
    return text.endsWith(value);
  }

  bool get isEmpty => text.isEmpty;

  void clear() {
    emulator.reset();
  }

  List<String> append(String chunk) {
    return emulator.write(chunk);
  }

  void restore(String chunk) {
    emulator.reset();
    emulator.write(chunk);
    emulator.drainResponses();
  }

  void resize({required int rows, required int cols}) {
    emulator.resize(rows, cols);
  }
}

class TerminalSessionView {
  TerminalSessionView({required this.session});

  TerminalSession session;
  TerminalConnectionState connectionState = TerminalConnectionState.idle;
  String? error;
  String inputDraft = '';
  int focusRequest = 0;
  final TerminalSessionBuffer buffer = TerminalSessionBuffer();

  bool get isInteractive =>
      session.isRunning && connectionState == TerminalConnectionState.ready;

  String get outputText => buffer.text;
  TerminalSnapshot get snapshot => buffer.emulator.snapshot();

  String get statusLabel {
    switch (connectionState) {
      case TerminalConnectionState.loading:
        return 'Loading';
      case TerminalConnectionState.ready:
        return session.isExited ? 'Exited' : 'Connected';
      case TerminalConnectionState.reconnecting:
        return 'Reconnecting';
      case TerminalConnectionState.exited:
        return session.exitCode == null
            ? 'Exited'
            : 'Exited (${session.exitCode})';
      case TerminalConnectionState.error:
        return 'Error';
      case TerminalConnectionState.idle:
        return session.isExited ? 'Exited' : 'Idle';
    }
  }

  String get helperText {
    switch (connectionState) {
      case TerminalConnectionState.loading:
        return 'Attaching to session...';
      case TerminalConnectionState.reconnecting:
        return 'Connection dropped. Trying to re-attach...';
      case TerminalConnectionState.exited:
        return session.exitCode == null
            ? 'Process exited. You can still inspect the backlog or close this session.'
            : 'Process exited with code ${session.exitCode}. You can still inspect the backlog or close this session.';
      case TerminalConnectionState.error:
        return error ?? 'Unable to connect to this terminal session.';
      case TerminalConnectionState.idle:
        return session.isExited
            ? 'This session already exited. Backlog is still available.'
            : 'Select this session to attach.';
      case TerminalConnectionState.ready:
        return session.isExited
            ? 'Backlog restored from an exited session.'
            : 'Live terminal attached.';
    }
  }
}

class _TerminalSocketBinding {
  WebSocketChannel? channel;
  StreamSubscription<dynamic>? subscription;
  Timer? reconnectTimer;
  bool awaitingBacklogReplay = false;
  bool disposed = false;

  void cancelReconnect() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  Future<void> dispose() async {
    disposed = true;
    cancelReconnect();
    await subscription?.cancel();
    subscription = null;
    await channel?.sink.close();
    channel = null;
  }
}

class TerminalProvider extends ChangeNotifier {
  TerminalProvider({TerminalApiClient? apiClient})
    : _apiClient = apiClient,
      _usesInjectedApiClient = apiClient != null;

  TerminalApiClient? _apiClient;
  final bool _usesInjectedApiClient;
  String _baseUrl = '';
  String _token = '';
  String _workDir = '/';

  final Map<String, TerminalSessionView> _sessionsById =
      <String, TerminalSessionView>{};
  final Map<String, _TerminalSocketBinding> _bindings =
      <String, _TerminalSocketBinding>{};
  final Set<String> _pinnedSessionIds = <String>{};
  List<String> _sessionOrder = <String>[];

  String? _activeSessionId;
  String? _secondarySessionId;
  bool _splitViewEnabled = false;
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _inventoryError;

  bool _disposed = false;

  List<TerminalSessionView> get sessions => _sessionOrder
      .map((id) => _sessionsById[id])
      .whereType<TerminalSessionView>()
      .toList(growable: false);
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get inventoryError => _inventoryError;
  String get workDir => _workDir;
  bool get splitViewEnabled => _splitViewEnabled;
  String? get activeSessionId => _activeSessionId;
  String? get secondarySessionId => _secondarySessionId;
  TerminalSessionView? get activeSession => sessionFor(_activeSessionId);
  TerminalSessionView? get secondarySession => sessionFor(_secondarySessionId);
  bool get hasSessions => _sessionOrder.isNotEmpty;
  bool get hasSecondarySession =>
      _secondarySessionId != null && _secondarySessionId != _activeSessionId;

  bool isPinned(String sessionId) => _pinnedSessionIds.contains(sessionId);

  TerminalSessionView? sessionFor(String? sessionId) {
    if (sessionId == null) {
      return null;
    }
    return _sessionsById[sessionId];
  }

  void configure({
    required String baseUrl,
    required String token,
    required String workDir,
  }) {
    final normalizedWorkDir = workDir.isEmpty ? '/' : workDir;
    final credentialsChanged = baseUrl != _baseUrl || token != _token;
    final workDirChanged = normalizedWorkDir != _workDir;

    if (!credentialsChanged && !workDirChanged) {
      return;
    }

    _baseUrl = baseUrl;
    _token = token;
    _workDir = normalizedWorkDir;

    if (_baseUrl.isEmpty || _token.isEmpty) {
      return;
    }

    if (credentialsChanged) {
      _inventoryError = null;
      if (!_usesInjectedApiClient) {
        _apiClient = TerminalApiClient(baseUrl: _baseUrl, token: _token);
      }
      unawaited(_resetConnections());
    }

    if (_hasLoaded) {
      unawaited(refreshSessions());
    }
  }

  Future<void> ensureInitialized() async {
    if (_hasLoaded) {
      return;
    }
    await refreshSessions(ensureSession: true);
  }

  Future<void> refreshSessions({bool ensureSession = false}) async {
    final apiClient = _apiClient;
    if (apiClient == null || _baseUrl.isEmpty || _token.isEmpty) {
      return;
    }

    _isLoading = true;
    _inventoryError = null;
    notifyListeners();

    try {
      final listed = await apiClient.listSessions();
      _mergeSessions(listed);
      _hasLoaded = true;
      _isLoading = false;
      _inventoryError = null;
      notifyListeners();

      if (_sessionOrder.isEmpty && ensureSession) {
        await createSession();
        return;
      }

      await _ensureAttached(_activeSessionId, reconnecting: false);
      if (_splitViewEnabled) {
        await _ensureAttached(_secondarySessionId, reconnecting: false);
      }
    } catch (error) {
      _isLoading = false;
      _inventoryError = error.toString();
      notifyListeners();
    }
  }

  Future<void> createSession({String? name}) async {
    final apiClient = _apiClient;
    if (apiClient == null) {
      return;
    }

    _isLoading = true;
    _inventoryError = null;
    notifyListeners();

    try {
      final session = await apiClient.createSession(
        workDir: _workDir,
        name: name,
        rows: 24,
        cols: 80,
      );
      _upsertSession(session, requestFocus: true);
      _isLoading = false;
      notifyListeners();
      await activateSession(session.id);
    } catch (error) {
      _isLoading = false;
      _inventoryError = error.toString();
      notifyListeners();
    }
  }

  Future<void> splitSession(String parentId, {String? name}) async {
    final apiClient = _apiClient;
    if (apiClient == null) {
      return;
    }

    try {
      final session = await apiClient.splitSession(parentId, name: name);
      _splitViewEnabled = true;
      _upsertSession(session, requestFocus: true);
      _secondarySessionId = session.id;
      notifyListeners();
      await _ensureAttached(session.id, reconnecting: false);
    } catch (error) {
      _setSessionError(parentId, error.toString());
    }
  }

  Future<void> renameSession(String sessionId, String name) async {
    final apiClient = _apiClient;
    if (apiClient == null) {
      return;
    }

    try {
      final session = await apiClient.renameSession(sessionId, name);
      _upsertSession(session);
      notifyListeners();
    } catch (error) {
      _setSessionError(sessionId, error.toString());
    }
  }

  Future<void> closeSession(String sessionId) async {
    final apiClient = _apiClient;
    if (apiClient == null) {
      return;
    }

    try {
      await apiClient.closeSession(sessionId);
      await _removeSession(sessionId);
      _reconcileSelection();
      notifyListeners();
    } catch (error) {
      _setSessionError(sessionId, error.toString());
    }
  }

  void togglePinned(String sessionId) {
    if (!_sessionsById.containsKey(sessionId)) {
      return;
    }
    if (_pinnedSessionIds.contains(sessionId)) {
      _pinnedSessionIds.remove(sessionId);
    } else {
      _pinnedSessionIds.add(sessionId);
    }
    _sortSessions();
    notifyListeners();
  }

  Future<void> activateSession(
    String sessionId, {
    bool openInSecondary = false,
  }) async {
    if (!_sessionsById.containsKey(sessionId)) {
      return;
    }

    if (openInSecondary) {
      _splitViewEnabled = true;
      _secondarySessionId = sessionId;
    } else {
      _activeSessionId = sessionId;
      if (_secondarySessionId == sessionId) {
        _secondarySessionId = null;
      }
    }
    _requestFocus(sessionId);
    notifyListeners();
    await _ensureAttached(sessionId, reconnecting: false);
  }

  void setSplitViewEnabled(bool enabled) {
    if (_splitViewEnabled == enabled) {
      return;
    }
    _splitViewEnabled = enabled;
    if (!enabled) {
      _secondarySessionId = null;
    } else if (_secondarySessionId == null && _sessionOrder.length > 1) {
      _secondarySessionId = _sessionOrder.firstWhere(
        (id) => id != _activeSessionId,
        orElse: () => _activeSessionId ?? '',
      );
      if (_secondarySessionId!.isEmpty) {
        _secondarySessionId = null;
      }
    }
    notifyListeners();
    if (_splitViewEnabled) {
      unawaited(_ensureAttached(_secondarySessionId, reconnecting: false));
    }
  }

  void swapSplitSessions() {
    final active = _activeSessionId;
    final secondary = _secondarySessionId;
    if (active == null || secondary == null) {
      return;
    }
    _activeSessionId = secondary;
    _secondarySessionId = active;
    _requestFocus(_activeSessionId!);
    notifyListeners();
  }

  void setInputDraft(String sessionId, String value) {
    final session = _sessionsById[sessionId];
    if (session == null || session.inputDraft == value) {
      return;
    }
    session.inputDraft = value;
    notifyListeners();
  }

  Future<void> sendInput(String sessionId, String input) async {
    final session = _sessionsById[sessionId];
    if (session == null || input.isEmpty) {
      return;
    }

    await _ensureAttached(sessionId, reconnecting: false);
    final binding = _bindings[sessionId];
    if (binding?.channel == null || !session.session.isRunning) {
      return;
    }

    final payload = jsonEncode(<String, String>{
      'type': 'input',
      'data': base64Encode(utf8.encode(input)),
    });
    binding!.channel!.sink.add(payload);
  }

  Future<void> resizeSession(String sessionId, int rows, int cols) async {
    final apiClient = _apiClient;
    if (apiClient == null) {
      return;
    }
    final session = _sessionsById[sessionId];
    if (session == null) {
      return;
    }
    if (session.session.rows == rows && session.session.cols == cols) {
      return;
    }

    try {
      final updated = await apiClient.resizeSession(sessionId, rows, cols);
      _upsertSession(updated);
      notifyListeners();
      if (session.buffer.emulator.snapshot().isAlternateBuffer) {
        await sendInput(sessionId, '\x0C');
      }
    } catch (error) {
      _setSessionError(sessionId, error.toString());
    }
  }

  bool shouldRequestFocus(String sessionId, int lastSeenToken) {
    final session = _sessionsById[sessionId];
    if (session == null) {
      return false;
    }
    return session.focusRequest > lastSeenToken;
  }

  Future<void> _ensureAttached(
    String? sessionId, {
    required bool reconnecting,
  }) async {
    final apiClient = _apiClient;
    if (apiClient == null || sessionId == null) {
      return;
    }
    final session = _sessionsById[sessionId];
    if (session == null || session.session.isExited) {
      if (session != null) {
        session.connectionState = TerminalConnectionState.exited;
        notifyListeners();
      }
      return;
    }

    final existing = _bindings[sessionId];
    if (existing?.channel != null) {
      return;
    }

    final binding = existing ?? _TerminalSocketBinding();
    binding.cancelReconnect();
    _bindings[sessionId] = binding;

    session.connectionState = reconnecting
        ? TerminalConnectionState.reconnecting
        : TerminalConnectionState.loading;
    session.error = null;
    notifyListeners();

    try {
      final attached = await apiClient.attachSession(sessionId);
      _upsertSession(attached, requestFocus: sessionId == _activeSessionId);
      final channel = apiClient.connectTerminalWebSocket(sessionId);
      binding.channel = channel;
      binding.awaitingBacklogReplay = true;
      binding.subscription = channel.stream.listen(
        (dynamic raw) => _handleSocketMessage(sessionId, raw),
        onError: (Object error) => _handleSocketDisconnect(sessionId, error),
        onDone: () => _handleSocketDisconnect(sessionId, null),
      );
      final current = _sessionsById[sessionId];
      if (current != null && current.session.isExited) {
        current.connectionState = TerminalConnectionState.exited;
      }
      notifyListeners();
    } catch (error) {
      session.connectionState = TerminalConnectionState.error;
      session.error = error.toString();
      notifyListeners();
      _scheduleReconnect(sessionId);
    }
  }

  void _handleSocketMessage(String sessionId, dynamic raw) {
    if (_disposed) {
      return;
    }
    if (raw is! String) {
      return;
    }

    final entry = _sessionsById[sessionId];
    if (entry == null) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final type = decoded['type'] as String? ?? '';
      switch (type) {
        case 'ready':
          final sessionJson = decoded['session'];
          if (sessionJson is Map<String, dynamic>) {
            _upsertSession(
              TerminalSession.fromJson(sessionJson),
              requestFocus: sessionId == _activeSessionId,
            );
          }
          entry.connectionState = entry.session.isExited
              ? TerminalConnectionState.exited
              : TerminalConnectionState.ready;
          entry.error = null;
          notifyListeners();
          break;
        case 'output':
        case 'replay':
          final encoded = decoded['data'] as String?;
          if (encoded == null) {
            return;
          }
          final text = utf8.decode(base64Decode(encoded), allowMalformed: true);
          final binding = _bindings[sessionId];
          binding?.awaitingBacklogReplay = false;
          if (type == 'replay') {
            entry.buffer.restore(text);
            if (entry.buffer.emulator.snapshot().isAlternateBuffer) {
              _sendRawInput(binding, '\x0C');
            }
          } else {
            final responses = entry.buffer.append(text);
            _sendEmulatorResponses(binding, responses);
          }
          if (!entry.session.isExited) {
            entry.connectionState = TerminalConnectionState.ready;
          }
          notifyListeners();
          break;
        case 'exit':
        case 'closed':
          final sessionJson = decoded['session'];
          if (sessionJson is Map<String, dynamic>) {
            _upsertSession(TerminalSession.fromJson(sessionJson));
          } else {
            final current = entry.session.copyWith(state: 'exited');
            _upsertSession(current);
          }
          entry.connectionState = TerminalConnectionState.exited;
          notifyListeners();
          break;
        case 'error':
          entry.connectionState = TerminalConnectionState.error;
          entry.error = decoded['error'] as String? ?? 'terminal stream error';
          notifyListeners();
          _scheduleReconnect(sessionId);
          break;
      }
    } catch (error) {
      entry.connectionState = TerminalConnectionState.error;
      entry.error = error.toString();
      notifyListeners();
    }
  }

  void _handleSocketDisconnect(String sessionId, Object? error) {
    if (_disposed) {
      return;
    }
    final binding = _bindings[sessionId];
    if (binding == null || binding.disposed) {
      return;
    }

    binding.channel = null;
    binding.subscription = null;

    final entry = _sessionsById[sessionId];
    if (entry == null) {
      return;
    }
    if (entry.session.isExited) {
      entry.connectionState = TerminalConnectionState.exited;
      notifyListeners();
      return;
    }

    if (error != null) {
      entry.error = error.toString();
    }
    entry.connectionState = TerminalConnectionState.reconnecting;
    notifyListeners();
    _scheduleReconnect(sessionId);
  }

  void _scheduleReconnect(String sessionId) {
    if (_disposed) {
      return;
    }
    final binding = _bindings[sessionId];
    final entry = _sessionsById[sessionId];
    if (binding == null || entry == null || entry.session.isExited) {
      return;
    }
    binding.cancelReconnect();
    binding.reconnectTimer = Timer(_terminalReconnectDelay, () {
      if (_disposed || !_sessionsById.containsKey(sessionId)) {
        return;
      }
      unawaited(_ensureAttached(sessionId, reconnecting: true));
    });
  }

  void _sendEmulatorResponses(
    _TerminalSocketBinding? binding,
    List<String> responses,
  ) {
    if (binding?.channel == null || responses.isEmpty) {
      return;
    }
    for (final response in responses) {
      _sendRawInput(binding, response);
    }
  }

  void _sendRawInput(_TerminalSocketBinding? binding, String input) {
    if (binding?.channel == null || input.isEmpty) {
      return;
    }
    final payload = jsonEncode(<String, String>{
      'type': 'input',
      'data': base64Encode(utf8.encode(input)),
    });
    binding!.channel!.sink.add(payload);
  }

  void _mergeSessions(List<TerminalSession> sessions) {
    final seen = <String>{};
    for (final session in sessions) {
      seen.add(session.id);
      _upsertSession(session);
    }

    final removedIds = _sessionsById.keys
        .where((id) => !seen.contains(id))
        .toList(growable: false);
    for (final id in removedIds) {
      unawaited(_removeSession(id));
    }

    _sortSessions();
    _reconcileSelection();
  }

  void _upsertSession(TerminalSession session, {bool requestFocus = false}) {
    final existing = _sessionsById[session.id];
    if (existing == null) {
      final created = TerminalSessionView(session: session);
      if (session.rows != null && session.cols != null) {
        created.buffer.resize(rows: session.rows!, cols: session.cols!);
      }
      created.connectionState = session.isExited
          ? TerminalConnectionState.exited
          : TerminalConnectionState.idle;
      _sessionsById[session.id] = created;
      _sessionOrder = <String>[..._sessionOrder, session.id];
      _activeSessionId ??= session.id;
      if (requestFocus) {
        created.focusRequest++;
      }
    } else {
      existing.session = session;
      if (session.rows != null && session.cols != null) {
        existing.buffer.resize(rows: session.rows!, cols: session.cols!);
      }
      if (session.isExited) {
        existing.connectionState = TerminalConnectionState.exited;
      } else if (existing.connectionState == TerminalConnectionState.exited) {
        existing.connectionState = TerminalConnectionState.idle;
      }
      if (requestFocus) {
        existing.focusRequest++;
      }
    }
    _sortSessions();
    _reconcileSelection();
  }

  void _sortSessions() {
    final ids = _sessionsById.keys.toList(growable: false);
    ids.sort((leftId, rightId) {
      final left = _sessionsById[leftId]!.session;
      final right = _sessionsById[rightId]!.session;
      final leftPinned = _pinnedSessionIds.contains(leftId);
      final rightPinned = _pinnedSessionIds.contains(rightId);
      if (leftPinned != rightPinned) {
        return leftPinned ? -1 : 1;
      }
      if (left.isRunning != right.isRunning) {
        return left.isRunning ? -1 : 1;
      }
      final nameCompare = left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
      if (nameCompare != 0) {
        return nameCompare;
      }
      return left.id.compareTo(right.id);
    });
    _sessionOrder = ids;
  }

  void _reconcileSelection() {
    if (_sessionOrder.isEmpty) {
      _activeSessionId = null;
      _secondarySessionId = null;
      return;
    }

    if (_activeSessionId == null ||
        !_sessionsById.containsKey(_activeSessionId)) {
      _activeSessionId = _preferredSessionId();
    }

    if (_secondarySessionId != null &&
        (!_sessionsById.containsKey(_secondarySessionId) ||
            _secondarySessionId == _activeSessionId)) {
      _secondarySessionId = null;
    }

    if (_splitViewEnabled &&
        _secondarySessionId == null &&
        _sessionOrder.length > 1) {
      _secondarySessionId = _sessionOrder.firstWhere(
        (id) => id != _activeSessionId,
        orElse: () => _activeSessionId ?? '',
      );
      if (_secondarySessionId == _activeSessionId) {
        _secondarySessionId = null;
      }
    }
  }

  String _preferredSessionId() {
    for (final id in _sessionOrder) {
      final session = _sessionsById[id]!.session;
      if (session.cwd == _workDir && session.isRunning) {
        return id;
      }
    }
    return _sessionOrder.first;
  }

  void _requestFocus(String sessionId) {
    final session = _sessionsById[sessionId];
    if (session == null) {
      return;
    }
    session.focusRequest++;
  }

  void _setSessionError(String sessionId, String message) {
    final session = _sessionsById[sessionId];
    if (session == null) {
      _inventoryError = message;
      notifyListeners();
      return;
    }
    session.connectionState = TerminalConnectionState.error;
    session.error = message;
    notifyListeners();
  }

  Future<void> _removeSession(String sessionId, {bool notify = false}) async {
    final binding = _bindings.remove(sessionId);
    await binding?.dispose();
    _pinnedSessionIds.remove(sessionId);
    _sessionsById.remove(sessionId);
    _sessionOrder = _sessionOrder.where((id) => id != sessionId).toList();
    if (_activeSessionId == sessionId) {
      _activeSessionId = null;
    }
    if (_secondarySessionId == sessionId) {
      _secondarySessionId = null;
    }
    _reconcileSelection();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _resetConnections() async {
    final bindings = _bindings.values.toList(growable: false);
    _bindings.clear();
    for (final binding in bindings) {
      await binding.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_resetConnections());
    super.dispose();
  }
}
