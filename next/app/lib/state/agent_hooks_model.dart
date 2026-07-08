// Agent completion hook installer state. The backend owns the actual
// Claude/Codex config scan; the app only exposes the authenticated admin RPC.

import 'package:flutter/foundation.dart';

import '../backend_client.dart';
import '../models.dart';

class AgentHooksModel extends ChangeNotifier {
  final BackendClient _client;
  final void Function(String message) _reportError;

  bool _checking = false;
  bool _installing = false;
  AgentHookInstallResult? _lastResult;
  String? _error;
  bool _statusUnsupported = false;

  AgentHooksModel({
    required BackendClient client,
    required void Function(String message) reportError,
  }) : this._(client, reportError);

  AgentHooksModel._(this._client, this._reportError);

  bool get checking => _checking;
  bool get installing => _installing;
  AgentHookInstallResult? get lastResult => _lastResult;
  String? get error => _error;
  bool get statusUnsupported => _statusUnsupported;

  Future<AgentHookInstallResult?> refreshStatus() async {
    if (_checking || _installing || _statusUnsupported) return _lastResult;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final result =
          await _client.call('notification.agentHookStatus')
              as Map<String, dynamic>;
      final parsed = AgentHookInstallResult.fromJson(result);
      _lastResult = parsed;
      _checking = false;
      _statusUnsupported = false;
      notifyListeners();
      return parsed;
    } on BackendRpcException catch (e) {
      _checking = false;
      if (e.code == -32601) {
        _statusUnsupported = true;
        notifyListeners();
        return _lastResult;
      }
      _error = e.toString();
      notifyListeners();
      _reportError('Could not load agent hook status: $e');
      rethrow;
    } catch (e) {
      _error = e.toString();
      _checking = false;
      notifyListeners();
      _reportError('Could not load agent hook status: $e');
      rethrow;
    }
  }

  Future<AgentHookInstallResult> install() async {
    if (_installing) {
      final current = _lastResult;
      if (current != null) return current;
    }
    _installing = true;
    _error = null;
    notifyListeners();
    try {
      final result =
          await _client.call('notification.installAgentHooks')
              as Map<String, dynamic>;
      final parsed = AgentHookInstallResult.fromJson(result);
      _lastResult = parsed;
      _installing = false;
      _statusUnsupported = false;
      notifyListeners();
      return parsed;
    } on BackendRpcException catch (e) {
      _installing = false;
      if (e.code == -32601) {
        _statusUnsupported = true;
        _error = null;
        notifyListeners();
        rethrow;
      }
      _error = e.toString();
      notifyListeners();
      _reportError('Could not install agent hooks: $e');
      rethrow;
    } catch (e) {
      _error = e.toString();
      _installing = false;
      notifyListeners();
      _reportError('Could not install agent hooks: $e');
      rethrow;
    }
  }

  void resetLocal() {
    _checking = false;
    _installing = false;
    _lastResult = null;
    _error = null;
    _statusUnsupported = false;
    notifyListeners();
  }
}
