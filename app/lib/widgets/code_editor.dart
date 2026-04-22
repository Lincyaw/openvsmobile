import 'package:flutter/material.dart';

import '../models/diagnostic.dart';
import '../models/editor_context.dart';
import '../theme/monospace_text.dart';

class CodeEditor extends StatefulWidget {
  final String content;
  final String fileName;
  final void Function(String content) onContentChanged;
  final void Function(EditorCursor cursor)? onCursorChanged;
  final void Function(EditorSelection? selection, EditorCursor cursor)?
  onSelectionChanged;
  final VoidCallback? onSave;
  final List<Diagnostic> diagnostics;
  final EditorSelection? revealSelection;
  final int revealNonce;

  const CodeEditor({
    super.key,
    required this.content,
    required this.fileName,
    required this.onContentChanged,
    this.onCursorChanged,
    this.onSelectionChanged,
    this.onSave,
    this.diagnostics = const <Diagnostic>[],
    this.revealSelection,
    this.revealNonce = 0,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late TextEditingController _controller;
  late ScrollController _lineNumberScrollController;
  late ScrollController _editorScrollController;
  late FocusNode _focusNode;
  double _fontSize = 13.0;
  double _baseScaleFontSize = 13.0;
  bool _isSyncing = false;

  double get _lineHeight => _fontSize * 1.5;
  double get _characterWidth => _fontSize * 0.62;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _lineNumberScrollController = ScrollController();
    _editorScrollController = ScrollController();
    _focusNode = FocusNode();
    _controller.addListener(_onTextChanged);
    _controller.addListener(_onSelectionChanged);
    _editorScrollController.addListener(_syncLineNumbersFromEditor);
    _lineNumberScrollController.addListener(_syncEditorFromLineNumbers);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyRevealSelection(),
    );
  }

  @override
  void didUpdateWidget(CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content &&
        widget.content != _controller.text) {
      _controller.removeListener(_onTextChanged);
      _controller.removeListener(_onSelectionChanged);
      final selection = _controller.selection;
      _controller.text = widget.content;
      if (selection.isValid) {
        final clampedBase = selection.baseOffset.clamp(
          0,
          widget.content.length,
        );
        final clampedExtent = selection.extentOffset.clamp(
          0,
          widget.content.length,
        );
        _controller.selection = TextSelection(
          baseOffset: clampedBase,
          extentOffset: clampedExtent,
        );
      }
      _controller.addListener(_onTextChanged);
      _controller.addListener(_onSelectionChanged);
    }

