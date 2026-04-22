class TerminalCursor {
  const TerminalCursor({
    required this.row,
    required this.column,
    this.visible = true,
  });

  final int row;
  final int column;
  final bool visible;

  TerminalCursor copyWith({int? row, int? column, bool? visible}) {
    return TerminalCursor(
      row: row ?? this.row,
      column: column ?? this.column,
      visible: visible ?? this.visible,
    );
  }
}

class TerminalSavedCursor {
  int row = 0;
  int column = 0;
  bool visible = true;
}
