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
                        return _DiffLine(
                          lineNumber: index + 1,
                          text: line,
                          colorScheme: colorScheme,
                        );
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
  final int lineNumber;
  final String text;
  final ColorScheme colorScheme;

  const _DiffLine({
    required this.lineNumber,
    required this.text,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    Color? backgroundColor;
    Color textColor = colorScheme.onSurface;

    if (text.startsWith('+')) {
      backgroundColor = Colors.green.withAlpha(40);
      textColor = Colors.green.shade300;
    } else if (text.startsWith('-')) {
      backgroundColor = Colors.red.withAlpha(40);
      textColor = Colors.red.shade300;
    } else if (text.startsWith('@@')) {
      backgroundColor = Colors.blue.withAlpha(40);
      textColor = Colors.blue.shade300;
    }

    return Container(
      color: backgroundColor,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 8),
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
