import 'package:flutter/material.dart';

import '../theme/monospace_text.dart';
import '../terminal/terminal_cell.dart';
import '../terminal/terminal_line.dart';
import '../terminal/terminal_snapshot.dart';
import '../terminal/terminal_style.dart';

class TerminalRenderer extends StatelessWidget {
  const TerminalRenderer({
    super.key,
    required this.snapshot,
    required this.scrollController,
    required this.fontSize,
    required this.lineHeight,
    required this.defaultForeground,
    required this.defaultBackground,
    this.focused = false,
  });

  final TerminalSnapshot snapshot;
  final ScrollController scrollController;
  final double fontSize;
  final double lineHeight;
  final Color defaultForeground;
  final Color defaultBackground;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final displayLines = snapshot.displayLines;
    return ListView.builder(
      controller: scrollController,
      itemCount: displayLines.length,
      itemBuilder: (context, index) {
        final line = displayLines[index];
        return RepaintBoundary(
          child: SizedBox(
            height: fontSize * lineHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RichText(
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textHeightBehavior: const TextHeightBehavior(
                  applyHeightToFirstAscent: false,
                  applyHeightToLastDescent: false,
                ),
                text: TextSpan(
                  style: monospaceTextStyle(
                    fontSize: fontSize,
                    height: lineHeight,
                    color: defaultForeground,
                  ),
                  children: _buildLineSpans(index, line),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<InlineSpan> _buildLineSpans(int displayRow, TerminalLine line) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    TerminalStyle? activeStyle;

    void flush() {
      if (buffer.isEmpty || activeStyle == null) {
        return;
      }
      spans.add(
        TextSpan(text: buffer.toString(), style: _textStyle(activeStyle)),
      );
      buffer.clear();
    }

    for (int col = 0; col < line.length; col++) {
      final cell = line[col];
      if (cell.isPlaceholder) {
        continue;
      }
      final styledCell = _cursorAdjustedCell(displayRow, col, cell);
      if (activeStyle != styledCell.style) {
        flush();
        activeStyle = styledCell.style;
      }
      buffer.write(styledCell.displayText);
    }

    flush();
    if (spans.isEmpty) {
      spans.add(TextSpan(text: '', style: _textStyle(TerminalStyle.reset)));
    }
    return spans;
  }

  TerminalCell _cursorAdjustedCell(
    int displayRow,
    int column,
    TerminalCell cell,
  ) {
    if (!focused || !snapshot.cursor.visible) {
      return cell;
    }
    final cursorDisplayRow = snapshot.isAlternateBuffer
        ? snapshot.cursor.row
        : snapshot.displayLines.length - snapshot.rows + snapshot.cursor.row;
    if (displayRow != cursorDisplayRow || column != snapshot.cursor.column) {
      return cell;
    }
    final style = cell.style.copyWith(inverse: !cell.style.inverse);
    return cell.copyWith(style: style);
  }

  TextStyle _textStyle(TerminalStyle style) {
    final foreground = _resolveForeground(style);
    final background = _resolveBackground(style);
    return monospaceTextStyle(
      fontSize: fontSize,
      height: lineHeight,
      color: foreground,
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine(<TextDecoration>[
        if (style.underline) TextDecoration.underline,
        if (style.strikethrough) TextDecoration.lineThrough,
      ]),
    );
  }

  Color _resolveForeground(TerminalStyle style) {
    final baseForeground = _resolveColor(style.foreground, defaultForeground);
    final baseBackground = _resolveColor(style.background, defaultBackground);
    return style.inverse ? baseBackground : baseForeground;
  }

  Color _resolveBackground(TerminalStyle style) {
    final baseForeground = _resolveColor(style.foreground, defaultForeground);
    final baseBackground = _resolveColor(style.background, defaultBackground);
    return style.inverse ? baseForeground : baseBackground;
  }

  Color _resolveColor(TerminalColor color, Color fallback) {
    switch (color.kind) {
      case TerminalColorKind.defaultColor:
        return fallback;
      case TerminalColorKind.indexed:
        return _indexedColor(color.index ?? 0);
      case TerminalColorKind.rgb:
        return Color.fromARGB(
          0xFF,
          color.red ?? 0,
          color.green ?? 0,
          color.blue ?? 0,
        );
    }
  }

  Color _indexedColor(int index) {
    final palette =
        ThemeData.estimateBrightnessForColor(defaultBackground) ==
            Brightness.dark
        ? _darkPalette
        : _lightPalette;
    if (index < 16) {
      return palette[index];
    }
    if (index < 232) {
      final n = index - 16;
      final blue = (n % 6) * 51;
      final green = ((n ~/ 6) % 6) * 51;
      final red = (n ~/ 36) * 51;
      return Color.fromARGB(0xFF, red, green, blue);
    }
    final gray = 8 + (index - 232) * 10;
    return Color.fromARGB(0xFF, gray, gray, gray);
  }
}

const List<Color> _darkPalette = <Color>[
  Color(0xFF000000),
  Color(0xFFCD0000),
  Color(0xFF00CD00),
  Color(0xFFCDCD00),
  Color(0xFF0000EE),
  Color(0xFFCD00CD),
  Color(0xFF00CDCD),
  Color(0xFFE5E5E5),
  Color(0xFF7F7F7F),
  Color(0xFFFF0000),
  Color(0xFF00FF00),
  Color(0xFFFFFF00),
  Color(0xFF5C5CFF),
  Color(0xFFFF00FF),
  Color(0xFF00FFFF),
  Color(0xFFFFFFFF),
];

const List<Color> _lightPalette = <Color>[
  Color(0xFF000000),
  Color(0xFFAA0000),
  Color(0xFF00AA00),
  Color(0xFFAA5500),
  Color(0xFF0000AA),
  Color(0xFFAA00AA),
  Color(0xFF00AAAA),
  Color(0xFFAAAAAA),
  Color(0xFF555555),
  Color(0xFFFF5555),
  Color(0xFF55FF55),
  Color(0xFFFFFF55),
  Color(0xFF5555FF),
  Color(0xFFFF55FF),
  Color(0xFF55FFFF),
  Color(0xFFFFFFFF),
];
