// Read-only file viewer. Monospace, with syntax highlighting when the
// filename extension maps to a language the `highlight` package knows;
// plain monospace otherwise.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';

import '../models.dart';
import '../ui/app_tokens.dart';

final _kCodeTextStyle = AppText.mono(fontSize: 13, height: 1.35);

// Extension → highlight.js language id. Anything not in this map renders as
// plain monospace text (the original v0 behaviour). Keep entries lowercase;
// lookup normalises to lowercase before indexing.
//
// `.toml` maps to `ini` and `.html` maps to `xml` — the `highlight` package
// doesn't ship dedicated grammars for those, and these are the closest
// supported substitutes. `.c` / `.h` ride on the `cpp` grammar for the
// same reason.
const Map<String, String> _kLanguageByExtension = {
  'dart': 'dart',
  'ts': 'typescript',
  'tsx': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'md': 'markdown',
  'sh': 'bash',
  'bash': 'bash',
  'py': 'python',
  'go': 'go',
  'html': 'xml',
  'css': 'css',
  'toml': 'ini',
  'xml': 'xml',
  'kt': 'kotlin',
  'swift': 'swift',
  'rs': 'rust',
  'c': 'cpp',
  'h': 'cpp',
  'cpp': 'cpp',
  'hpp': 'cpp',
  'java': 'java',
  'gradle': 'gradle',
};

String? _languageForPath(String path) {
  final fileName = path.split('/').last;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return null;
  return _kLanguageByExtension[fileName.substring(dot + 1).toLowerCase()];
}

class FileViewerScreen extends StatelessWidget {
  final String path;
  final FileContent content;
  const FileViewerScreen({
    super.key,
    required this.path,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = path.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName),
        actions: [
          IconButton(
            tooltip: 'Show full path',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(path)));
            },
          ),
        ],
      ),
      body: content.isBinary
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Binary file, ${content.bytes.length} bytes\n\n'
                  'Preview is not supported in this view.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            )
          : _TextBody(path: path, bytes: content.bytes),
    );
  }
}

class _TextBody extends StatelessWidget {
  final String path;
  final List<int> bytes;
  const _TextBody({required this.path, required this.bytes});

  @override
  Widget build(BuildContext context) {
    // `allowMalformed: true` papers over a partial UTF-8 truncation at the
    // file's tail (rare but legitimate, e.g. a large file clipped at
    // MAX_FILE_BYTES mid-codepoint) instead of throwing.
    final text = utf8.decode(bytes, allowMalformed: true);
    final language = _languageForPath(path);

    if (language == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(text, style: _kCodeTextStyle),
      );
    }

    // `HighlightView` renders into a non-selectable `RichText`; wrapping in
    // `SelectionArea` re-introduces long-press selection + clipboard copy.
    return SingleChildScrollView(
      child: SelectionArea(
        child: HighlightView(
          text,
          language: language,
          theme: monokaiSublimeTheme,
          padding: const EdgeInsets.all(12),
          textStyle: _kCodeTextStyle,
        ),
      ),
    );
  }
}
