import 'package:flutter/material.dart';

class UnifiedDiffView extends StatelessWidget {
  final String diff;
  final bool isConflict;
  final String emptyLabel;

  const UnifiedDiffView({
    super.key,
    required this.diff,
    this.isConflict = false,
    this.emptyLabel = 'No diff available for this file',
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lines = diff.split('\n');

    if (diff.trim().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isConflict
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                size: 64,
                color: isConflict ? colorScheme.error : colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                emptyLabel,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (isConflict)
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
                    style: TextStyle(color: colorScheme.onErrorContainer),
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
                    children: lines
                        .map(
                          (line) =>
                              _DiffLine(text: line, colorScheme: colorScheme),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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
