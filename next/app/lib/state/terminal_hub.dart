// Multi-backend terminal aggregation.
//
// Files / Plugins / Notifications remain scoped to the active backend via
// AppState. Terminals are different: they are lightweight, long-lived PTYs
// that users expect to scan across all saved backend hosts. This hub owns one
// terminal-only BackendClient per saved backend and groups sessions by host.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../backend_client.dart';
import '../models.dart';
import '../settings_store.dart';
import 'terminals_notifier.dart';

typedef TerminalHubClientFactory = BackendClient Function();

@immutable
class BackendTerminalSession {
  final BackendTarget backend;
  final TerminalSession session;

  const BackendTerminalSession({required this.backend, required this.session});

  String get backendId => backend.id;
  String get sessionId => session.id;
  String get key => '${backend.id}:${session.id}';
}

@immutable
class BackendTerminalGroup {
  final BackendTarget backend;
  final BackendConnectionState connectionState;
  final String? lastError;
  final List<TerminalSession> sessions;

  const BackendTerminalGroup({
    required this.backend,
    required this.connectionState,
    required this.lastError,
    required this.sessions,
  });

  bool get isConnected => connectionState == BackendConnectionState.connected;
}

@immutable
class BackendWorkspaceChoice {
  final String root;
  final String label;
  final bool isOpen;

  const BackendWorkspaceChoice({
    required this.root,
    required this.label,
    required this.isOpen,
  });
}

class TerminalHub extends ChangeNotifier {
  TerminalHub({TerminalHubClientFactory? clientFactory, String? deviceId})
    : this._(
        clientFactory: clientFactory ?? BackendClient.new,
        deviceId: deviceId,
      );

  TerminalHub._({required this._clientFactory, this._deviceId});

  final TerminalHubClientFactory _clientFactory;
  final Map<String, _BackendTerminalController> _controllers = {};
  final List<String> _order = [];

  String? _activeBackendId;
  String? _deviceId;
  String? _lastOperationError;

  final ValueNotifier<int> previewVersion = ValueNotifier<int>(0);

  List<BackendTerminalGroup> get groups => [
    for (final id in _order)
      if (_controllers[id] case final controller?)
        BackendTerminalGroup(
          backend: controller.target,
          connectionState: controller.connectionState,
          lastError: controller.lastError,
          sessions: controller.sessions,
        ),
  ];

  String? get activeBackendId => _activeBackendId;
  String? get lastOperationError => _lastOperationError;

  void clearLastOperationError() {
    if (_lastOperationError == null) return;
    _lastOperationError = null;
    notifyListeners();
  }

  void updateBackends(
    List<BackendTarget> targets, {
    String? activeBackendId,
    String? deviceId,
  }) {
    _activeBackendId = activeBackendId;
    _deviceId = deviceId ?? _deviceId;
    final wanted = targets.where((t) => t.isComplete).toList(growable: false);
    final wantedIds = wanted.map((t) => t.id).toSet();

    for (final id in _controllers.keys.toList()) {
      if (wantedIds.contains(id)) continue;
      _controllers.remove(id)?.dispose();
    }

    _order
      ..clear()
      ..addAll(wanted.map((t) => t.id));

    for (final target in wanted) {
      final existing = _controllers[target.id];
      if (existing == null) {
        final controller = _BackendTerminalController(
          target: target,
          client: _clientFactory(),
          deviceId: _deviceId,
          reportError: _reportOperationError,
          onChanged: _onControllerChanged,
          onPreviewChanged: _onPreviewChanged,
        );
        _controllers[target.id] = controller;
        unawaited(controller.start());
        continue;
      }
      if (!existing.hasSameEndpoint(target)) {
        existing.dispose();
        final controller = _BackendTerminalController(
          target: target,
          client: _clientFactory(),
          deviceId: _deviceId,
          reportError: _reportOperationError,
          onChanged: _onControllerChanged,
          onPreviewChanged: _onPreviewChanged,
        );
        _controllers[target.id] = controller;
        unawaited(controller.start());
      } else {
        existing.updateTarget(target, deviceId: _deviceId);
      }
    }
    notifyListeners();
  }

  void requestReconnectNow() {
    for (final controller in _controllers.values) {
      controller.requestReconnectNow();
    }
  }

  Future<void> refreshAll() async {
    await Future.wait([
      for (final controller in _controllers.values)
        controller.refreshSessions(),
    ]);
  }

