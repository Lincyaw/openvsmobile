// Read-only file viewer. Monospace, with syntax highlighting when the
// filename maps to a language the `highlight` package knows; plain
// monospace otherwise.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';

import '../app_state.dart';
import '../models.dart';
import '../selection_context.dart';
import '../ui/app_tokens.dart';
import '../ui/highlight_theme.dart';
import 'selection_plugin_action_button.dart';

/// Files larger than this render as plain monospace text. Highlighting is
/// synchronous and would block the UI thread for big files; pure
/// `SelectableText` stays smooth and keeps the surface usable.
const int _kHighlightMaxBytes = 200 * 1024;
const double _kCodeLineHeight = 1.35;

// Extension → highlight.js language id. Anything not in this map renders as
// plain monospace text. Keep entries lowercase; lookup normalises before
// indexing. Substitutions (`.toml` → `ini`, `.html` → `xml`, `.c/.h` →
// `cpp`) are deliberate — the bundled grammar covers them well enough.
// Anything without a reasonable grammar match falls through to plain mono
// on purpose; mis-tagging a language paints the wrong tokens and is worse
// than no highlighting.
const Map<String, String> _kLanguageByExtension = {
  'dart': 'dart',
  'ts': 'typescript',
  'tsx': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'json': 'json',
  'jsonc': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'md': 'markdown',
  'markdown': 'markdown',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'ps1': 'powershell',
  'py': 'python',
  'rb': 'ruby',
  'go': 'go',
  'rs': 'rust',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'swift': 'swift',
  'scala': 'scala',
  'lua': 'lua',
  'r': 'r',
  'php': 'php',
  'cs': 'cs',
  'cpp': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'hxx': 'cpp',
  'c': 'cpp',
  'h': 'cpp',
  'sql': 'sql',
  'proto': 'protobuf',
  'graphql': 'graphql',
  'gql': 'graphql',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'svg': 'xml',
  'css': 'css',
  'scss': 'scss',
  'less': 'less',
  'toml': 'ini',
  'ini': 'ini',
  'conf': 'ini',
  'properties': 'properties',
  'diff': 'diff',
  'patch': 'diff',
  'dockerfile': 'dockerfile',
  'gradle': 'gradle',
};

// Filename (case-insensitive) → highlight.js language id. Used for files
// that carry meaning in their name rather than their extension. Checked
// before the extension table.
const Map<String, String> _kLanguageByFilename = {
  'dockerfile': 'dockerfile',
  'containerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
  'cmakelists.txt': 'cmake',
  '.gitignore': 'properties',
  '.gitattributes': 'properties',
  '.env': 'properties',
  '.bashrc': 'bash',
  '.zshrc': 'bash',
  '.bash_profile': 'bash',
};

String? _languageForPath(String path) {
  final fileName = path.split('/').last;
  final lower = fileName.toLowerCase();
  final byName = _kLanguageByFilename[lower];
  if (byName != null) return byName;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return null;
  return _kLanguageByExtension[fileName.substring(dot + 1).toLowerCase()];
}

