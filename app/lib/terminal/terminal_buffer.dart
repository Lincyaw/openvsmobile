import 'terminal_cell.dart';
import 'terminal_cursor.dart';
import 'terminal_line.dart';
import 'terminal_snapshot.dart';
import 'terminal_style.dart';

class TerminalBuffer {
  TerminalBuffer({
    required int rows,
    required int cols,
    this.scrollbackLimit = 10000,
    this.enableScrollback = true,
  }) : _rows = rows,
       _cols = cols,
       _lines = List<TerminalLine>.generate(
         rows,
         (_) => TerminalLine.blank(cols),
       ) {
    _scrollBottom = rows - 1;
  }

  int _rows;
  int _cols;
  final int scrollbackLimit;
  final bool enableScrollback;
  final List<TerminalLine> _lines;
  final List<TerminalLine> _scrollback = <TerminalLine>[];
  final Set<int> _dirtyRows = <int>{};

  int _cursorRow = 0;
  int _cursorCol = 0;
  int _scrollTop = 0;
  int _scrollBottom = 0;
  bool _cursorVisible = true;
  bool autoWrap = true;

  int get rows => _rows;
  int get cols => _cols;
  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;
  int get scrollbackLength => _scrollback.length;
  bool get hasScrollback => enableScrollback;

  TerminalCursor get cursor => TerminalCursor(
    row: _cursorRow,
    column: _cursorCol,
    visible: _cursorVisible,
  );

  void setCursorVisibility(bool visible) {
    _cursorVisible = visible;
  }

  void markAllDirty() {
    for (int row = 0; row < _rows; row++) {
      _dirtyRows.add(row);
    }
  }

  void clearDirtyRows() {
    _dirtyRows.clear();
  }

  Set<int> dirtyRowsSnapshot() => Set<int>.from(_dirtyRows);

  void reset() {
    _scrollback.clear();
    _lines
      ..clear()
      ..addAll(
        List<TerminalLine>.generate(_rows, (_) => TerminalLine.blank(_cols)),
      );
    _cursorRow = 0;
    _cursorCol = 0;
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _cursorVisible = true;
    autoWrap = true;
    markAllDirty();
  }

  void resize(int rows, int cols) {
    if (rows == _rows && cols == _cols) {
      return;
    }

    final oldRows = _rows;
    final oldCols = _cols;
    final oldLines = List<TerminalLine>.from(_lines);
    final oldScrollback = List<TerminalLine>.from(_scrollback);

    _rows = rows;
    _cols = cols;
    _lines.clear();

    final neededVisible = rows;
    final visibleSource = <TerminalLine>[...oldScrollback, ...oldLines];
    final start = visibleSource.length > neededVisible
        ? visibleSource.length - neededVisible
        : 0;
    final selected = visibleSource.sublist(start);

    if (enableScrollback && start > 0) {
      _scrollback
        ..clear()
        ..addAll(
          visibleSource.take(start).map((line) => _resizeLine(line, cols)),
        );
      if (_scrollback.length > scrollbackLimit) {
        _scrollback.removeRange(0, _scrollback.length - scrollbackLimit);
      }
    } else {
      _scrollback.clear();
    }

    for (final line in selected) {
      _lines.add(_resizeLine(line, cols));
    }
    while (_lines.length < rows) {
      _lines.add(TerminalLine.blank(cols));
    }

    _cursorRow = _cursorRow.clamp(0, rows - 1);
    _cursorCol = _cursorCol.clamp(0, cols - 1);
    _scrollTop = 0;
    _scrollBottom = rows - 1;
    markAllDirty();

    if (oldRows != rows || oldCols != cols) {
      _normalizeWideCells();
    }
  }

  void carriageReturn() {
    _cursorCol = 0;
  }

  void lineFeed() {
    if (_cursorRow == _scrollBottom) {
      scrollUp(1);
      return;
    }
    _cursorRow = (_cursorRow + 1).clamp(0, _rows - 1);
  }

  void reverseIndex() {
    if (_cursorRow == _scrollTop) {
      scrollDown(1);
      return;
    }
    _cursorRow = (_cursorRow - 1).clamp(0, _rows - 1);
  }

  void backspace() {
    if (_cursorCol > 0) {
      _cursorCol -= 1;
    }
  }

  void tab() {
    final nextTabStop = ((_cursorCol ~/ 8) + 1) * 8;
    final target = nextTabStop.clamp(0, _cols - 1);
    while (_cursorCol < target) {
      putChar(' ', const TerminalStyle());
    }
  }

  void moveCursor({int? row, int? col}) {
    if (row != null) {
      _cursorRow = row.clamp(0, _rows - 1);
    }
    if (col != null) {
      _cursorCol = col.clamp(0, _cols - 1);
    }
  }

