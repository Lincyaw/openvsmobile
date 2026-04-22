import 'terminal_cell.dart';

class TerminalLine {
  TerminalLine.blank(int cols)
    : _cells = List<TerminalCell>.filled(
        cols,
        TerminalCell.blank,
        growable: false,
      );

  TerminalLine.fromCells(List<TerminalCell> cells)
    : _cells = List<TerminalCell>.from(cells, growable: false);

  final List<TerminalCell> _cells;

  int get length => _cells.length;

  List<TerminalCell> get cells => List<TerminalCell>.unmodifiable(_cells);

  TerminalCell operator [](int index) => _cells[index];

  void operator []=(int index, TerminalCell value) {
    _cells[index] = value;
  }

  TerminalLine clone() => TerminalLine.fromCells(_cells);

  void clearRange(int start, int end) {
    for (int i = start; i < end; i++) {
      _cells[i] = TerminalCell.blank;
    }
  }

  void insertBlanks(int start, int count) {
    if (count <= 0 || start >= length) {
      return;
    }
    final effectiveCount = count.clamp(0, length - start);
    for (int i = length - 1; i >= start + effectiveCount; i--) {
      _cells[i] = _cells[i - effectiveCount];
    }
    for (int i = start; i < start + effectiveCount; i++) {
      _cells[i] = TerminalCell.blank;
    }
  }

  void deleteCells(int start, int count) {
    if (count <= 0 || start >= length) {
      return;
    }
    final effectiveCount = count.clamp(0, length - start);
    for (int i = start; i < length - effectiveCount; i++) {
      _cells[i] = _cells[i + effectiveCount];
    }
    for (int i = length - effectiveCount; i < length; i++) {
      _cells[i] = TerminalCell.blank;
    }
  }

  String toDisplayString({bool trimRight = false}) {
    final raw = _cells.map((cell) => cell.displayText).join();
    if (!trimRight) {
      return raw;
    }
    return raw.replaceFirst(RegExp(r'\s+$'), '');
  }
}