  List<BackendTerminalSession> sessionsForBackend(String backendId) {
    final controller = _controllers[backendId];
    if (controller == null) return const [];
    return [
      for (final session in controller.sessions)
        BackendTerminalSession(backend: controller.target, session: session),
    ];
  }

  BackendTerminalSession? sessionFor(String backendId, String sessionId) {
    final controller = _controllers[backendId];
    final session = controller?.sessionFor(sessionId);
    if (controller == null || session == null) return null;
    return BackendTerminalSession(backend: controller.target, session: session);
  }

  void focusTerminal(String backendId, String sessionId) {
    _controllers[backendId]?.focusTerminal(sessionId);
  }

  int terminalGenerationFor(String backendId, String sessionId) =>
      _controllers[backendId]?.terminalGenerationFor(sessionId) ?? 0;

  Terminal? terminalForIfKnown(String backendId, String sessionId) =>
      _controllers[backendId]?.terminalForIfKnown(sessionId);

  TerminalPreview previewFor(String backendId, String sessionId) =>
      _controllers[backendId]?.previewFor(sessionId) ??
      const TerminalPreview(text: null, lastDataAt: null);

  Future<TerminalSession?> createTerminal({
    required String backendId,
    String? workspaceId,
    required int cols,
    required int rows,
  }) {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return Future.value(null);
    }
    return controller.createTerminal(
      workspaceId: workspaceId,
      cols: cols,
      rows: rows,
    );
  }

  Future<List<BackendWorkspaceChoice>> listWorkspaceChoices(String backendId) {
    final controller = _controllers[backendId];
    if (controller == null) return Future.value(const []);
    return controller.listWorkspaceChoices();
  }

  String pickerStartPath(String backendId) {
    final controller = _controllers[backendId];
    return controller?.pickerStartPath ?? '/';
  }

  Future<List<DirEntry>> listPickerDir({
    required String backendId,
    required String path,
  }) {
    final controller = _controllers[backendId];
    if (controller == null) {
      return Future.error(StateError('Backend is not available.'));
    }
    return controller.listPickerDir(path);
  }

  Future<void> forgetRecentWorkspace({
    required String backendId,
    required String root,
  }) async {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return;
    }
    await controller.forgetRecentWorkspace(root);
  }

  Future<void> clearRecentWorkspaces(String backendId) async {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return;
    }
    await controller.clearRecentWorkspaces();
  }

  Future<TerminalSession?> createTerminalForWorkspaceRoot({
    required String backendId,
    String? workspaceRoot,
    required int cols,
    required int rows,
  }) {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return Future.value(null);
    }
    return controller.createTerminalForWorkspaceRoot(
      workspaceRoot: workspaceRoot,
      cols: cols,
      rows: rows,
    );
  }

  Future<void> disposeTerminal(String backendId, String sessionId) {
    final controller = _controllers[backendId];
    if (controller == null) return Future.value();
    return controller.disposeTerminal(sessionId);
  }

  Future<void> detachTerminal(String backendId, String sessionId) {
    final controller = _controllers[backendId];
    if (controller == null) return Future.value();
    return controller.detachTerminal(sessionId);
  }

  Future<void> renameTerminal(
    String backendId,
    String sessionId,
    String? title,
  ) {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return Future.value();
    }
    return controller.renameTerminal(sessionId, title);
  }

  Future<List<ExternalTerminalSession>> listExternalSessions(String backendId) {
    final controller = _controllers[backendId];
    if (controller == null) return Future.value(const []);
    return controller.listExternalSessions();
  }

  Future<TerminalSession?> adoptExternalSession({
    required String backendId,
    String? workspaceId,
    required String sessionName,
    required int cols,
    required int rows,
  }) {
    final controller = _controllers[backendId];
    if (controller == null) {
      _reportOperationError('Backend is not available.');
      return Future.value(null);
    }
    return controller.adoptExternalSession(
      workspaceId: workspaceId,
      sessionName: sessionName,
      cols: cols,
      rows: rows,
    );
  }

  void _reportOperationError(String message) {
    _lastOperationError = message;
    notifyListeners();
  }

  void _onControllerChanged() {
    notifyListeners();
  }

  void _onPreviewChanged() {
    previewVersion.value = previewVersion.value + 1;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      unawaited(controller.dispose());
    }
    _controllers.clear();
    previewVersion.dispose();
    super.dispose();
  }
}