  void moveCursorRelative({int rowDelta = 0, int colDelta = 0}) {
    moveCursor(row: _cursorRow + rowDelta, col: _cursorCol + colDelta);
  }

  void saveCursor(TerminalSavedCursor slot) {
    slot.row = _cursorRow;
    slot.column = _cursorCol;
    slot.visible = _cursorVisible;
  }

  void restoreCursor(TerminalSavedCursor slot) {
    _cursorRow = slot.row.clamp(0, _rows - 1);
    _cursorCol = slot.column.clamp(0, _cols - 1);
    _cursorVisible = slot.visible;
  }

  void setScrollRegion(int? top, int? bottom) {
    if (top == null || bottom == null || top >= bottom) {
      _scrollTop = 0;
      _scrollBottom = _rows - 1;
    } else {
      _scrollTop = top.clamp(0, _rows - 1);
      _scrollBottom = bottom.clamp(0, _rows - 1);
    }
    moveCursor(row: 0, col: 0);
  }

  void putChar(String grapheme, TerminalStyle style, {int width = 1}) {
    if (grapheme.isEmpty || width <= 0) {
      return;
    }

    final effectiveWidth = width > 1 ? 2 : 1;
    if (_cursorCol >= _cols) {
      if (!autoWrap) {
        _cursorCol = _cols - 1;
      } else {
        carriageReturn();
        lineFeed();
      }
    }
    if (effectiveWidth == 2 && _cursorCol == _cols - 1) {
      if (!autoWrap) {
        return;
      }
      carriageReturn();
      lineFeed();
    }

    _clearWideOverlap(_cursorRow, _cursorCol);
    _setCell(
      _cursorRow,
      _cursorCol,
      TerminalCell(text: grapheme, style: style, width: effectiveWidth),
    );
    if (effectiveWidth == 2 && _cursorCol + 1 < _cols) {
      _setCell(_cursorRow, _cursorCol + 1, TerminalCell.placeholder);
    }
    _cursorCol += effectiveWidth;
  }

  void appendCombiningMark(String grapheme) {
    final targetCol = _cursorCol > 0 ? _cursorCol - 1 : 0;
    final line = _lines[_cursorRow];
    final cell = line[targetCol];
    if (cell.isPlaceholder) {
      return;
    }
    line[targetCol] = cell.copyWith(text: '${cell.text}$grapheme');
    _dirtyRows.add(_cursorRow);
  }

  void clearScreen([int mode = 0]) {
    switch (mode) {
      case 0:
        clearLine(0);
        for (int row = _cursorRow + 1; row < _rows; row++) {
          _lines[row].clearRange(0, _cols);
          _dirtyRows.add(row);
        }
        break;
      case 1:
        for (int row = 0; row < _cursorRow; row++) {
          _lines[row].clearRange(0, _cols);
          _dirtyRows.add(row);
        }
        clearLine(1);
        break;
      default:
        for (int row = 0; row < _rows; row++) {
          _lines[row].clearRange(0, _cols);
          _dirtyRows.add(row);
        }
        break;
    }
  }

  void clearLine([int mode = 0]) {
    final line = _lines[_cursorRow];
    switch (mode) {
      case 0:
        line.clearRange(_cursorCol, _cols);
        break;
      case 1:
        line.clearRange(0, _cursorCol + 1);
        break;
      default:
        line.clearRange(0, _cols);
        break;
    }
    _dirtyRows.add(_cursorRow);
  }

  void insertLines(int count) {
    if (_cursorRow < _scrollTop || _cursorRow > _scrollBottom || count <= 0) {
      return;
    }
    final effectiveCount = count.clamp(0, _scrollBottom - _cursorRow + 1);
    for (int row = _scrollBottom; row >= _cursorRow + effectiveCount; row--) {
      _lines[row] = _lines[row - effectiveCount];
      _dirtyRows.add(row);
    }
    for (int row = _cursorRow; row < _cursorRow + effectiveCount; row++) {
      _lines[row] = TerminalLine.blank(_cols);
      _dirtyRows.add(row);
    }
  }

  void deleteLines(int count) {
    if (_cursorRow < _scrollTop || _cursorRow > _scrollBottom || count <= 0) {
      return;
    }
    final effectiveCount = count.clamp(0, _scrollBottom - _cursorRow + 1);
    for (int row = _cursorRow; row <= _scrollBottom - effectiveCount; row++) {
      _lines[row] = _lines[row + effectiveCount];
      _dirtyRows.add(row);
    }
    for (
      int row = _scrollBottom - effectiveCount + 1;
      row <= _scrollBottom;
      row++
    ) {
      _lines[row] = TerminalLine.blank(_cols);
      _dirtyRows.add(row);
    }
  }

