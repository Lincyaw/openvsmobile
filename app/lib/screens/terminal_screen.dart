import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../widgets/ansi_text.dart';
import '../widgets/app_bar_menu.dart';
import '../providers/workspace_provider.dart';
import 'package:provider/provider.dart';

/// Terminal screen that connects to the Go server's /bridge/ws/terminal/{id}
/// WebSocket endpoint. Creates a terminal session via REST API first,
/// then attaches via WebSocket for base64-encoded PTY I/O.
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
  final _httpClient = http.Client();

  bool _ctrlMode = false;

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
    _httpClient.close();
    super.dispose();
  }

  /// Clean up the current WebSocket connection and subscription.
  void _disconnect() {
    try {
      _sendClose();
    } catch (_) {}
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
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

  Future<void> _sendResize(int cols, int rows) async {
    if (_terminalId.isEmpty) return;
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    try {
      final base = widget.baseUrl.endsWith('/')
          ? widget.baseUrl.substring(0, widget.baseUrl.length - 1)
          : widget.baseUrl;
      await _httpClient.post(
        Uri.parse('$base/bridge/terminal/resize'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'id': _terminalId,
          'rows': rows,
          'cols': cols,
        }),
      );
    } catch (_) {}
  }

  Future<void> _createAndConnect() async {
    _disconnect();
    try {
      final base = widget.baseUrl.endsWith('/')
          ? widget.baseUrl.substring(0, widget.baseUrl.length - 1)
          : widget.baseUrl;

      // Create terminal session via REST API.
      final createResp = await _httpClient.post(
        Uri.parse('$base/bridge/terminal/create'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'cwd': widget.workDir,
          'profile': '',
          'rows': _rows,
          'cols': _cols,
        }),
      );

      if (createResp.statusCode < 200 || createResp.statusCode >= 300) {
        setState(() {
          _error = 'Failed to create terminal: ${createResp.statusCode}';
          _hasConnected = false;
        });
        return;
      }

      final decoded = jsonDecode(createResp.body) as Map<String, dynamic>;
      final session = decoded['session'] as Map<String, dynamic>? ?? decoded;
      _terminalId = session['id'] as String? ?? '';

      if (_terminalId.isEmpty) {
        setState(() {
          _error = 'No terminal ID returned';
          _hasConnected = false;
        });
        return;
      }

      // Connect to terminal WebSocket.
      final wsBase = widget.baseUrl
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
      final wsBaseTrimmed = wsBase.endsWith('/')
          ? wsBase.substring(0, wsBase.length - 1)
          : wsBase;
      final uri = Uri.parse('$wsBaseTrimmed/bridge/ws/terminal/$_terminalId?token=${widget.token}');

      _channel = WebSocketChannel.connect(uri);
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          setState(() {
            _error = e.toString();
            _connected = false;
            _hasConnected = false;
          });
        },
        onDone: () {
          setState(() {
            _connected = false;
            _hasConnected = false;
          });
        },
      );
    } catch (e) {
      setState(() {
        _error = e.toString();
        _hasConnected = false;
      });
    }
  }

  void _connect() {
    _createAndConnect();
  }

  void _onMessage(dynamic data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'ready':
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
      case 'exit':
        setState(() => _connected = false);
        break;
      case 'error':
        setState(() => _error = msg['error'] as String? ?? msg['message'] as String?);
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
      jsonEncode({'type': 'input', 'data': encoded}),
    );
  }

  Future<void> _sendClose() async {
    if (_terminalId.isEmpty) return;
    try {
      final base = widget.baseUrl.endsWith('/')
          ? widget.baseUrl.substring(0, widget.baseUrl.length - 1)
          : widget.baseUrl;
      await _httpClient.post(
        Uri.parse('$base/bridge/terminal/close'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'id': _terminalId}),
      );
    } catch (_) {}
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
    _focusNode.requestFocus();
  }

  /// Send raw control characters directly to the PTY (bypassing the input field).
  void _sendRaw(String chars) {
    if (!_connected || _channel == null) return;
    _sendInput(chars);
  }

  /// Insert text at the current cursor position in the input field.
  void _insertAtCursor(String text) {
    final value = _inputController.text;
    final selection = _inputController.selection;
    final start = selection.isValid ? selection.start : value.length;
    final end = selection.isValid ? selection.end : value.length;
    final newText = value.replaceRange(start, end, text);
    final newOffset = start + text.length;
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _focusNode.requestFocus();
  }

  /// Toggle Ctrl modifier mode for the next toolbar key press.
  void _toggleCtrlMode() {
    setState(() => _ctrlMode = !_ctrlMode);
    _focusNode.requestFocus();
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
          // Terminal key toolbar + input field.
          Container(
            color: isDark
                ? const Color(0xFF252526)
                : colorScheme.surfaceContainerHigh,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Function key toolbar (Termux-style).
                _TerminalKeyToolbar(
                  ctrlMode: _ctrlMode,
                  onToggleCtrl: _toggleCtrlMode,
                  onSendRaw: _sendRaw,
                  onInsert: _insertAtCursor,
                  enabled: _connected,
                ),
                // Input row.
                Padding(
                  padding: EdgeInsets.only(
                    left: 8,
                    right: 8,
                    top: 2,
                    bottom: MediaQuery.of(context).padding.bottom + 4,
                  ),
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
                              : colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.3),
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
          ),
        ],
      ),
    );
  }
}