class _BackendTerminalController {
  _BackendTerminalController({
    required BackendTarget target,
    required BackendClient client,
    required String? deviceId,
    required ReportOperationError reportError,
    required VoidCallback onChanged,
    required VoidCallback onPreviewChanged,
  }) : this._(
         target: target,
         client: client,
         deviceId: deviceId,
         reportError: reportError,
         onChanged: onChanged,
         onPreviewChanged: onPreviewChanged,
       );

  _BackendTerminalController._({
    required this._target,
    required this._client,
    required this._deviceId,
    required ReportOperationError reportError,
    required this._onChanged,
    required this._onPreviewChanged,
  }) {
    _terminals = TerminalsNotifier(client: _client, reportError: reportError);
    _reportError = reportError;
    _terminals.addListener(_onChanged);
    _terminals.previewVersion.addListener(_onPreviewChanged);
    _client.state.addListener(_onConnectionState);
    _client.lastError.addListener(_onChanged);
    _notifSub = _client.notifications.listen(_onNotification);
    _configureClient();
  }

  BackendTarget _target;
  final BackendClient _client;
  final String? _deviceId;
  final VoidCallback _onChanged;
  final VoidCallback _onPreviewChanged;
  late final ReportOperationError _reportError;
  late final TerminalsNotifier _terminals;
  StreamSubscription<BackendNotification>? _notifSub;
  bool _disposed = false;

  BackendTarget get target => _target;
  BackendConnectionState get connectionState => _client.state.value;
  String? get lastError => _client.lastError.value;
  List<TerminalSession> get sessions => _terminals.currentTerminals;
  String get pickerStartPath =>
      _client.defaultCwd.isNotEmpty ? _client.defaultCwd : '/';

  bool hasSameEndpoint(BackendTarget next) =>
      _target.transport == next.transport &&
      _target.host == next.host &&
      _target.port == next.port &&
      _target.token == next.token &&
      _target.irohTicket == next.irohTicket &&
      _target.irohAlpn == next.irohAlpn;

  void updateTarget(BackendTarget next, {String? deviceId}) {
    _target = next;
    if (deviceId != null) {
      _client.deviceId = deviceId;
    }
    _onChanged();
  }

  Future<void> start() async {
    if (_disposed) return;
    await _client.start();
  }

  void requestReconnectNow() {
    _client.requestReconnectNow();
  }

