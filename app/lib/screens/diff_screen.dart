import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/git_models.dart';
import '../providers/git_provider.dart';

class DiffScreen extends StatefulWidget {
  final String filePath;
  final bool staged;
  final bool isConflict;

  const DiffScreen({
    super.key,
    required this.filePath,
    required this.staged,
    this.isConflict = false,
  });

  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  late Future<GitDiffDocument> _diffFuture;

  @override
  void initState() {
    super.initState();
    _diffFuture = _loadDiff();
  }

  Future<GitDiffDocument> _loadDiff() {
    return context.read<GitProvider>().fetchDiff(
      widget.filePath,
      staged: widget.staged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filePath, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh diff',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _diffFuture = _loadDiff();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<GitDiffDocument>(
        future: _diffFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Failed to load diff',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() {
                          _diffFuture = _loadDiff();
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final diff = snapshot.data!;
          final lines = diff.diff.split('\n');

          if (diff.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.isConflict
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      size: 64,
                      color: widget.isConflict
                          ? colorScheme.error
                          : colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.isConflict
                          ? 'Open this file in the editor to resolve the conflict.'
                          : 'No diff available for this file',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return Column(
            children: [
              if (widget.isConflict)
                Container(
                  width: double.infinity,
                  color: colorScheme.errorContainer,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Conflict file: review both sides before staging a resolution.',
                          style: TextStyle(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: List.generate(lines.length, (index) {
                            final line = lines[index];
                            return _DiffLine(
                              text: line,
                              colorScheme: colorScheme,
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  final String text;
  final ColorScheme colorScheme;

  const _DiffLine({required this.text, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color? backgroundColor;
    Color textColor = colorScheme.onSurface;

    if (text.startsWith('+')) {
      backgroundColor = Colors.green.withAlpha(isDark ? 40 : 25);
      textColor = isDark ? Colors.green.shade300 : Colors.green.shade800;
    } else if (text.startsWith('-')) {
      backgroundColor = Colors.red.withAlpha(isDark ? 40 : 25);
      textColor = isDark ? Colors.red.shade300 : Colors.red.shade800;
    } else if (text.startsWith('@@')) {
      backgroundColor = Colors.blue.withAlpha(isDark ? 40 : 25);
      textColor = isDark ? Colors.blue.shade300 : Colors.blue.shade800;
    }

    return Container(
      color: backgroundColor,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
