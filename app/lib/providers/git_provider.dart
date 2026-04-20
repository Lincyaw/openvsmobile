import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/git_models.dart';
import '../services/git_api_client.dart';

class GitProvider extends ChangeNotifier {
  final GitApiClient apiClient;

  GitRepositoryState? _repository;
  bool _isLoading = false;
  String? _error;
  String _workDir = '/';
  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSubscription;

  GitProvider({required this.apiClient});

  GitRepositoryState? get repository => _repository;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get workDir => _workDir;

  void setWorkDir(String dir) {
    if (_workDir == dir) {
      return;
    }
    _workDir = dir;
    _repository = GitRepositoryState.empty(dir);
    _error = null;
    _connectEvents();
    notifyListeners();
  }

  Future<void> refreshRepository() async {
    _setLoading(true);
    try {
      _repository = await apiClient.getRepository(_workDir);
      _error = null;
      _connectEvents();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> stageFile(String file) => _runAction(() {
        return apiClient.stageFile(_workDir, file);
      });

  Future<void> unstageFile(String file) => _runAction(() {
        return apiClient.unstageFile(_workDir, file);
      });

  Future<void> discardFile(String file) => _runAction(() {
        return apiClient.discardFile(_workDir, file);
      });

  Future<void> commit(String message) => _runAction(() {
        return apiClient.commit(_workDir, message);
      });

  Future<void> fetch() => _runAction(() => apiClient.fetch(_workDir));
  Future<void> pull() => _runAction(() => apiClient.pull(_workDir));
  Future<void> push() => _runAction(() => apiClient.push(_workDir));

  Future<void> _runAction(Future<GitRepositoryState> Function() action) async {
    _setLoading(true);
    try {
      _repository = await action();
      _error = null;
      _connectEvents();
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    if (value) {
      _error = null;
    }
    notifyListeners();
  }

  void _connectEvents() {
    if (_workDir.isEmpty) {
      return;
    }

    _eventsSubscription?.cancel();
    _eventsChannel?.sink.close();

    _eventsChannel = apiClient.connectEventsWebSocket();
    _eventsSubscription = _eventsChannel!.stream.listen(
      _onEvent,
      onError: (_) {},
      onDone: () {},
    );
  }

  void _onEvent(dynamic raw) {
    if (raw is! String) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final event = BridgeEventEnvelope.fromJson(decoded);
      if (event.type != 'bridge/git/repositoryChanged') {
        return;
      }
      if (event.payload is! Map) {
        return;
      }
      final repository = GitRepositoryState.fromJson(
        Map<String, dynamic>.from(event.payload as Map),
      );
      if (repository.path != _workDir) {
        return;
      }
      _repository = repository;
      _error = null;
      notifyListeners();
    } catch (_) {
      // Ignore malformed bridge events; the next refresh or event will recover.
    }
  }

  Future<void> applyBridgeEvent(Map<String, dynamic> event) async {
    _onEvent(jsonEncode(event));
    if (event['type'] != 'bridge/git/repositoryChanged') {
      return;
    }
    final payload = event['payload'];
    if (payload is! Map) {
      return;
    }
    final changedPath = payload['path'];
    if (changedPath is String && changedPath == _workDir) {
      await refreshRepository();
    }
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _eventsChannel?.sink.close();
    super.dispose();
  }
}
