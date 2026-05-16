// WebSocket JSON-RPC client. Single persistent connection.
//
// Public surface:
//   - connect()/disconnect() lifecycle
//   - call(method, params) → Future<dynamic>
//   - notifications: a broadcast Stream<({String method, dynamic params})>
//   - state: a ChangeNotifier-friendly enum + ValueNotifier
//
// Correlation is by JSON-RPC id (monotonic int per connection).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

enum BackendConnectionState {
  disconnected,
  connecting,
  handshaking,
  connected,
  failed,
}

class BackendNotification {
  final String method;
  final dynamic params;
  const BackendNotification(this.method, this.params);
}

class BackendRpcException implements Exception {
  final int code;
  final String message;
  final dynamic data;
  BackendRpcException(this.code, this.message, [this.data]);
  @override
  String toString() => 'BackendRpcException($code): $message';
}

class BackendClient {
  final ValueNotifier<BackendConnectionState> state =
      ValueNotifier(BackendConnectionState.disconnected);

  /// Last failure message; cleared on successful reconnect.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final StreamController<BackendNotification> _notifs =
      StreamController.broadcast();

  Stream<BackendNotification> get notifications => _notifs.stream;

  bool get isConnected => state.value == BackendConnectionState.connected;

  Future<void> connect({
    required String host,
    required int port,
    required String token,
  }) async {
    await disconnect();
    state.value = BackendConnectionState.connecting;
    lastError.value = null;

    final uri = Uri.parse('ws://$host:$port/rpc');
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(uri);
      // Wait for the channel to actually open (or fail).
      await ch.ready;
    } catch (e) {
      state.value = BackendConnectionState.failed;
      lastError.value = 'connect failed: $e';
      return;
    }

    _channel = ch;
    _sub = ch.stream.listen(
      _onMessage,
      onError: (Object e) {
        lastError.value = 'socket error: $e';
        _teardown(BackendConnectionState.failed);
      },
      onDone: () {
        // If we tore down deliberately, state is already disconnected.
        if (state.value == BackendConnectionState.connecting ||
            state.value == BackendConnectionState.handshaking ||
            state.value == BackendConnectionState.connected) {
          lastError.value ??= 'connection closed';
          _teardown(BackendConnectionState.disconnected);
        }
      },
    );

    state.value = BackendConnectionState.handshaking;
    try {
      await call('auth.handshake', {
        'token': token,
        'protocolVersion': '1.0',
        'client': {'name': 'openvsmobile-flutter', 'version': '0.1.0'},
      });
    } catch (e) {
      lastError.value = 'handshake failed: $e';
      await disconnect();
      state.value = BackendConnectionState.failed;
      return;
    }
    state.value = BackendConnectionState.connected;
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {
      // Ignore — we're tearing down anyway.
    }
    _channel = null;
    _failPending('disconnected');
    if (state.value != BackendConnectionState.failed) {
      state.value = BackendConnectionState.disconnected;
    }
  }

  void _teardown(BackendConnectionState newState) {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _failPending('connection closed');
    state.value = newState;
  }

  void _failPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(BackendRpcException(-1, reason));
      }
    }
    _pending.clear();
  }

  Future<dynamic> call(String method, [Map<String, dynamic>? params]) {
    final ch = _channel;
    if (ch == null) {
      return Future.error(BackendRpcException(-1, 'not connected'));
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final frame = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
    };
    if (params != null) frame['params'] = params;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (e) {
      _pending.remove(id);
      return Future.error(BackendRpcException(-1, 'send failed: $e'));
    }
    return completer.future;
  }

  void _onMessage(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id != null) {
      final completer = _pending.remove(id is int ? id : (id as num).toInt());
      if (completer == null) return;
      if (decoded.containsKey('error')) {
        final err = decoded['error'] as Map<String, dynamic>;
        completer.completeError(BackendRpcException(
          (err['code'] as num).toInt(),
          err['message'] as String? ?? 'error',
          err['data'],
        ));
      } else {
        completer.complete(decoded['result']);
      }
      return;
    }
    final method = decoded['method'];
    if (method is String) {
      _notifs.add(BackendNotification(method, decoded['params']));
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _notifs.close();
    state.dispose();
    lastError.dispose();
  }
}
