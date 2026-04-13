import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Strip ANSI escape sequences from raw PTY output.
String _stripAnsi(String text) {
  return text.replaceAll(
    RegExp(
        r'\x1B\[[0-9;]*[a-zA-Z]|\x1B\].*?\x07|\x1B[()][0-9A-B]|\x1B\[[\?]?[0-9;]*[hlm]'),
    '',
  );
}

/// Simple terminal screen that connects to the Go server's /ws/terminal
/// WebSocket endpoint. Sends/receives base64-encoded PTY I/O.
class TerminalScreen extends StatefulWidget {
  final String baseUrl;
  final String token;
  final String workDir;

  const TerminalScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    this.workDir = '/',
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final _outputController = ScrollController();
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();
  final _outputBuffer = StringBuffer();
  String _terminalId = '';
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _sendClose();
    _subscription?.cancel();
    _channel?.sink.close();
    _outputController.dispose();
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _connect() {
    final wsBase = widget.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base =
        wsBase.endsWith('/') ? wsBase.substring(0, wsBase.length - 1) : wsBase;
    final uri = Uri.parse('$base/ws/terminal?token=${widget.token}');

    _channel = WebSocketChannel.connect(uri);
    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: (e) => setState(() => _error = e.toString()),
      onDone: () => setState(() => _connected = false),
    );

    // Create a terminal session.
    _terminalId = 'term-${DateTime.now().millisecondsSinceEpoch}';
    _channel!.sink.add(jsonEncode({
      'type': 'create',
      'id': _terminalId,
      'shell': '',
      'workDir': widget.workDir,
      'rows': 24,
      'cols': 80,
    }));
  }

  void _onMessage(dynamic data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'created':
        setState(() => _connected = true);
        _focusNode.requestFocus();
        break;
      case 'output':
        final encoded = msg['data'] as String?;
        if (encoded != null) {
          final bytes = base64Decode(encoded);
          final text = utf8.decode(bytes, allowMalformed: true);
          setState(() => _outputBuffer.write(_stripAnsi(text)));
          _scrollToBottom();
        }
        break;
      case 'closed':
        setState(() => _connected = false);
        break;
      case 'error':
        setState(() => _error = msg['error'] as String?);
        break;
    }
  }

  void _sendInput(String text) {
    if (!_connected || _channel == null) return;
    final encoded = base64Encode(utf8.encode(text));
    _channel!.sink.add(jsonEncode({
      'type': 'input',
      'id': _terminalId,
      'data': encoded,
    }));
  }

  void _sendClose() {
    if (_channel == null || _terminalId.isEmpty) return;
    _channel!.sink.add(jsonEncode({
      'type': 'close',
      'id': _terminalId,
    }));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputController.hasClients) {
        _outputController.animateTo(
          _outputController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onSubmit(String text) {
    _sendInput('$text\n');
    _inputController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          if (_connected)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reconnect',
              onPressed: () {
                _sendClose();
                setState(() {
                  _outputBuffer.clear();
                  _connected = false;
                  _error = null;
                });
                _connect();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              backgroundColor: colorScheme.errorContainer,
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          if (!_connected && _error == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Connecting...'),
                ],
              ),
            ),
          Expanded(
            child: Container(
              color: isDark
                  ? const Color(0xFF1E1E1E)
                  : const Color(0xFFF5F5F5),
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                controller: _outputController,
                child: SelectableText(
                  _outputBuffer.toString(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.4,
                    color: isDark
                        ? const Color(0xFFD4D4D4)
                        : const Color(0xFF1E1E1E),
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.only(
              left: 8,
              right: 8,
              top: 4,
              bottom: MediaQuery.of(context).padding.bottom + 4,
            ),
            color: isDark
                ? const Color(0xFF252526)
                : colorScheme.surfaceContainerHigh,
            child: Row(
              children: [
                Text(
                  '\$ ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: colorScheme.primary,
                    fontSize: 14,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: isDark
                          ? const Color(0xFFD4D4D4)
                          : colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Enter command...',
                      hintStyle: TextStyle(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onSubmitted: _onSubmit,
                    textInputAction: TextInputAction.send,
                    enabled: _connected,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.send,
                    size: 20,
                    color: _connected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  ),
                  onPressed: _connected
                      ? () => _onSubmit(_inputController.text)
                      : null,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
