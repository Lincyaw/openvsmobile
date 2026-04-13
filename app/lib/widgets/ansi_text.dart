import 'package:flutter/material.dart';

/// Standard xterm-256 color palette for the 16 basic colors.
class _AnsiColors {
  // Dark theme colors (standard xterm)
  static const List<Color> darkForeground = [
    Color(0xFF000000), // 0 - Black
    Color(0xFFCD0000), // 1 - Red
    Color(0xFF00CD00), // 2 - Green
    Color(0xFFCDCD00), // 3 - Yellow
    Color(0xFF0000EE), // 4 - Blue
    Color(0xFFCD00CD), // 5 - Magenta
    Color(0xFF00CDCD), // 6 - Cyan
    Color(0xFFE5E5E5), // 7 - White
    // Bright variants
    Color(0xFF7F7F7F), // 8 - Bright Black (Gray)
    Color(0xFFFF0000), // 9 - Bright Red
    Color(0xFF00FF00), // 10 - Bright Green
    Color(0xFFFFFF00), // 11 - Bright Yellow
    Color(0xFF5C5CFF), // 12 - Bright Blue
    Color(0xFFFF00FF), // 13 - Bright Magenta
    Color(0xFF00FFFF), // 14 - Bright Cyan
    Color(0xFFFFFFFF), // 15 - Bright White
  ];

  // Light theme colors (slightly adjusted for readability on light bg)
  static const List<Color> lightForeground = [
    Color(0xFF000000), // 0 - Black
    Color(0xFFAA0000), // 1 - Red
    Color(0xFF00AA00), // 2 - Green
    Color(0xFFAA5500), // 3 - Yellow/Brown
    Color(0xFF0000AA), // 4 - Blue
    Color(0xFFAA00AA), // 5 - Magenta
    Color(0xFF00AAAA), // 6 - Cyan
    Color(0xFFAAAAAA), // 7 - White
    // Bright variants
    Color(0xFF555555), // 8 - Bright Black
    Color(0xFFFF5555), // 9 - Bright Red
    Color(0xFF55FF55), // 10 - Bright Green
    Color(0xFFFFFF55), // 11 - Bright Yellow
    Color(0xFF5555FF), // 12 - Bright Blue
    Color(0xFFFF55FF), // 13 - Bright Magenta
    Color(0xFF55FFFF), // 14 - Bright Cyan
    Color(0xFFFFFFFF), // 15 - Bright White
  ];

  /// Convert a 256-color index to a Color.
  static Color from256(int index) {
    if (index < 16) {
      return darkForeground[index];
    }
    if (index < 232) {
      // 6x6x6 color cube: index 16-231
      final n = index - 16;
      final b = (n % 6) * 51;
      final g = ((n ~/ 6) % 6) * 51;
      final r = (n ~/ 36) * 51;
      return Color.fromARGB(255, r, g, b);
    }
    // Grayscale ramp: index 232-255 -> 8, 18, ..., 238
    final gray = 8 + (index - 232) * 10;
    return Color.fromARGB(255, gray, gray, gray);
  }
}

/// A single styled text segment produced by the ANSI parser.
class _AnsiSegment {
  final String text;
  final Color? foreground;
  final Color? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;

  const _AnsiSegment({
    required this.text,
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
  });
}

/// Tracks current SGR state while parsing.
class _SgrState {
  Color? foreground;
  Color? background;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;

  void reset() {
    foreground = null;
    background = null;
    bold = false;
    dim = false;
    italic = false;
    underline = false;
  }

  _AnsiSegment toSegment(String text) {
    return _AnsiSegment(
      text: text,
      foreground: foreground,
      background: background,
      bold: bold,
      dim: dim,
      italic: italic,
      underline: underline,
    );
  }
}

