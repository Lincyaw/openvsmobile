import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../widgets/ansi_text.dart';
import '../widgets/app_bar_menu.dart';
import '../providers/workspace_provider.dart';
import 'package:provider/provider.dart';

/// Terminal screen that connects to the Go server's /ws/terminal
/// WebSocket endpoint. Sends/receives base64-encoded PTY I/O.
class TerminalScreen extends StatefulWidget {
  final String baseUrl;
  final String token;
  final String workDir;

  /// When false, defers WebSocket connection until the tab becomes active.
  final bool isActive;

  const TerminalScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    this.workDir = '/',
    this.isActive = true,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const double _fontSize = 13;
  static const double _lineHeight = 1.4;
  static const double _termPadding = 8;
  static const int _maxLines = 2000;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final _outputController = ScrollController();
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  // Line-based buffer for terminal output.
  final List<String> _lines = [''];
  final _currentLine = StringBuffer();
  String? _cachedOutput;
  String _terminalId = '';
  bool _connected = false;
  bool _hasConnected = false;
  String? _error;
  int _cols = 80;
  int _rows = 24;
  double? _charWidth;

  @override
  void initState() {
    super.initState();
    // Defer connection until first build to avoid connecting when tab is hidden.
  }

  @override
  void didUpdateWidget(TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.workDir != oldWidget.workDir && _hasConnected) {
      // Workspace changed — reconnect terminal in new directory.
      _reconnect();
    }
    if (widget.isActive && !oldWidget.isActive && !_hasConnected) {
      _ensureConnected();
    }
  }

  @override
  void dispose() {
    _disconnect();
    _outputController.dispose();
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Clean up the current WebSocket connection and subscription.
  void _disconnect() {
    _sendClose();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _ensureConnected() {
    if (_hasConnected) return;
    _hasConnected = true;
    _connect();
  }

  double _getCharWidth() {
    if (_charWidth != null) return _charWidth!;
    final paragraph = ui.ParagraphBuilder(
      ui.ParagraphStyle(fontFamily: 'monospace', fontSize: _fontSize),
    )..addText('M');
    final p = paragraph.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    _charWidth = p.maxIntrinsicWidth;
    return _charWidth!;
  }

  (int, int) _calcTermSize(double width, double height) {
    final cw = _getCharWidth();
    final lineHeightPx = _fontSize * _lineHeight;
    final cols = ((width - _termPadding * 2) / cw).floor().clamp(20, 300);
    final rows = ((height) / lineHeightPx).floor().clamp(5, 100);
    return (cols, rows);
  }

  void _sendResize(int cols, int rows) {
    if (!_connected || _channel == null || _terminalId.isEmpty) return;
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    _channel!.sink.add(
      jsonEncode({
        'type': 'resize',
        'id': _terminalId,
        'rows': rows,
        'cols': cols,
      }),
    );
  }

  void _connect() {
    _disconnect(); // Clean up any existing connection before creating a new one.
    final wsBase = widget.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/ws/terminal?token=${widget.token}');

    _channel = WebSocketChannel.connect(uri);
    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: (e) => setState(() => _error = e.toString()),
      onDone: () => setState(() => _connected = false),
    );

    _terminalId = 'term-${DateTime.now().millisecondsSinceEpoch}';
    _channel!.sink.add(
      jsonEncode({
        'type': 'create',
        'id': _terminalId,
        'shell': '',
        'workDir': widget.workDir,
        'rows': _rows,
        'cols': _cols,
      }),
    );
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
          setState(() {
            _appendOutput(text);
            _cachedOutput = null;
          });
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

  /// Append PTY output, handling CR/LF properly.
  /// Uses StringBuffer for the current line to avoid O(n^2) string concat.
  void _appendOutput(String text) {
    for (int i = 0; i < text.length; i++) {
      final ch = text.codeUnitAt(i);

      if (ch == 0x0A) {
        // LF: commit current line and start a new one.
        _lines[_lines.length - 1] = _currentLine.toString();
        _lines.add('');
        _currentLine.clear();
      } else if (ch == 0x0D) {
        // CR: if followed by LF, skip (CRLF handled as single newline).
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
          continue;
        }
        // Standalone CR: overwrite current line content.
        _currentLine.clear();
      } else {
        _currentLine.writeCharCode(ch);
      }
    }
    _lines[_lines.length - 1] = _currentLine.toString();

    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  String get _outputText {
    _cachedOutput ??= _lines.join('\n');
    return _cachedOutput!;
  }

  void _sendInput(String text) {
    if (!_connected || _channel == null) return;
    final encoded = base64Encode(utf8.encode(text));
    _channel!.sink.add(
      jsonEncode({'type': 'input', 'id': _terminalId, 'data': encoded}),
    );
  }

  void _sendClose() {
    if (_channel == null || _terminalId.isEmpty) return;
    _channel!.sink.add(jsonEncode({'type': 'close', 'id': _terminalId}));
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

  void _reconnect() {
    _disconnect();
    setState(() {
      _lines.clear();
      _lines.add('');
      _currentLine.clear();
      _cachedOutput = null;
      _connected = false;
      _error = null;
    });
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isActive) _ensureConnected();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final wsName = context.select<WorkspaceProvider, String>(
      (ws) => ws.displayName,
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Terminal'),
            Text(
              wsName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          if (_connected)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reconnect',
              onPressed: _reconnect,
            ),
          const AppBarMenu(),
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final (cols, rows) = _calcTermSize(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _sendResize(cols, rows);
                });

                final fgColor = isDark
                    ? const Color(0xFFD4D4D4)
                    : const Color(0xFF1E1E1E);

                return Container(
                  color: isDark
                      ? const Color(0xFF1E1E1E)
                      : const Color(0xFFF5F5F5),
                  width: double.infinity,
                  padding: const EdgeInsets.all(_termPadding),
                  child: SingleChildScrollView(
                    controller: _outputController,
                    child: AnsiText(
                      _outputText,
                      fontSize: _fontSize,
                      lineHeight: _lineHeight,
                      defaultForeground: fgColor,
                    ),
                  ),
                );
              },
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
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
