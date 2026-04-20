import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import '../models/diagnostic.dart';
import '../models/editor_context.dart';

/// Maps highlight.js CSS class names to TextStyle.
class _SyntaxTheme {
  final Map<String, TextStyle> styles;
  final TextStyle defaultStyle;
  final Color backgroundColor;

  const _SyntaxTheme({
    required this.styles,
    required this.defaultStyle,
    required this.backgroundColor,
  });

  static _SyntaxTheme light() {
    return _SyntaxTheme(
      backgroundColor: const Color(0xFFFFFFFF),
      defaultStyle: const TextStyle(color: Color(0xFF000000)),
      styles: const {
        'comment': TextStyle(color: Color(0xFF008000)),
        'quote': TextStyle(color: Color(0xFF008000)),
        'keyword': TextStyle(color: Color(0xFF0000FF)),
        'selector-tag': TextStyle(color: Color(0xFF0000FF)),
        'literal': TextStyle(color: Color(0xFF0000FF)),
        'number': TextStyle(color: Color(0xFF098658)),
        'string': TextStyle(color: Color(0xFFA31515)),
        'doctag': TextStyle(color: Color(0xFFA31515)),
        'title': TextStyle(color: Color(0xFF795E26)),
        'function': TextStyle(color: Color(0xFF795E26)),
        'type': TextStyle(color: Color(0xFF267F99)),
        'built_in': TextStyle(color: Color(0xFF267F99)),
        'class': TextStyle(color: Color(0xFF267F99)),
        'variable': TextStyle(color: Color(0xFF001080)),
        'attr': TextStyle(color: Color(0xFF0451A5)),
        'attribute': TextStyle(color: Color(0xFF0451A5)),
        'params': TextStyle(color: Color(0xFF001080)),
        'meta': TextStyle(color: Color(0xFF808080)),
        'regexp': TextStyle(color: Color(0xFF811F3F)),
        'symbol': TextStyle(color: Color(0xFF098658)),
        'deletion': TextStyle(color: Color(0xFFA31515)),
        'addition': TextStyle(color: Color(0xFF008000)),
      },
    );
  }

  static _SyntaxTheme dark() {
    return _SyntaxTheme(
      backgroundColor: const Color(0xFF1E1E1E),
      defaultStyle: const TextStyle(color: Color(0xFFD4D4D4)),
      styles: const {
        'comment': TextStyle(color: Color(0xFF6A9955)),
        'quote': TextStyle(color: Color(0xFF6A9955)),
        'keyword': TextStyle(color: Color(0xFF569CD6)),
        'selector-tag': TextStyle(color: Color(0xFF569CD6)),
        'literal': TextStyle(color: Color(0xFF569CD6)),
        'number': TextStyle(color: Color(0xFFB5CEA8)),
        'string': TextStyle(color: Color(0xFFCE9178)),
        'doctag': TextStyle(color: Color(0xFFCE9178)),
        'title': TextStyle(color: Color(0xFFDCDCAA)),
        'function': TextStyle(color: Color(0xFFDCDCAA)),
        'type': TextStyle(color: Color(0xFF4EC9B0)),
        'built_in': TextStyle(color: Color(0xFF4EC9B0)),
        'class': TextStyle(color: Color(0xFF4EC9B0)),
        'variable': TextStyle(color: Color(0xFF9CDCFE)),
        'attr': TextStyle(color: Color(0xFF9CDCFE)),
        'attribute': TextStyle(color: Color(0xFF9CDCFE)),
        'params': TextStyle(color: Color(0xFF9CDCFE)),
        'meta': TextStyle(color: Color(0xFF808080)),
        'regexp': TextStyle(color: Color(0xFFD16969)),
        'symbol': TextStyle(color: Color(0xFFB5CEA8)),
        'deletion': TextStyle(color: Color(0xFFCE9178)),
        'addition': TextStyle(color: Color(0xFF6A9955)),
      },
    );
  }
}

class CodeViewer extends StatefulWidget {
  final String content;
  final String fileName;
  final EditorCursor? revealCursor;
  final int revealToken;
  final VoidCallback? onAskAi;
  final void Function(EditorSelection? selection)? onSelectionChanged;
  final VoidCallback? onEditRequested;
  final List<Diagnostic> diagnostics;

  const CodeViewer({
    super.key,
    required this.content,
    required this.fileName,
    this.revealCursor,
    this.revealToken = 0,
    this.onAskAi,
    this.onSelectionChanged,
    this.onEditRequested,
    this.diagnostics = const [],
  });

