import 'package:flutter/material.dart';

class CodeEditor extends StatefulWidget {
  final String content;
  final String fileName;
  final void Function(String content) onContentChanged;
  final VoidCallback? onSave;

  const CodeEditor({
    super.key,
    required this.content,
    required this.fileName,
    required this.onContentChanged,
    this.onSave,
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
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _lineNumberScrollController = ScrollController();
    _editorScrollController = ScrollController();
    _focusNode = FocusNode();
    _controller.addListener(_onTextChanged);
    _editorScrollController.addListener(_syncLineNumbersFromEditor);
    _lineNumberScrollController.addListener(_syncEditorFromLineNumbers);
  }

  @override
  void didUpdateWidget(CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content &&
        widget.content != _controller.text) {
      _controller.removeListener(_onTextChanged);
      _controller.text = widget.content;
      _controller.addListener(_onTextChanged);
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

  @override
  void dispose() {
    _editorScrollController.removeListener(_syncLineNumbersFromEditor);
    _lineNumberScrollController.removeListener(_syncEditorFromLineNumbers);
    _controller.removeListener(_onTextChanged);
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

    return GestureDetector(
      onScaleStart: (_) {},
      onScaleUpdate: (details) {
        if (details.pointerCount >= 2) {
          setState(() {
            _fontSize = (_fontSize * details.scale).clamp(8.0, 32.0);
          });
        }
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line numbers
          Container(
            width: lineNumberWidth,
            color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
            child: SingleChildScrollView(
              controller: _lineNumberScrollController,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(
                    lines.length,
                    (i) => SizedBox(
                      height: _fontSize * 1.5,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize,
                          height: 1.5,
                          color: isDark
                              ? Colors.grey.shade600
                              : Colors.grey.shade400,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Editor area
          Expanded(
            child: Container(
              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF),
              child: SingleChildScrollView(
                controller: _editorScrollController,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth:
                          MediaQuery.of(context).size.width - lineNumberWidth,
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
                        style: TextStyle(
                          fontFamily: 'monospace',
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
        ],
      ),
    );
  }
}