    if (oldWidget.revealNonce != widget.revealNonce ||
        oldWidget.revealSelection != widget.revealSelection) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _applyRevealSelection(),
      );
    }
  }

  void _syncLineNumbersFromEditor() {
    if (_isSyncing) return;
    _isSyncing = true;
    if (_lineNumberScrollController.hasClients) {
      _lineNumberScrollController.jumpTo(_editorScrollController.offset);
    }
    _isSyncing = false;
  }

  void _syncEditorFromLineNumbers() {
    if (_isSyncing) return;
    _isSyncing = true;
    if (_editorScrollController.hasClients) {
      _editorScrollController.jumpTo(_lineNumberScrollController.offset);
    }
    _isSyncing = false;
  }

  void _onTextChanged() {
    widget.onContentChanged(_controller.text);
  }

  void _onSelectionChanged() {
    final selection = _controller.selection;
    if (!selection.isValid) return;

    final cursor = _offsetToCursor(selection.extentOffset);
    widget.onCursorChanged?.call(cursor);

    if (selection.isCollapsed) {
      widget.onSelectionChanged?.call(null, cursor);
      return;
    }

    final startOffset = selection.start < selection.end
        ? selection.start
        : selection.end;
    final endOffset = selection.start < selection.end
        ? selection.end
        : selection.start;
    widget.onSelectionChanged?.call(
      EditorSelection(
        start: _offsetToCursor(startOffset),
        end: _offsetToCursor(endOffset),
      ),
      cursor,
    );
  }

  void _applyRevealSelection() {
    final selection = widget.revealSelection;
    if (selection == null || !mounted) {
      return;
    }

    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }

    final startOffset = _cursorToOffset(selection.start);
    final endOffset = _cursorToOffset(selection.end);
    _controller.selection = TextSelection(
      baseOffset: startOffset,
      extentOffset: endOffset,
    );

    if (_editorScrollController.hasClients) {
      final targetOffset = ((selection.start.line - 1) * _lineHeight).clamp(
        0.0,
        _editorScrollController.position.maxScrollExtent,
      );
      _editorScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  EditorCursor _offsetToCursor(int rawOffset) {
    final text = _controller.text;
    final clampedOffset = rawOffset.clamp(0, text.length);
    var line = 1;
    var column = 1;

    for (var i = 0; i < clampedOffset; i++) {
      if (text.codeUnitAt(i) == 10) {
        line++;
        column = 1;
      } else {
        column++;
      }
    }

    return EditorCursor(line: line, column: column);
  }

  int _cursorToOffset(EditorCursor cursor) {
    final text = _controller.text;
    final targetLine = cursor.line > 0 ? cursor.line : 1;
    final targetColumn = cursor.column > 0 ? cursor.column : 1;
    var line = 1;
    var column = 1;

    for (var index = 0; index < text.length; index += 1) {
      if (line == targetLine && column == targetColumn) {
        return index;
      }
      if (text.codeUnitAt(index) == 10) {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }

    return text.length;
  }

  bool _isLineHighlighted(int lineNumber) {
    final selection = widget.revealSelection;
    if (selection == null) {
      return false;
    }
    return lineNumber >= selection.start.line &&
        lineNumber <= selection.end.line;
  }

  Diagnostic? _diagnosticForLine(int lineNumber) {
    Diagnostic? candidate;
    for (final diagnostic in widget.diagnostics) {
      if (!diagnostic.range.containsLine(lineNumber)) {
        continue;
      }
      if (candidate == null ||
          _severityRank(diagnostic.severity) >
              _severityRank(candidate.severity)) {
        candidate = diagnostic;
      }
    }
    return candidate;
  }

  int _severityRank(String severity) {
    switch (severity) {
      case 'error':
        return 3;
      case 'warning':
        return 2;
      case 'info':
        return 1;
      default:
        return 0;
    }
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'error':
        return const Color(0xFFFF4444);
      case 'warning':
        return const Color(0xFFFF8800);
      case 'info':
        return const Color(0xFF4488FF);
      default:
        return const Color(0xFF888888);
    }
  }

  double _editorContentWidth(BuildContext context, double lineNumberWidth) {
    final longestLineLength = _controller.text
        .split('\n')
        .fold<int>(
          0,
          (maxLength, line) =>
              line.length > maxLength ? line.length : maxLength,
        );
    final viewportWidth =
        MediaQuery.of(context).size.width - lineNumberWidth - 16;
    final contentWidth = (longestLineLength + 1) * _characterWidth;
    return contentWidth > viewportWidth ? contentWidth : viewportWidth;
  }

  IconData _severityIcon(String severity) {
    switch (severity) {
      case 'error':
        return Icons.error;
      case 'warning':
        return Icons.warning;
      case 'info':
        return Icons.info_outline;
      default:
        return Icons.circle;
    }
  }

  @override
  void dispose() {
    _editorScrollController.removeListener(_syncLineNumbersFromEditor);
    _lineNumberScrollController.removeListener(_syncEditorFromLineNumbers);
    _controller.removeListener(_onTextChanged);
    _controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    _lineNumberScrollController.dispose();
    _editorScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lines = _controller.text.split('\n');
    final lineNumberWidth = '${lines.length}'.length * 10.0 + 24.0;
    final highlightColor = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.12);

    return GestureDetector(
      onScaleStart: (_) {
        _baseScaleFontSize = _fontSize;
      },
      onScaleUpdate: (details) {
        if (details.pointerCount >= 2) {
          setState(() {
            _fontSize = (_baseScaleFontSize * details.scale).clamp(8.0, 32.0);
          });
        }
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width:
                lineNumberWidth + (widget.diagnostics.isNotEmpty ? 20.0 : 0.0),
            color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
            child: SingleChildScrollView(
              controller: _lineNumberScrollController,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: RepaintBoundary(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(lines.length, (index) {
                      final lineNumber = index + 1;
                      final diagnostic = _diagnosticForLine(lineNumber);
                      return Container(
                        height: _lineHeight,
                        color: _isLineHighlighted(lineNumber)
                            ? highlightColor
                            : null,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (diagnostic != null)
                              Tooltip(
                                message:
                                    '${diagnostic.severity}: ${diagnostic.message}',
                                child: Icon(
                                  _severityIcon(diagnostic.severity),
                                  size: _fontSize,
                                  color: _severityColor(diagnostic.severity),
                                ),
                              ),
                            if (diagnostic != null) const SizedBox(width: 2),
                            Text(
                              '$lineNumber',
                              style: monospaceTextStyle(
                                fontSize: _fontSize,
                                height: 1.5,
                                color: diagnostic != null
                                    ? _severityColor(diagnostic.severity)
                                    : (isDark
                                          ? Colors.grey.shade600
                                          : Colors.grey.shade400),
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF),
              child: SingleChildScrollView(
                controller: _editorScrollController,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _editorContentWidth(context, lineNumberWidth),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: MediaQuery.of(context).size.height,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          maxLines: null,
                          expands: false,
                          keyboardType: TextInputType.multiline,
                          style: monospaceTextStyle(
                            fontSize: _fontSize,
                            height: 1.5,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