/// Termux-style function key toolbar for mobile terminal input.
class _TerminalKeyToolbar extends StatelessWidget {
  final bool ctrlMode;
  final VoidCallback onToggleCtrl;
  final void Function(String) onSendRaw;
  final void Function(String) onInsert;
  final bool enabled;

  const _TerminalKeyToolbar({
    required this.ctrlMode,
    required this.onToggleCtrl,
    required this.onSendRaw,
    required this.onInsert,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget keyButton({
      required String label,
      required VoidCallback? onTap,
      bool active = false,
      double? width,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: active
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: width ?? 40,
              height: 32,
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? colorScheme.primary
                      : enabled
                          ? colorScheme.onSurface
                          : colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.4),
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget iconKeyButton({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
      bool active = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: active
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 36,
              height: 32,
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 16,
                color: active
                    ? colorScheme.primary
                    : enabled
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Ctrl toggle.
            keyButton(
              label: 'Ctrl',
              onTap: onToggleCtrl,
              active: ctrlMode,
              width: 42,
            ),
            // Esc.
            keyButton(
              label: 'Esc',
              onTap: () => onSendRaw('\x1B'),
              width: 40,
            ),
            // Tab.
            keyButton(
              label: 'Tab',
              onTap: () => onSendRaw('\t'),
              width: 38,
            ),
            // Separator.
            const SizedBox(width: 4),
            // Arrow keys.
            iconKeyButton(
              icon: Icons.arrow_upward,
              tooltip: 'Up',
              onTap: () => onSendRaw('\x1B[A'),
            ),
            iconKeyButton(
              icon: Icons.arrow_downward,
              tooltip: 'Down',
              onTap: () => onSendRaw('\x1B[B'),
            ),
            iconKeyButton(
              icon: Icons.arrow_back,
              tooltip: 'Left',
              onTap: () => onSendRaw('\x1B[D'),
            ),
            iconKeyButton(
              icon: Icons.arrow_forward,
              tooltip: 'Right',
              onTap: () => onSendRaw('\x1B[C'),
            ),
            // Separator.
            const SizedBox(width: 4),
            // Common chars (Ctrl mode sends control char).
            _CharKey(
              label: '/',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            _CharKey(
              label: '-',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            _CharKey(
              label: '|',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            _CharKey(
              label: '~',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            _CharKey(
              label: '.',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            _CharKey(
              label: '_',
              ctrlMode: ctrlMode,
              onSendRaw: onSendRaw,
              onInsert: onInsert,
              enabled: enabled,
            ),
            // Separator.
            const SizedBox(width: 4),
            // Direct Ctrl combo buttons.
            keyButton(
              label: '^C',
              onTap: () => onSendRaw('\x03'),
              width: 32,
            ),
            keyButton(
              label: '^D',
              onTap: () => onSendRaw('\x04'),
              width: 32,
            ),
            keyButton(
              label: '^L',
              onTap: () => onSendRaw('\x0C'),
              width: 32,
            ),
            keyButton(
              label: '^U',
              onTap: () => onSendRaw('\x15'),
              width: 32,
            ),
          ],
        ),
      ),
    );
  }
}

/// A character key that behaves differently in Ctrl mode.
class _CharKey extends StatelessWidget {
  final String label;
  final bool ctrlMode;
  final void Function(String) onSendRaw;
  final void Function(String) onInsert;
  final bool enabled;

  const _CharKey({
    required this.label,
    required this.ctrlMode,
    required this.onSendRaw,
    required this.onInsert,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isActive = ctrlMode;

    String ctrlVersion(String ch) {
      final code = ch.codeUnitAt(0);
      return String.fromCharCode(code & 0x1F);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: isActive
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: enabled
              ? () {
                  if (ctrlMode) {
                    onSendRaw(ctrlVersion(label));
                  } else {
                    onInsert(label);
                  }
                }
              : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30,
            height: 32,
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isActive
                    ? colorScheme.primary
                    : enabled
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