class FileViewerScreen extends StatefulWidget {
  final String path;
  final FileContent content;
  final AppState? appState;
  const FileViewerScreen({
    super.key,
    required this.path,
    required this.content,
    this.appState,
  });

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'file-search');
  final ScrollController _codeScroll = ScrollController();
  bool _searchOpen = false;
  String _searchQuery = '';
  List<int> _matchLines = const [];
  int _matchIndex = 0;

  String get _selectionSourceId => SelectionContext.fileSourceId(widget.path);

  String? get _workspaceId => widget.appState?.currentWorkspace?.id;

  String? get _workspaceRoot => widget.appState?.currentWorkspace?.root;

  String? get _relativePath {
    final root = _workspaceRoot;
    if (root == null || root.isEmpty) return null;
    if (widget.path == root) return '';
    if (widget.path.startsWith('$root/')) {
      return widget.path.substring(root.length + 1);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.appState?.clearSelectionContext();
  }

  @override
  void didUpdateWidget(covariant FileViewerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.appState != widget.appState) {
      oldWidget.appState?.clearSelectionContext(
        sourceId: SelectionContext.fileSourceId(oldWidget.path),
      );
      widget.appState?.clearSelectionContext();
    }
  }

  @override
  void dispose() {
    widget.appState?.clearSelectionContext(sourceId: _selectionSourceId);
    _searchController.dispose();
    _searchFocus.dispose();
    _codeScroll.dispose();
    super.dispose();
  }

  void _onSelectionContextChanged(SelectionContext? selection) {
    final appState = widget.appState;
    if (appState == null) return;
    if (selection == null) {
      appState.clearSelectionContext(sourceId: _selectionSourceId);
    } else {
      appState.setSelectionContext(selection);
    }
  }

  void _toggleSearch(String text) {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _searchQuery = '';
        _matchLines = const [];
        _matchIndex = 0;
      } else {
        _updateSearch(_searchController.text, text, notify: false);
      }
    });
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchFocus.requestFocus();
      });
    }
  }

  void _updateSearch(String raw, String text, {bool notify = true}) {
    final query = raw.trim();
    final matches = _findMatchLines(text, query);
    void apply() {
      _searchQuery = query;
      _matchLines = matches;
      if (_matchIndex >= matches.length) _matchIndex = 0;
      if (matches.isEmpty) _matchIndex = 0;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
    if (matches.isNotEmpty) {
      _scrollToLine(matches[_matchIndex]);
    }
  }

  List<int> _findMatchLines(String text, String query) {
    if (query.isEmpty) return const [];
    final lowerQuery = query.toLowerCase();
    final lines = _splitLines(text);
    final out = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().contains(lowerQuery)) {
        out.add(i + 1);
      }
    }
    return out;
  }

  void _moveMatch(int delta) {
    if (_matchLines.isEmpty) return;
    setState(() {
      _matchIndex = (_matchIndex + delta) % _matchLines.length;
      if (_matchIndex < 0) _matchIndex += _matchLines.length;
    });
    _scrollToLine(_matchLines[_matchIndex]);
  }

  void _scrollToLine(int line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_codeScroll.hasClients) return;
      final fontSize = AppText.monoCode(context).fontSize ?? 14;
      final lineExtent = fontSize * _kCodeLineHeight;
      final target = ((line - 1) * lineExtent).clamp(
        _codeScroll.position.minScrollExtent,
        _codeScroll.position.maxScrollExtent,
      );
      _codeScroll.animateTo(
        target.toDouble(),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.path.split('/').last;
    final isText = !widget.content.isBinary;
    final text = isText
        ? utf8.decode(widget.content.bytes, allowMalformed: true)
        : '';
    return Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? TextField(
                key: const ValueKey<String>('file-search-field'),
                controller: _searchController,
                focusNode: _searchFocus,
                decoration: const InputDecoration(
                  hintText: 'Find in file',
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onChanged: (value) => _updateSearch(value, text),
              )
            : Text(fileName),
        actions: [
          if (widget.appState != null)
            SelectionPluginActionButton(appState: widget.appState!),
          if (isText)
            IconButton(
              key: const ValueKey<String>('file-search-toggle'),
              tooltip: _searchOpen ? 'Close search' : 'Find in file',
              icon: Icon(_searchOpen ? Icons.close : Icons.search),
              onPressed: () => _toggleSearch(text),
            ),
          IconButton(
            tooltip: 'Show full path',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(widget.path)));
            },
          ),
        ],
      ),
      body: widget.content.isBinary
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text(
                  'Binary file, ${widget.content.bytes.length} bytes\n\n'
                  'Preview is not supported in this view.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            )
          : Column(
              children: [
                if (_searchOpen)
                  _SearchSummaryBar(
                    query: _searchQuery,
                    matchCount: _matchLines.length,
                    currentIndex: _matchIndex,
                    currentLine: _matchLines.isEmpty
                        ? null
                        : _matchLines[_matchIndex],
                    onPrevious: () => _moveMatch(-1),
                    onNext: () => _moveMatch(1),
                  ),
                Expanded(
                  child: _TextBody(
                    path: widget.path,
                    text: text,
                    scrollController: _codeScroll,
                    currentMatchLine: _matchLines.isEmpty
                        ? null
                        : _matchLines[_matchIndex],
                    workspaceId: _workspaceId,
                    workspaceRoot: _workspaceRoot,
                    relativePath: _relativePath,
                    onSelectionContextChanged: _onSelectionContextChanged,
                  ),
                ),
              ],
            ),
    );
  }
}