  @override
  State<CodeViewer> createState() => _CodeViewerState();
}

class _CodeViewerState extends State<CodeViewer> {
  double _fontSize = 13.0;
  double _baseScaleFontSize = 13.0;
  String? _selectedText;
  bool _showToolbar = false;
  int _selectionGeneration = 0;

  // Cached computations to avoid re-running on every zoom frame.
  Map<int, Diagnostic>? _cachedDiagnosticsByLine;
  List<Diagnostic>? _cachedDiagnosticsSource;
  List<TextSpan>? _cachedHighlightedSpans;
  String? _cachedContent;
  String? _cachedFileName;
  Brightness? _cachedBrightness;
  late final ScrollController _verticalScrollController;

  @override
  void initState() {
    super.initState();
    _verticalScrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealCursorIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant CodeViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealToken != widget.revealToken) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealCursorIfNeeded();
      });
    }
  }

  @override
  void dispose() {
    _verticalScrollController.dispose();
    super.dispose();
  }

  Map<int, Diagnostic> get _diagnosticsByLine {
    if (_cachedDiagnosticsSource != widget.diagnostics) {
      _cachedDiagnosticsSource = widget.diagnostics;
      final map = <int, Diagnostic>{};
      for (final d in widget.diagnostics) {
        final existing = map[d.line];
        if (existing == null ||
            _severityRank(d.severity) > _severityRank(existing.severity)) {
          map[d.line] = d;
        }
      }
      _cachedDiagnosticsByLine = map;
    }
    return _cachedDiagnosticsByLine!;
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

  String get _language {
    final ext = widget.fileName.contains('.')
        ? widget.fileName.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'dart':
        return 'dart';
      case 'go':
        return 'go';
      case 'ts':
      case 'tsx':
        return 'typescript';
      case 'js':
      case 'jsx':
        return 'javascript';
      case 'json':
        return 'json';
      case 'yaml':
      case 'yml':
        return 'yaml';
      case 'md':
        return 'markdown';
      case 'py':
        return 'python';
      case 'rs':
        return 'rust';
      case 'html':
        return 'xml';
      case 'css':
        return 'css';
      case 'sh':
      case 'bash':
        return 'bash';
      case 'sql':
        return 'sql';
      case 'xml':
        return 'xml';
      case 'java':
        return 'java';
      case 'kt':
        return 'kotlin';
      case 'swift':
        return 'swift';
      case 'c':
      case 'h':
        return 'cpp';
      case 'cpp':
      case 'cc':
      case 'hpp':
        return 'cpp';
      default:
        return 'plaintext';
    }
  }

  List<TextSpan> _buildHighlightedSpans(
    _SyntaxTheme syntaxTheme,
    Brightness brightness,
  ) {
    if (_cachedHighlightedSpans != null &&
        _cachedContent == widget.content &&
        _cachedFileName == widget.fileName &&
        _cachedBrightness == brightness) {
      return _cachedHighlightedSpans!;
    }
    _cachedContent = widget.content;
    _cachedFileName = widget.fileName;
    _cachedBrightness = brightness;
    try {
      final result = highlight.parse(widget.content, language: _language);
      _cachedHighlightedSpans = _convertNodes(result.nodes ?? [], syntaxTheme);
    } catch (_) {
      _cachedHighlightedSpans = [
        TextSpan(text: widget.content, style: syntaxTheme.defaultStyle),
      ];
    }
    return _cachedHighlightedSpans!;
  }

  List<TextSpan> _convertNodes(List<Node> nodes, _SyntaxTheme syntaxTheme) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      if (node.children != null && node.children!.isNotEmpty) {
        final style =
            syntaxTheme.styles[node.className] ?? syntaxTheme.defaultStyle;
        spans.add(
          TextSpan(
            style: style,
            children: _convertNodes(node.children!, syntaxTheme),
          ),
        );
      } else {
        final style = node.className != null
            ? (syntaxTheme.styles[node.className] ?? syntaxTheme.defaultStyle)
            : syntaxTheme.defaultStyle;
        spans.add(TextSpan(text: node.value, style: style));
      }
    }
    return spans;
  }

  EditorSelection? _selectionFromText(String? text) {
    if (text == null || text.isEmpty) return null;
    final startOffset = widget.content.indexOf(text);
    if (startOffset < 0) return null;
    final endOffset = startOffset + text.length;
    return EditorSelection(
      start: _offsetToCursor(startOffset),
      end: _offsetToCursor(endOffset),
    );
  }

  EditorCursor _offsetToCursor(int rawOffset) {
    final clampedOffset = rawOffset.clamp(0, widget.content.length);
    var line = 1;
    var column = 1;

    for (var i = 0; i < clampedOffset; i++) {
      if (widget.content.codeUnitAt(i) == 10) {
        line++;
        column = 1;
      } else {
        column++;
      }
    }

    return EditorCursor(line: line, column: column);
  }

  void _revealCursorIfNeeded() {
    final cursor = widget.revealCursor;
    if (cursor == null || !_verticalScrollController.hasClients) {
      return;
    }
    final targetOffset =
        ((cursor.line - 1) * _fontSize * 1.5) - (_fontSize * 3);
    final position = _verticalScrollController.position;
    final clamped = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _verticalScrollController.jumpTo(clamped.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final syntaxTheme = isDark ? _SyntaxTheme.dark() : _SyntaxTheme.light();
    final lines = widget.content.split('\n');
    final lineNumberWidth = '${lines.length}'.length * 10.0 + 24.0;

    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onScaleStart: (details) {
              _baseScaleFontSize = _fontSize;
            },
            onScaleUpdate: (details) {
              setState(() {
                _fontSize = (_baseScaleFontSize * details.scale).clamp(
                  8.0,
                  32.0,
                );
              });
            },
            child: Container(
              color: syntaxTheme.backgroundColor,
              child: SelectionArea(
                onSelectionChanged: (value) {
                  final text = value?.plainText;
                  _selectionGeneration++;
                  if (text != null &&
                      text.isNotEmpty &&
                      text != _selectedText) {
                    widget.onSelectionChanged?.call(_selectionFromText(text));
                    setState(() {
                      _selectedText = text;
                      _showToolbar = true;
                    });
                  } else if ((text == null || text.isEmpty) && _showToolbar) {
                    widget.onSelectionChanged?.call(null);
                    final expectedGeneration = _selectionGeneration;
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (mounted &&
                          _selectionGeneration == expectedGeneration) {
                        setState(() {
                          _showToolbar = false;
                        });
                      }
                    });
                  }
                },
                child: SingleChildScrollView(
                  controller: _verticalScrollController,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line numbers with diagnostic gutter
                        Container(
                          width:
                              lineNumberWidth +
                              (widget.diagnostics.isNotEmpty ? 20.0 : 0.0),
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 4,
                          ),
                          color: isDark
                              ? const Color(0xFF1E1E1E)
                              : const Color(0xFFF5F5F5),
                          child: RepaintBoundary(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: List.generate(lines.length, (i) {
                                final lineNum = i + 1;
                                final diag = _diagnosticsByLine[lineNum];
                                return SizedBox(
                                  height: _fontSize * 1.5,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (diag != null)
                                        Tooltip(
                                          message:
                                              '${diag.severity}: ${diag.message}',
                                          child: Icon(
                                            _severityIcon(diag.severity),
                                            size: _fontSize,
                                            color: _severityColor(
                                              diag.severity,
                                            ),
                                          ),
                                        ),
                                      if (diag != null)
                                        const SizedBox(width: 2),
                                      Text(
                                        '$lineNum',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: _fontSize,
                                          height: 1.5,
                                          color: diag != null
                                              ? _severityColor(diag.severity)
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
                        // Code content with syntax highlighting
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: RichText(
                            text: TextSpan(
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: _fontSize,
                                height: 1.5,
                              ),
                              children: _buildHighlightedSpans(
                                syntaxTheme,
                                isDark ? Brightness.dark : Brightness.light,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Selection toolbar
        if (_showToolbar && _selectedText != null && _selectedText!.isNotEmpty)
          _SelectionToolbar(
            onAskAi: widget.onAskAi != null
                ? () {
                    widget.onAskAi!();
                    setState(() => _showToolbar = false);
                  }
                : null,
            onEdit: widget.onEditRequested != null
                ? () {
                    widget.onEditRequested!();
                    setState(() => _showToolbar = false);
                  }
                : null,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: _selectedText!));
              setState(() => _showToolbar = false);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
      ],
    );
  }
}

class _SelectionToolbar extends StatelessWidget {
  final VoidCallback? onAskAi;
  final VoidCallback? onEdit;
  final VoidCallback onCopy;

  const _SelectionToolbar({this.onAskAi, this.onEdit, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (onAskAi != null)
            TextButton.icon(
              onPressed: onAskAi,
              icon: const Icon(Icons.smart_toy, size: 20),
              label: const Text('Ask AI'),
            ),
          if (onEdit != null)
            TextButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit, size: 20),
              label: const Text('Edit'),
            ),
          TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 20),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}