  Future<void> refreshSessions() async {
    if (_disposed || _client.state.value != BackendConnectionState.connected) {
      return;
    }
    try {
      final res =
          await _client.call('terminal.list', const {}) as Map<String, dynamic>;
      final sessions = ((res['sessions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(TerminalSession.fromJson)
          .toList();
      _terminals.setSessions(sessions);
      for (final session in sessions) {
        await _terminals.replayHistory(session.id);
      }
    } catch (e) {
      if (_client.state.value == BackendConnectionState.connected) {
        debugPrint('TerminalHub.refreshSessions(${_target.name}) failed: $e');
      }
    }
  }

  TerminalSession? sessionFor(String sessionId) =>
      _terminals.sessionFor(sessionId);

  void focusTerminal(String sessionId) => _terminals.focusTerminal(sessionId);

  int terminalGenerationFor(String sessionId) =>
      _terminals.terminalGenerationFor(sessionId);

  Terminal? terminalForIfKnown(String sessionId) =>
      _terminals.terminalForIfKnown(sessionId);

  TerminalPreview previewFor(String sessionId) =>
      _terminals.previewFor(sessionId);

  Future<TerminalSession?> createTerminal({
    String? workspaceId,
    required int cols,
    required int rows,
  }) => _terminals.createTerminal(
    workspaceId: workspaceId,
    cols: cols,
    rows: rows,
  );

  Future<List<BackendWorkspaceChoice>> listWorkspaceChoices() async {
    if (_client.state.value != BackendConnectionState.connected) {
      return const [];
    }
    final res =
        await _client.call('workspace.list', const {}) as Map<String, dynamic>;
    final active = ((res['active'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Workspace.fromJson)
        .toList();
    final recents = ((res['recents'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final roots = <String>{};
    final choices = <BackendWorkspaceChoice>[];
    for (final workspace in active) {
      if (!roots.add(workspace.root)) continue;
      choices.add(
        BackendWorkspaceChoice(
          root: workspace.root,
          label: workspace.label,
          isOpen: true,
        ),
      );
    }
    for (final root in recents) {
      if (!roots.add(root)) continue;
      choices.add(
        BackendWorkspaceChoice(
          root: root,
          label: _basename(root),
          isOpen: false,
        ),
      );
    }
    return choices;
  }

  Future<List<DirEntry>> listPickerDir(String path) async {
    if (_client.state.value != BackendConnectionState.connected) {
      throw StateError('Backend is not connected.');
    }
    final res =
        await _client.call('fs.listDir', {'path': path, 'picker': true})
            as Map<String, dynamic>;
    final raw = (res['entries'] as List?) ?? const [];
    return raw
        .cast<Map<String, dynamic>>()
        .map(DirEntry.fromJson)
        .toList(growable: false);
  }

  Future<void> forgetRecentWorkspace(String root) async {
    try {
      await _client.call('workspace.forgetRecent', {'root': root});
      _onChanged();
    } catch (e) {
      _reportError('Could not remove recent workspace: $e');
    }
  }

  Future<void> clearRecentWorkspaces() async {
    try {
      await _client.call('workspace.clearRecents', const {});
      _onChanged();
    } catch (e) {
      _reportError('Could not clear recent workspaces: $e');
    }
  }

  Future<TerminalSession?> createTerminalForWorkspaceRoot({
    String? workspaceRoot,
    required int cols,
    required int rows,
  }) async {
    String? workspaceId;
    if (workspaceRoot != null && workspaceRoot.isNotEmpty) {
      try {
        final res =
            await _client.call('workspace.open', {
                  'root': workspaceRoot,
                  'reuseExisting': true,
                })
                as Map<String, dynamic>;
        final workspace = Workspace.fromJson(
          res['workspace'] as Map<String, dynamic>,
        );
        workspaceId = workspace.id;
      } catch (e) {
        _reportError('Could not open workspace: $e');
        return null;
      }
    }
    return createTerminal(workspaceId: workspaceId, cols: cols, rows: rows);
  }

  Future<void> disposeTerminal(String sessionId) => _terminals.disposeTerminal(
    sessionId,
    connectionState: _client.state.value,
  );

  Future<void> detachTerminal(String sessionId) => _terminals.detachTerminal(
    sessionId,
    connectionState: _client.state.value,
  );

  Future<void> renameTerminal(String sessionId, String? title) =>
      _terminals.renameTerminal(sessionId, title);

  Future<List<ExternalTerminalSession>> listExternalSessions() =>
      _terminals.listExternalSessions();

  Future<TerminalSession?> adoptExternalSession({
    String? workspaceId,
    required String sessionName,
    required int cols,
    required int rows,
  }) => _terminals.adoptExternalSession(
    workspaceId: workspaceId,
    sessionName: sessionName,
    cols: cols,
    rows: rows,
  );

  void _configureClient() {
    _client.configure(
      host: _target.host,
      port: _target.port,
      token: _target.token,
      transport: _target.transport,
      irohTicket: _target.irohTicket,
      irohAlpn: _target.irohAlpn,
      deviceId: _deviceId,
    );
  }

  void _onConnectionState() {
    if (_client.state.value == BackendConnectionState.connected) {
      unawaited(refreshSessions());
    }
    _onChanged();
  }

  void _onNotification(BackendNotification n) {
    final params = n.params;
    if (params is! Map<String, dynamic>) return;
    switch (n.method) {
      case BackendNotifications.terminalData:
        _terminals.onTerminalData(params);
        break;
      case BackendNotifications.terminalExit:
        _terminals.onTerminalExit(params);
        break;
      case BackendNotifications.terminalDetached:
        _terminals.onTerminalDetached(params);
        break;
      case BackendNotifications.terminalRenamed:
        _terminals.onTerminalRenamed(params);
        break;
      default:
        break;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _notifSub?.cancel();
    _notifSub = null;
    _terminals.removeListener(_onChanged);
    _terminals.previewVersion.removeListener(_onPreviewChanged);
    _client.state.removeListener(_onConnectionState);
    _client.lastError.removeListener(_onChanged);
    _terminals.dispose();
    await _client.dispose();
  }
}

String _basename(String path) {
  if (path.isEmpty) return path;
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  if (slash < 0) return trimmed;
  if (slash == trimmed.length - 1) return trimmed;
  return trimmed.substring(slash + 1);
}
