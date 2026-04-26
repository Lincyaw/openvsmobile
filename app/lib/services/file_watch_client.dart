import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Lightweight WebSocket client for `/ws/files` that watches the current
/// workspace and invokes [onRefresh] when the server reports a change.
///
/// The client keeps at most one connection open; calling [connect] with a
/// different `path` tears down the previous socket and reconnects to the
/// updated workspace.
class FileWatchClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  String? _lastPath;
  Timer? _debounceTimer;

  void connect(
    String baseUrl,
    String token,
    String path,
    VoidCallback onRefresh,
  ) {
    if (_lastPath == path && _channel != null) return;
    _lastPath = path;

    _subscription?.cancel();
    _channel?.sink.close();

    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/ws/files?token=$token');

    try {
      _channel = WebSocketChannel.connect(uri);
      _subscription = _channel!.stream.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final type = msg['type'] as String?;
          if (type == 'file_changed') {
            _debounceTimer?.cancel();
            _debounceTimer = Timer(const Duration(milliseconds: 500), () {
              onRefresh();
            });
          }
        },
        onError: (_) {},
        onDone: () {},
      );
      _channel!.sink.add(jsonEncode({'type': 'watch', 'path': path}));
    } catch (_) {}
  }

  void dispose() {
    _debounceTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