  void insertChars(int count) {
    final line = _lines[_cursorRow];
    line.insertBlanks(_cursorCol, count);
    _normalizeLine(_cursorRow);
    _dirtyRows.add(_cursorRow);
  }

  void deleteChars(int count) {
    final line = _lines[_cursorRow];
    line.deleteCells(_cursorCol, count);
    _normalizeLine(_cursorRow);
    _dirtyRows.add(_cursorRow);
  }

  void eraseChars(int count) {
    if (count <= 0) {
      return;
    }
    final line = _lines[_cursorRow];
    final end = (_cursorCol + count).clamp(0, _cols);
    line.clearRange(_cursorCol, end);
    _normalizeLine(_cursorRow);
    _dirtyRows.add(_cursorRow);
  }

  void scrollUp(int count) {
    final effectiveCount = count.clamp(0, _scrollBottom - _scrollTop + 1);
    for (int i = 0; i < effectiveCount; i++) {
      final removed = _lines.removeAt(_scrollTop);
      if (enableScrollback && _scrollTop == 0 && _scrollBottom == _rows - 1) {
        _scrollback.add(removed.clone());
        if (_scrollback.length > scrollbackLimit) {
          _scrollback.removeAt(0);
        }
      }
      _lines.insert(_scrollBottom, TerminalLine.blank(_cols));
    }
    for (int row = _scrollTop; row <= _scrollBottom; row++) {
      _dirtyRows.add(row);
    }
  }

  void scrollDown(int count) {
    final effectiveCount = count.clamp(0, _scrollBottom - _scrollTop + 1);
    for (int i = 0; i < effectiveCount; i++) {
      _lines.removeAt(_scrollBottom);
      _lines.insert(_scrollTop, TerminalLine.blank(_cols));
    }
    for (int row = _scrollTop; row <= _scrollBottom; row++) {
      _dirtyRows.add(row);
    }
  }

  TerminalSnapshot snapshot({
    bool isAlternateBuffer = false,
    bool applicationCursorKeys = false,
    int viewportOffset = 0,
    bool clearDirtyRows = false,
  }) {
    final visibleLines = _lines
        .map((line) => line.clone())
        .toList(growable: false);
    final displayLines = enableScrollback
        ? <TerminalLine>[
            ..._scrollback.map((line) => line.clone()),
            ...visibleLines.map((line) => line.clone()),
          ]
        : visibleLines.map((line) => line.clone()).toList(growable: false);
    final snapshot = TerminalSnapshot(
      rows: _rows,
      cols: _cols,
      cursor: cursor,
      lines: visibleLines,
      displayLines: displayLines,
      dirtyRows: dirtyRowsSnapshot(),
      scrollbackLength: _scrollback.length,
      viewportOffset: viewportOffset,
      isAlternateBuffer: isAlternateBuffer,
      applicationCursorKeys: applicationCursorKeys,
    );
    if (clearDirtyRows) {
      _dirtyRows.clear();
    }
    return snapshot;
  }

  String backlogText() {
    final lines = <String>[
      ..._scrollback.map((line) => line.toDisplayString(trimRight: true)),
      ..._lines.map((line) => line.toDisplayString(trimRight: true)),
    ];
    return lines.join('\n');
  }

  TerminalLine _resizeLine(TerminalLine line, int cols) {
    final resized = TerminalLine.blank(cols);
    final limit = cols < line.length ? cols : line.length;
    for (int i = 0; i < limit; i++) {
      resized[i] = line[i];
    }
    return resized;
  }

  void _setCell(int row, int col, TerminalCell cell) {
    _lines[row][col] = cell;
    _dirtyRows.add(row);
  }

  void _clearWideOverlap(int row, int col) {
    final line = _lines[row];
    final current = line[col];
    if (current.isPlaceholder && col > 0) {
      line[col - 1] = TerminalCell.blank;
    }
    if (!current.isPlaceholder && current.width == 2 && col + 1 < _cols) {
      line[col + 1] = TerminalCell.blank;
    }
    if (col > 0) {
      final previous = line[col - 1];
      if (!previous.isPlaceholder && previous.width == 2) {
        line[col - 1] = TerminalCell.blank;
      }
    }
  }

  void _normalizeWideCells() {
    for (int row = 0; row < _rows; row++) {
      _normalizeLine(row);
    }
  }

  void _normalizeLine(int row) {
    final line = _lines[row];
    for (int col = 0; col < _cols; col++) {
      final cell = line[col];
      if (cell.isPlaceholder) {
        if (col == 0 || line[col - 1].width != 2) {
          line[col] = TerminalCell.blank;
        }
        continue;
      }
      if (cell.width == 2) {
        if (col == _cols - 1) {
          line[col] = TerminalCell.blank;
        } else {
          line[col + 1] = TerminalCell.placeholder;
        }
      }
    }
    _dirtyRows.add(row);
  }
}
