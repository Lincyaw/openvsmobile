import 'package:flutter/material.dart';

/// Displays unified diff output with syntax coloring.
class DiffScreen extends StatelessWidget {
  final String fileName;
  final String diffContent;

  const DiffScreen({
    super.key,
    required this.fileName,
    required this.diffContent,
  });

  @override
  Widget build(BuildContext context) {
    final lines = diffContent.split('\n');
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(fileName, overflow: TextOverflow.ellipsis)),
      body: diffContent.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 64,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No changes',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: colorScheme.outline),
                  ),
                ],
              ),
            )
          : Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: List.generate(lines.length, (index) {
                        final line = lines[index];
                        return _DiffLine(text: line, colorScheme: colorScheme);
                      }),
                    ),
                  ),
                ),
              ),
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