class _TextBody extends StatelessWidget {
  final String path;
  final String text;
  final ScrollController scrollController;
  final int? currentMatchLine;
  final String? workspaceId;
  final String? workspaceRoot;
  final String? relativePath;
  final ValueChanged<SelectionContext?>? onSelectionContextChanged;
  const _TextBody({
    required this.path,
    required this.text,
    required this.scrollController,
    required this.currentMatchLine,
    required this.workspaceId,
    required this.workspaceRoot,
    required this.relativePath,
    this.onSelectionContextChanged,
  });

  @override
  Widget build(BuildContext context) {
    final language = _languageForPath(path);
    final tooLargeToHighlight = utf8.encode(text).length > _kHighlightMaxBytes;
    final codeStyle = AppText.monoCode(
      context,
    ).copyWith(height: _kCodeLineHeight);
    final lineCount = tooLargeToHighlight ? null : _splitLines(text).length;

    if (language == null || tooLargeToHighlight) {
      return _CodeScrollFrame(
        controller: scrollController,
        lineCount: lineCount,
        currentLine: currentMatchLine,
        child: SelectableText(
          text,
          style: codeStyle,
          onSelectionChanged: (selection, _) {
            onSelectionContextChanged?.call(
              SelectionContext.fromFileOffsets(
                path: path,
                fullText: text,
                baseOffset: selection.baseOffset,
                extentOffset: selection.extentOffset,
                language: language,
                workspaceId: workspaceId,
                workspaceRoot: workspaceRoot,
                relativePath: relativePath,
              ),
            );
          },
        ),
      );
    }

    // `HighlightView` renders into a non-selectable `RichText`; wrapping in
    // `SelectionArea` re-introduces long-press selection + clipboard copy.
    return _CodeScrollFrame(
      controller: scrollController,
      lineCount: lineCount,
      currentLine: currentMatchLine,
      child: SelectionArea(
        onSelectionChanged: (content) {
          onSelectionContextChanged?.call(
            content == null
                ? null
                : SelectionContext.fromFileSelectedText(
                    path: path,
                    fullText: text,
                    selectedText: content.plainText,
                    language: language,
                    workspaceId: workspaceId,
                    workspaceRoot: workspaceRoot,
                    relativePath: relativePath,
                  ),
          );
        },
        child: HighlightView(
          text,
          language: language,
          theme: highlightThemeForBrightness(Theme.of(context).brightness),
          padding: EdgeInsets.zero,
          textStyle: codeStyle,
        ),
      ),
    );
  }
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [''];
  return text.split('\n');
}

class _SearchSummaryBar extends StatelessWidget {
  final String query;
  final int matchCount;
  final int currentIndex;
  final int? currentLine;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  const _SearchSummaryBar({
    required this.query,
    required this.matchCount,
    required this.currentIndex,
    required this.currentLine,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = query.isEmpty
        ? 'Enter a query'
        : matchCount == 0
        ? 'No matches'
        : '${currentIndex + 1} of $matchCount · line $currentLine';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                label,
                key: const ValueKey<String>('file-search-summary'),
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Previous match',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: matchCount > 0 ? onPrevious : null,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Next match',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: matchCount > 0 ? onNext : null,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeScrollFrame extends StatelessWidget {
  final ScrollController controller;
  final int? lineCount;
  final int? currentLine;
  final Widget child;
  const _CodeScrollFrame({
    required this.controller,
    required this.lineCount,
    required this.currentLine,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lineCount != null) ...[
                _LineNumberGutter(
                  lineCount: lineCount!,
                  currentLine: currentLine,
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: MediaQuery.sizeOf(context).width - 72,
                ),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineNumberGutter extends StatelessWidget {
  final int lineCount;
  final int? currentLine;
  const _LineNumberGutter({required this.lineCount, required this.currentLine});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = (lineCount.toString().length * 8 + 16).toDouble();
    final style = AppText.monoCaption(context).copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: _kCodeLineHeight,
    );
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 1; i <= lineCount; i++)
            Container(
              key: ValueKey<String>('file-line-number:$i'),
              width: double.infinity,
              color: i == currentLine
                  ? theme.colorScheme.secondaryContainer
                  : Colors.transparent,
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: Text('$i', textAlign: TextAlign.right, style: style),
            ),
        ],
      ),
    );
  }
}
