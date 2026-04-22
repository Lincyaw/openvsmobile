import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/terminal_provider.dart';
import '../theme/monospace_text.dart';
import '../terminal/terminal_input_handler.dart';
import 'terminal_renderer.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.sessionId,
    required this.view,
    required this.isActive,
    required this.onSubmit,
    required this.onDraftChanged,
    required this.onResize,
    required this.onSendRaw,
    this.compact = false,
  });

  final String sessionId;
  final TerminalSessionView view;
  final bool isActive;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onDraftChanged;
  final void Function(int rows, int cols) onResize;
  final ValueChanged<String> onSendRaw;
  final bool compact;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  static const double _fontSize = 13;
  static const double _lineHeight = 1.4;
  static const double _padding = 8;
  static const double _autoScrollTolerance = 24;

  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  late final FocusNode _terminalFocusNode;
  late final FocusNode _inputFocusNode;
  int _lastFocusToken = 0;
  bool _ctrlMode = false;
  bool _followOutput = true;
  bool _showCompactComposer = false;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.view.inputDraft);
    _scrollController = ScrollController()..addListener(_handleScrollChange);
    _terminalFocusNode = FocusNode(debugLabel: 'terminal-surface');
    _inputFocusNode = FocusNode(debugLabel: 'terminal-input');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _followOutput = true;
      _showCompactComposer = false;
    }
    if (_inputController.text != widget.view.inputDraft) {
      _inputController.value = TextEditingValue(
        text: widget.view.inputDraft,
        selection: TextSelection.collapsed(
          offset: widget.view.inputDraft.length,
        ),
      );
    }
    if (widget.view.focusRequest > _lastFocusToken && widget.isActive) {
      _lastFocusToken = widget.view.focusRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _terminalFocusNode.requestFocus();
        }
      });
    }
    _scrollToBottom();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScrollChange);
    _inputController.dispose();
    _scrollController.dispose();
    _terminalFocusNode.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _handleScrollChange() {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final distanceFromBottom = position.maxScrollExtent - position.pixels;
    _followOutput = distanceFromBottom <= _autoScrollTolerance;
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      if (!force && !_followOutput) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      if ((_scrollController.offset - target).abs() <= 1) {
        return;
      }
      _scrollController.jumpTo(target);
    });
  }

  void _submit() {
    final text = _inputController.text;
    if (text.isEmpty) {
      return;
    }
    widget.onSubmit('$text\r');
    _inputController.clear();
    widget.onDraftChanged('');
    _terminalFocusNode.requestFocus();
  }

  KeyEventResult _handleTerminalKey(FocusNode node, KeyEvent event) {
    if (!widget.view.isInteractive) {
      return KeyEventResult.ignored;
    }
    final encoded = TerminalInputHandler.translateKey(
      event.logicalKey,
      character: event.character,
      ctrlPressed: HardwareKeyboard.instance.isControlPressed,
      altPressed: HardwareKeyboard.instance.isAltPressed,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      applicationCursorKeys: widget.view.snapshot.applicationCursorKeys,
    );
    if (encoded == null) {
      return KeyEventResult.ignored;
    }
    widget.onSendRaw(encoded);
    return KeyEventResult.handled;
  }

  void _sendToolbarRaw(String value) {
    if (!widget.view.isInteractive) {
      return;
    }
    widget.onSendRaw(value);
    _terminalFocusNode.requestFocus();
  }

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
    widget.onDraftChanged(newText);
    _inputFocusNode.requestFocus();
  }

  void _toggleCompactComposer() {
    setState(() => _showCompactComposer = !_showCompactComposer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_showCompactComposer) {
        _inputFocusNode.requestFocus();
      } else {
        _terminalFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final terminalBackground = isDark
        ? const Color(0xFF1E1E1E)
        : const Color(0xFFF5F5F5);
    final terminalForeground = isDark
        ? const Color(0xFFD4D4D4)
        : const Color(0xFF1E1E1E);
    final snapshot = widget.view.snapshot;

    final paneBody = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.compact)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.view.session.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Chip(label: Text(widget.view.statusLabel)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(widget.view.helperText, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cols = ((constraints.maxWidth - (_padding * 2)) / 7.8)
                  .floor()
                  .clamp(20, 300);
              final rows = (constraints.maxHeight / (_fontSize * _lineHeight))
                  .floor()
                  .clamp(5, 100);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.onResize(rows, cols);
              });

              return Focus(
                focusNode: _terminalFocusNode,
                canRequestFocus: widget.view.isInteractive,
                onKeyEvent: _handleTerminalKey,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _terminalFocusNode.requestFocus(),
                  child: Container(
                    key: const ValueKey<String>('terminal-surface'),
                    color: terminalBackground,
                    padding: const EdgeInsets.all(_padding),
                    child: TerminalRenderer(
                      snapshot: snapshot,
                      scrollController: _scrollController,
                      fontSize: _fontSize,
                      lineHeight: _lineHeight,
                      defaultForeground: terminalForeground,
                      defaultBackground: terminalBackground,
                      focused: _terminalFocusNode.hasFocus && widget.isActive,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          color: theme.colorScheme.surfaceContainerHigh,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TerminalKeyToolbar(
                compact: widget.compact,
                showComposer: _showCompactComposer,
                ctrlMode: _ctrlMode,
                enabled: widget.view.isInteractive,
                onToggleCtrl: () {
                  setState(() => _ctrlMode = !_ctrlMode);
                  _terminalFocusNode.requestFocus();
                },
                onToggleComposer: widget.compact ? _toggleCompactComposer : null,
                onSendRaw: _sendToolbarRaw,
                onInsert: _insertAtCursor,
              ),
              if (!widget.compact || _showCompactComposer)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Row(
                    children: [
                    Text(
                      r'$ ',
                      style: monospaceTextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 14,
                      ),
                    ),
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          focusNode: _inputFocusNode,
                          enabled: widget.view.isInteractive,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Enter command...',
                            isDense: true,
                          ),
                          style: monospaceTextStyle(
                            fontSize: 13,
                          ),
                          onChanged: widget.onDraftChanged,
                          onSubmitted: (_) => _submit(),
                          textInputAction: TextInputAction.send,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send command',
                        onPressed: widget.view.isInteractive ? _submit : null,
                        icon: const Icon(Icons.send, size: 20),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    if (widget.compact) {
      return ColoredBox(color: terminalBackground, child: paneBody);
    }

    return Card(clipBehavior: Clip.antiAlias, child: paneBody);
  }
}

class _TerminalKeyToolbar extends StatelessWidget {
  const _TerminalKeyToolbar({
    required this.compact,
    required this.showComposer,
    required this.ctrlMode,
    required this.onToggleCtrl,
    required this.onSendRaw,
    required this.onInsert,
    required this.enabled,
    this.onToggleComposer,
  });

  final bool compact;
  final bool showComposer;
  final bool ctrlMode;
  final VoidCallback onToggleCtrl;
  final ValueChanged<String> onSendRaw;
  final ValueChanged<String> onInsert;
  final bool enabled;
  final VoidCallback? onToggleComposer;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget keyButton({
      required String label,
      required VoidCallback? onTap,
      bool active = false,
      double width = 40,
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
            child: SizedBox(
              width: width,
              height: 32,
              child: Center(
                child: Text(
                  label,
                    style: monospaceTextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: active
                        ? colorScheme.primary
                        : enabled
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget iconKeyButton({
      required IconData icon,
      required VoidCallback? onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: colorScheme.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 36,
              height: 32,
              child: Center(
                child: Icon(
                  icon,
                  size: 16,
                  color: enabled
                      ? colorScheme.onSurface
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              iconKeyButton(
                icon: showComposer ? Icons.keyboard_hide : Icons.keyboard,
                onTap: onToggleComposer,
              ),
              const SizedBox(width: 4),
              keyButton(label: '^C', width: 38, onTap: () => onSendRaw('\x03')),
              keyButton(label: '^D', width: 38, onTap: () => onSendRaw('\x04')),
              keyButton(label: 'Esc', width: 38, onTap: () => onSendRaw('\x1B')),
              keyButton(label: 'Tab', width: 38, onTap: () => onSendRaw('\t')),
              keyButton(label: 'Enter', width: 48, onTap: () => onSendRaw('\r')),
              const SizedBox(width: 4),
              iconKeyButton(
                icon: Icons.arrow_upward,
                onTap: () => onSendRaw('\x1B[A'),
              ),
              iconKeyButton(
                icon: Icons.arrow_downward,
                onTap: () => onSendRaw('\x1B[B'),
              ),
              iconKeyButton(
                icon: Icons.arrow_back,
                onTap: () => onSendRaw('\x1B[D'),
              ),
              iconKeyButton(
                icon: Icons.arrow_forward,
                onTap: () => onSendRaw('\x1B[C'),
              ),
            ],
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
            keyButton(
              label: 'Ctrl',
              width: 42,
              active: ctrlMode,
              onTap: onToggleCtrl,
            ),
            keyButton(label: 'Esc', onTap: () => onSendRaw('\x1B')),
            keyButton(label: 'Tab', onTap: () => onSendRaw('\t'), width: 38),
            const SizedBox(width: 4),
            iconKeyButton(
              icon: Icons.arrow_upward,
              onTap: () => onSendRaw('\x1B[A'),
            ),
            iconKeyButton(
              icon: Icons.arrow_downward,
              onTap: () => onSendRaw('\x1B[B'),
            ),
            iconKeyButton(
              icon: Icons.arrow_back,
              onTap: () => onSendRaw('\x1B[D'),
            ),
            iconKeyButton(
              icon: Icons.arrow_forward,
              onTap: () => onSendRaw('\x1B[C'),
            ),
            const SizedBox(width: 4),
            for (final label in const <String>['/', '-', '|', '~', '.', '_'])
              _ToolbarCharKey(
                label: label,
                ctrlMode: ctrlMode,
                enabled: enabled,
                onSendRaw: onSendRaw,
                onInsert: onInsert,
              ),
            const SizedBox(width: 4),
            keyButton(label: '^C', width: 32, onTap: () => onSendRaw('\x03')),
            keyButton(label: '^D', width: 32, onTap: () => onSendRaw('\x04')),
            keyButton(label: '^L', width: 32, onTap: () => onSendRaw('\x0C')),
            keyButton(label: '^U', width: 32, onTap: () => onSendRaw('\x15')),
          ],
        ),
      ),
    );
  }
}

class _ToolbarCharKey extends StatelessWidget {
  const _ToolbarCharKey({
    required this.label,
    required this.ctrlMode,
    required this.onSendRaw,
    required this.onInsert,
    required this.enabled,
  });

  final String label;
  final bool ctrlMode;
  final ValueChanged<String> onSendRaw;
  final ValueChanged<String> onInsert;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: ctrlMode
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: !enabled
              ? null
              : () {
                  if (ctrlMode) {
                    final ctrl = TerminalInputHandler.ctrlCharacter(label);
                    if (ctrl != null) {
                      onSendRaw(ctrl);
                    }
                    return;
                  }
                  onInsert(label);
                },
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 30,
            height: 32,
            child: Center(
              child: Text(
                label,
                style: monospaceTextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ctrlMode
                      ? colorScheme.primary
                      : enabled
                      ? colorScheme.onSurface
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
