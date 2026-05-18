// Read-only file viewer. Monospace, with syntax highlighting when the
// filename maps to a language the `highlight` package knows; plain
// monospace otherwise.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';

import '../models.dart';
import '../ui/app_tokens.dart';
import '../ui/highlight_theme.dart';

final _kCodeTextStyle = AppText.mono(fontSize: 13, height: 1.35);

/// Files larger than this render as plain monospace text. Highlighting is
/// synchronous and would block the UI thread for big files; pure
/// `SelectableText` stays smooth and keeps the surface usable.
const int _kHighlightMaxBytes = 200 * 1024;

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
  'env': 'properties',
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
    final tooLargeToHighlight = bytes.length > _kHighlightMaxBytes;

    if (language == null || tooLargeToHighlight) {
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
          theme: appHighlightTheme,
          padding: const EdgeInsets.all(12),
          textStyle: _kCodeTextStyle,
        ),
      ),
    );
  }
}
