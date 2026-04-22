import 'terminal_cursor.dart';
import 'terminal_line.dart';

class TerminalSnapshot {
  const TerminalSnapshot({
    required this.rows,
    required this.cols,
    required this.cursor,
    required this.lines,
    required this.displayLines,
    required this.dirtyRows,
    required this.scrollbackLength,
    required this.viewportOffset,
    required this.isAlternateBuffer,
    required this.applicationCursorKeys,
  });

  final int rows;
  final int cols;
  final TerminalCursor cursor;
  final List<TerminalLine> lines;
  final List<TerminalLine> displayLines;
  final Set<int> dirtyRows;
  final int scrollbackLength;
  final int viewportOffset;
  final bool isAlternateBuffer;
  final bool applicationCursorKeys;

  String get plainText => displayLines
      .map((line) => line.toDisplayString(trimRight: true))
      .join('\n');
}
