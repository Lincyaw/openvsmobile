// Read-only file viewer. Monospace, no syntax highlighting in v0.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../models.dart';

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
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _decode(content.bytes),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
    );
  }

  String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
