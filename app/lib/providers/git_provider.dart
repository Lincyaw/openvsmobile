import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/git_models.dart';
import '../services/git_api_client.dart';

enum GitOperationType { refresh, stage, unstage, discard, commit, fetch, pull, push }

enum GitFeedbackKind { success, error }

class GitOperationFeedback {
  final GitFeedbackKind kind;
  final String message;
  final GitOperationType operation;
  final int nonce;

  const GitOperationFeedback({
    required this.kind,
    required this.message,
    required this.operation,
    required this.nonce,
  });
}

class GitProvider extends ChangeNotifier {
  final GitApiClient apiClient;

  GitRepositoryState? _repository;
  bool _isLoading = false;
  String? _error;
  String _workDir = '/';
  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSubscription;
  final Set<GitOperationType> _runningOperations = <GitOperationType>{};
  GitOperationFeedback? _feedback;
  int _feedbackNonce = 0;

  GitProvider({required this.apiClient});

  GitRepositoryState? get repository => _repository;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get workDir => _workDir;
  GitOperationFeedback? get feedback => _feedback;

  bool isRunning(GitOperationType operation) => _runningOperations.contains(operation);
  bool get hasActiveOperation => _runningOperations.isNotEmpty;

  String? get activeOperationLabel {
    if (isRunning(GitOperationType.commit)) {
      return 'Committing changes...';
    }
    if (isRunning(GitOperationType.pull)) {
      return 'Pulling from remote...';
    }
    if (isRunning(GitOperationType.push)) {
      return 'Pushing to remote...';
    }
    if (isRunning(GitOperationType.fetch)) {
      return 'Fetching latest refs...';
    }
    if (isRunning(GitOperationType.stage)) {
      return 'Staging changes...';
    }
    if (isRunning(GitOperationType.unstage)) {
      return 'Removing staged changes...';
    }
    if (isRunning(GitOperationType.discard)) {
      return 'Discarding local changes...';
    }
    if (isRunning(GitOperationType.refresh)) {
      return 'Refreshing repository state...';
    }
    return null;
  }

  void setWorkDir(String dir) {
    if (_workDir == dir) {
      return;
    }
    _workDir = dir;
    _repository = GitRepositoryState.empty(dir);
    _error = null;
    _feedback = null;
    _runningOperations.clear();
    _connectEvents();
    notifyListeners();
  }

  Future<void> refreshRepository() async {
    await _runOperation(
      GitOperationType.refresh,
      () async => _repository = await apiClient.getRepository(_workDir),
      successMessage: 'Repository refreshed',
      emitSuccessFeedback: false,
    );
  }

  Future<void> stageFile(String file) => _runRepositoryAction(
        GitOperationType.stage,
        () => apiClient.stageFile(_workDir, file),
        successMessage: 'Staged $file',
      );

  Future<void> unstageFile(String file) => _runRepositoryAction(
        GitOperationType.unstage,
        () => apiClient.unstageFile(_workDir, file),
        successMessage: 'Unstaged $file',
      );

  Future<void> discardFile(String file) => _runRepositoryAction(
        GitOperationType.discard,
        () => apiClient.discardFile(_workDir, file),
        successMessage: 'Discarded local changes for $file',
      );

  Future<void> commit(String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      _error = 'Commit message cannot be empty';
      _setFeedback(
        GitOperationFeedback(
          kind: GitFeedbackKind.error,
          message: _error!,
          operation: GitOperationType.commit,
          nonce: ++_feedbackNonce,
        ),
      );
      return;
    }

