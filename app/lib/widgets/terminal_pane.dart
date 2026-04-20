import 'package:flutter/material.dart';

import '../providers/terminal_provider.dart';
import 'ansi_text.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.sessionId,
    required this.view,
    required this.isActive,
    required this.onSubmit,
    required this.onDraftChanged,
    required this.onResize,
  });

  final String sessionId;
  final TerminalSessionView view;
  final bool isActive;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onDraftChanged;
  final void Function(int rows, int cols) onResize;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  static const double _fontSize = 13;
  static const double _lineHeight = 1.4;
  static const double _padding = 8;

  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  late final FocusNode _focusNode;
  int _lastFocusToken = 0;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.view.inputDraft);
    _scrollController = ScrollController();
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
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
          _focusNode.requestFocus();
        }
      });
    }
    if (oldWidget.view.outputText != widget.view.outputText) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _inputController.text;
    if (text.isEmpty) {
      return;
    }
    widget.onSubmit('$text\n');
    _inputController.clear();
    widget.onDraftChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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

                return Container(
                  color: isDark
                      ? const Color(0xFF1E1E1E)
                      : const Color(0xFFF5F5F5),
                  padding: const EdgeInsets.all(_padding),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: AnsiText(
                      widget.view.outputText,
                      fontSize: _fontSize,
                      lineHeight: _lineHeight,
                      defaultForeground: isDark
                          ? const Color(0xFFD4D4D4)
                          : const Color(0xFF1E1E1E),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            color: theme.colorScheme.surfaceContainerHigh,
            child: Row(
              children: [
                Text(
                  '\$ ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.primary,
                    fontSize: 14,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    enabled: widget.view.isInteractive,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Enter command...',
                      isDense: true,
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
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
    );
  }
}
