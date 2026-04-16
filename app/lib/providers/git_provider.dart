import 'package:flutter/foundation.dart';
import '../models/git_models.dart';
import '../services/git_api_client.dart';

class GitProvider extends ChangeNotifier {
  final GitApiClient apiClient;

  List<GitStatusEntry> _statusEntries = [];
  List<GitLogEntry> _logEntries = [];
  GitBranchInfo? _branchInfo;
  String? _currentDiff;
  bool _isLoading = false;
  String? _error;
  String _workDir = '/';

  GitProvider({required this.apiClient});

  List<GitStatusEntry> get statusEntries => _statusEntries;
  List<GitLogEntry> get logEntries => _logEntries;
  GitBranchInfo? get branchInfo => _branchInfo;
  String? get currentDiff => _currentDiff;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get workDir => _workDir;

  void setWorkDir(String dir) {
    if (_workDir == dir) return;
    _workDir = dir;
    // Clear stale data from previous workspace so UI never shows mixed results.
    _statusEntries = [];
    _logEntries = [];
    _branchInfo = null;
    _currentDiff = null;
    _error = null;
    // Do not notifyListeners here — callers typically follow with refreshAll(),
    // which notifies on its own lifecycle. Avoids build-phase violations.
  }

  /// Load git status for the current work directory.
  Future<void> loadStatus() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _statusEntries = await apiClient.getStatus(_workDir);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load git log for the current work directory.
  Future<void> loadLog({int count = 20}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _logEntries = await apiClient.getLog(_workDir, count: count);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load branch info for the current work directory.
  Future<void> loadBranches() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _branchInfo = await apiClient.getBranches(_workDir);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load diff for the current work directory, optionally for a specific file.
  Future<void> loadDiff({String? file, bool staged = false}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _currentDiff = await apiClient.getDiff(
        _workDir,
        file: file,
        staged: staged,
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Stage a file and refresh status.
  Future<void> stageFile(String file) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await apiClient.stageFile(_workDir, file);
      await refreshAll();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Unstage a file and refresh status.
  Future<void> unstageFile(String file) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await apiClient.unstageFile(_workDir, file);
      await refreshAll();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Commit staged changes with a message and refresh.
  Future<void> commit(String message) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await apiClient.commit(_workDir, message);
      await refreshAll();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Checkout a branch and refresh all git data.
  Future<void> checkoutBranch(String branch) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await apiClient.checkoutBranch(_workDir, branch);
      await refreshAll();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refresh all git data: status, branches, and log.
  Future<void> refreshAll() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final results = await Future.wait([
        apiClient.getStatus(_workDir),
        apiClient.getBranches(_workDir),
        apiClient.getLog(_workDir),
      ]);
      _statusEntries = results[0] as List<GitStatusEntry>;
      _branchInfo = results[1] as GitBranchInfo;
      _logEntries = results[2] as List<GitLogEntry>;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