    await _runRepositoryAction(
      GitOperationType.commit,
      () => apiClient.commit(_workDir, trimmed),
      successMessage: 'Commit created',
    );
  }

  Future<void> fetch() => _runRepositoryAction(
        GitOperationType.fetch,
        () => apiClient.fetch(_workDir),
        successMessage: 'Fetch completed',
      );

  Future<void> pull() => _runRepositoryAction(
        GitOperationType.pull,
        () => apiClient.pull(_workDir),
        successMessage: 'Pull completed',
      );

  Future<void> push() => _runRepositoryAction(
        GitOperationType.push,
        () => apiClient.push(_workDir),
        successMessage: 'Push completed',
      );

  Future<GitDiffDocument> fetchDiff(String file, {bool staged = false}) {
    return apiClient.getDiff(_workDir, file, staged: staged);
  }

  Future<void> _runRepositoryAction(
    GitOperationType operation,
    Future<GitRepositoryState> Function() action, {
    required String successMessage,
  }) {
    return _runOperation(
      operation,
      () async => _repository = await action(),
      successMessage: successMessage,
    );
  }

  Future<void> _runOperation(
    GitOperationType operation,
    Future<void> Function() action, {
    required String successMessage,
    bool emitSuccessFeedback = true,
  }) async {
    _runningOperations.add(operation);
    if (operation == GitOperationType.refresh) {
      _setLoading(true);
    } else {
      _error = null;
      notifyListeners();
    }

    try {
      await action();
      _error = null;
      _connectEvents();
      if (emitSuccessFeedback) {
        _setFeedback(
          GitOperationFeedback(
            kind: GitFeedbackKind.success,
            message: successMessage,
            operation: operation,
            nonce: ++_feedbackNonce,
          ),
        );
      }
    } catch (e) {
      _error = e.toString();
      _setFeedback(
        GitOperationFeedback(
          kind: GitFeedbackKind.error,
          message: _error!,
          operation: operation,
          nonce: ++_feedbackNonce,
        ),
      );
    } finally {
      _runningOperations.remove(operation);
      if (operation == GitOperationType.refresh) {
        _setLoading(false);
      } else {
        notifyListeners();
      }
    }
  }

  void clearFeedback() {
    if (_feedback == null) {
      return;
    }
    _feedback = null;
    notifyListeners();
  }

  void _setFeedback(GitOperationFeedback feedback) {
    _feedback = feedback;
    notifyListeners();
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
      _applyRepositoryEvent(decoded);
    } catch (_) {
      // Ignore malformed bridge events; the next refresh or event will recover.
    }
  }

  Future<void> applyBridgeEvent(Map<String, dynamic> event) async {
    final hadRepository = _applyRepositoryEvent(event);
    if (event['type'] != 'bridge/git/repositoryChanged') {
      return;
    }
    final payload = event['payload'];
    if (payload is! Map) {
      return;
    }
    if (hadRepository) {
      return;
    }
    final changedPath =
        (payload['path'] as String?) ??
        (payload['repository'] is Map
            ? (payload['repository'] as Map)['path'] as String?
            : null);
    if (changedPath == _workDir) {
      await refreshRepository();
    }
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _eventsChannel?.sink.close();
    super.dispose();
  }

  bool _applyRepositoryEvent(Map<String, dynamic> decoded) {
    final event = BridgeEventEnvelope.fromJson(decoded);
    if (event.type != 'bridge/git/repositoryChanged') {
      return false;
    }
    if (event.payload is! Map) {
      return false;
    }

    final payload = Map<String, dynamic>.from(event.payload as Map);
    final repositoryPayload = payload['repository'];
    final source = repositoryPayload is Map
        ? Map<String, dynamic>.from(repositoryPayload)
        : payload;
    if (!source.containsKey('path') && payload['path'] is String) {
      source['path'] = payload['path'];
    }
    if (!source.containsKey('branch') &&
        !source.containsKey('staged') &&
        !source.containsKey('unstaged') &&
        !source.containsKey('untracked') &&
        !source.containsKey('conflicts') &&
        !source.containsKey('mergeChanges')) {
      return false;
    }

    final repository = GitRepositoryState.fromJson(source);
    if (repository.path != _workDir) {
      return false;
    }
    _repository = repository;
    _error = null;
    notifyListeners();
    return true;
  }
}
