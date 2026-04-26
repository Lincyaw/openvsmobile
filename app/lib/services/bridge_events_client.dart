import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One event delivered over the `/bridge/ws/events` WebSocket.
///
/// The server envelope is `{type, payload, ts}`; we expose those three fields
/// directly. `payload` is whatever the originating extension event provided
/// (e.g. `{rootPath: ...}` for `git.repositoryChanged`).
class BridgeEvent {
  final String type;
  final dynamic payload;
  final String? ts;

  const BridgeEvent({required this.type, this.payload, this.ts});

  factory BridgeEvent.fromJson(Map<String, dynamic> json) {
    return BridgeEvent(
      type: json['type'] as String? ?? '',
      payload: json['payload'],
      ts: json['ts'] as String?,
    );
  }
}

typedef BridgeEventHandler = void Function(BridgeEvent event);

/// Long-lived WebSocket client for the bridge events fan-out.
///
/// Connects on [connect], reconnects on disconnect with exponential backoff
/// (1s..30s), and dispatches incoming events to handlers registered via
/// [on]. The MainShell owns one of these and routes events into providers.
class BridgeEventsClient {
  static const _initialBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);

  final Map<String, List<BridgeEventHandler>> _handlers = {};
  final List<BridgeEventHandler> _wildcardHandlers = [];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  String? _baseUrl;
  String? _token;
  Duration _backoff = _initialBackoff;
  bool _connected = false;
  bool _disposed = false;

  /// Opens (or refreshes) the connection to `<baseUrl>/bridge/ws/events`.
  ///
  /// Calling [connect] again with the same arguments is a no-op once already
  /// connected. Calling it with different arguments tears down the previous
  /// socket and reconnects.
  void connect(String baseUrl, String token) {
    if (_disposed) return;
    if (_baseUrl == baseUrl && _token == token && _channel != null) {
      return;
    }
    _baseUrl = baseUrl;
    _token = token;
    _backoff = _initialBackoff;
    _openSocket();
  }

  /// Registers a handler for events whose `type` matches [eventType].
  /// Pass `'*'` to receive every event.
  ///
  /// Returns a function that removes the handler when invoked.
  VoidCallback on(String eventType, BridgeEventHandler handler) {
    if (eventType == '*') {
      _wildcardHandlers.add(handler);
      return () => _wildcardHandlers.remove(handler);
    }
    _handlers.putIfAbsent(eventType, () => []).add(handler);
    return () {
      final list = _handlers[eventType];
      if (list == null) return;
      list.remove(handler);
      if (list.isEmpty) _handlers.remove(eventType);
    };
  }

  bool get isConnected => _connected;

  void _openSocket() {
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) return;

    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;

    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/bridge/ws/events?token=$token');

    try {
      _channel = WebSocketChannel.connect(uri);
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      final event = BridgeEvent.fromJson(decoded);
      if (event.type == 'ready') {
        // Successful round-trip: reset backoff so the next disconnect
        // retries quickly rather than after the previous (longer) wait.
        _connected = true;
        _backoff = _initialBackoff;
        return;
      }
      if (event.type == 'closed') {
        _scheduleReconnect();
        return;
      }
      _dispatch(event);
    } catch (_) {
      // Ignore malformed frames; the next valid frame or reconnect resyncs.
    }
  }

  void _dispatch(BridgeEvent event) {
    final exact = _handlers[event.type];
    if (exact != null) {
      // Iterate over a copy in case a handler removes itself.
      for (final h in List<BridgeEventHandler>.from(exact)) {
        try {
          h(event);
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('BridgeEventsClient handler ${event.type} failed: $e\n$st');
          }
        }
      }
    }
    if (_wildcardHandlers.isNotEmpty) {
      for (final h in List<BridgeEventHandler>.from(_wildcardHandlers)) {
        try {
          h(event);
        } catch (_) {}
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectTimer != null) return;
    _connected = false;
    final wait = _backoff;
    _reconnectTimer = Timer(wait, () {
      _reconnectTimer = null;
      _openSocket();
    });
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
    // Cap the local random so we don't accidentally jitter past max.
    final jitter = math.Random().nextInt(250);
    _backoff = Duration(milliseconds: _backoff.inMilliseconds + jitter);
    if (_backoff > _maxBackoff) _backoff = _maxBackoff;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _handlers.clear();
    _wildcardHandlers.clear();
  }
}