/// Parse raw text containing ANSI escape sequences into styled segments.
///
/// Handles SGR sequences (\x1B[...m) and strips other escape sequences.
/// Gracefully handles incomplete sequences at the end of input by returning
/// them as the remainder (useful for chunked output).
class _AnsiParser {
  /// Parses [input] and returns a list of styled segments.
  ///
  /// [remainder] from a previous call can be prepended to handle split
  /// escape sequences across chunks.
  static (List<_AnsiSegment>, String) parse(
    String input, {
    _SgrState? state,
    List<Color> palette = _AnsiColors.darkForeground,
  }) {
    state ??= _SgrState();
    final segments = <_AnsiSegment>[];
    final textBuf = StringBuffer();
    int i = 0;

    while (i < input.length) {
      if (input.codeUnitAt(i) == 0x1B) {
        // Check if we have enough characters to determine the escape type.
        if (i + 1 >= input.length) {
          // Incomplete escape at end of input — return as remainder.
          if (textBuf.isNotEmpty) {
            segments.add(state.toSegment(textBuf.toString()));
            textBuf.clear();
          }
          return (segments, input.substring(i));
        }

        final next = input.codeUnitAt(i + 1);

        if (next == 0x5B) {
          // CSI sequence: \x1B[ ... <letter>
          // Find the terminating byte (0x40-0x7E).
          int j = i + 2;
          while (j < input.length) {
            final c = input.codeUnitAt(j);
            if (c >= 0x40 && c <= 0x7E) break;
            j++;
          }
          if (j >= input.length) {
            // Incomplete CSI sequence — return as remainder.
            if (textBuf.isNotEmpty) {
              segments.add(state.toSegment(textBuf.toString()));
              textBuf.clear();
            }
            return (segments, input.substring(i));
          }

          final terminator = input.codeUnitAt(j);
          if (terminator == 0x6D) {
            // 'm' — SGR sequence
            final params = input.substring(i + 2, j);
            if (textBuf.isNotEmpty) {
              segments.add(state.toSegment(textBuf.toString()));
              textBuf.clear();
            }
            _applySgr(state, params, palette);
          }
          // For non-SGR CSI sequences, just skip them.
          i = j + 1;
        } else if (next == 0x5D) {
          // OSC sequence: \x1B] ... \x07 or \x1B\\
          int j = i + 2;
          while (j < input.length) {
            if (input.codeUnitAt(j) == 0x07) break;
            if (j + 1 < input.length &&
                input.codeUnitAt(j) == 0x1B &&
                input.codeUnitAt(j + 1) == 0x5C) {
              j++; // skip past the backslash too
              break;
            }
            j++;
          }
          if (j >= input.length) {
            // Incomplete OSC — return as remainder.
            if (textBuf.isNotEmpty) {
              segments.add(state.toSegment(textBuf.toString()));
              textBuf.clear();
            }
            return (segments, input.substring(i));
          }
          i = j + 1;
        } else if (next == 0x28 || next == 0x29) {
          // Charset designation: \x1B( or \x1B), skip next char.
          i += 3;
          if (i > input.length) i = input.length;
        } else {
          // Other two-byte escape — skip.
          i += 2;
        }
      } else {
        textBuf.writeCharCode(input.codeUnitAt(i));
        i++;
      }
    }

    if (textBuf.isNotEmpty) {
      segments.add(state.toSegment(textBuf.toString()));
    }

    return (segments, '');
  }

  /// Apply SGR parameters to the current state.
  static void _applySgr(_SgrState state, String params, List<Color> palette) {
    if (params.isEmpty) {
      state.reset();
      return;
    }

    final parts = params.split(';');
    int idx = 0;

    while (idx < parts.length) {
      final code = int.tryParse(parts[idx]) ?? 0;

      switch (code) {
        case 0:
          state.reset();
        case 1:
          state.bold = true;
        case 2:
          state.dim = true;
        case 3:
          state.italic = true;
        case 4:
          state.underline = true;
        case 22:
          state.bold = false;
          state.dim = false;
        case 23:
          state.italic = false;
        case 24:
          state.underline = false;
        case 39:
          state.foreground = null;
        case 49:
          state.background = null;
        case 38:
          // Extended foreground color.
          if (idx + 1 < parts.length) {
            final mode = int.tryParse(parts[idx + 1]) ?? 0;
            if (mode == 5 && idx + 2 < parts.length) {
              final colorIdx = int.tryParse(parts[idx + 2]) ?? 0;
              state.foreground = _AnsiColors.from256(colorIdx);
              idx += 2;
            }
          }
        case 48:
          // Extended background color.
          if (idx + 1 < parts.length) {
            final mode = int.tryParse(parts[idx + 1]) ?? 0;
            if (mode == 5 && idx + 2 < parts.length) {
              final colorIdx = int.tryParse(parts[idx + 2]) ?? 0;
              state.background = _AnsiColors.from256(colorIdx);
              idx += 2;
            }
          }
        default:
          if (code >= 30 && code <= 37) {
            state.foreground = palette[code - 30];
          } else if (code >= 40 && code <= 47) {
            state.background = palette[code - 40];
          } else if (code >= 90 && code <= 97) {
            state.foreground = palette[code - 90 + 8];
          } else if (code >= 100 && code <= 107) {
            state.background = palette[code - 100 + 8];
          }
      }
      idx++;
    }
  }
}

/// A widget that renders text containing ANSI escape sequences with proper
/// colors and styling. Replaces SelectableText for terminal output.
class AnsiText extends StatelessWidget {
  final String rawText;
  final double fontSize;
  final double lineHeight;
  final Color defaultForeground;
  final Color? defaultBackground;

  const AnsiText(
    this.rawText, {
    super.key,
    this.fontSize = 13,
    this.lineHeight = 1.4,
    this.defaultForeground = const Color(0xFFD4D4D4),
    this.defaultBackground,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark
        ? _AnsiColors.darkForeground
        : _AnsiColors.lightForeground;
    final state = _SgrState();
    final (segments, _) = _AnsiParser.parse(
      rawText,
      state: state,
      palette: palette,
    );

    if (segments.isEmpty) {
      return const SizedBox.shrink();
    }

    final spans = <TextSpan>[];
    for (final seg in segments) {
      if (seg.text.isEmpty) continue;

      final color = seg.foreground ?? defaultForeground;
      final bgColor = seg.background ?? defaultBackground;

      spans.add(
        TextSpan(
          text: seg.text,
          style: TextStyle(
            color: seg.dim ? color.withValues(alpha: 0.5) : color,
            backgroundColor: bgColor,
            fontWeight: seg.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: seg.italic ? FontStyle.italic : FontStyle.normal,
            decoration: seg.underline
                ? TextDecoration.underline
                : TextDecoration.none,
          ),
        ),
      );
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          height: lineHeight,
          color: defaultForeground,
        ),
        children: spans,
      ),
    );
  }
}
