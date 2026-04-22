class TerminalColor {
  const TerminalColor._({
    required this.kind,
    this.index,
    this.red,
    this.green,
    this.blue,
  });

  const TerminalColor.indexed(int index)
    : this._(kind: TerminalColorKind.indexed, index: index);

  const TerminalColor.rgb(int red, int green, int blue)
    : this._(kind: TerminalColorKind.rgb, red: red, green: green, blue: blue);

  final TerminalColorKind kind;
  final int? index;
  final int? red;
  final int? green;
  final int? blue;

  bool get isDefault => kind == TerminalColorKind.defaultColor;

  static const TerminalColor defaultColor = TerminalColor._(
    kind: TerminalColorKind.defaultColor,
  );

  @override
  bool operator ==(Object other) {
    return other is TerminalColor &&
        other.kind == kind &&
        other.index == index &&
        other.red == red &&
        other.green == green &&
        other.blue == blue;
  }

  @override
  int get hashCode => Object.hash(kind, index, red, green, blue);
}

enum TerminalColorKind { defaultColor, indexed, rgb }

class TerminalStyle {
  const TerminalStyle({
    this.foreground = TerminalColor.defaultColor,
    this.background = TerminalColor.defaultColor,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.inverse = false,
    this.strikethrough = false,
  });

  final TerminalColor foreground;
  final TerminalColor background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool inverse;
  final bool strikethrough;

  static const TerminalStyle reset = TerminalStyle();

  TerminalStyle copyWith({
    TerminalColor? foreground,
    TerminalColor? background,
    bool? bold,
    bool? dim,
    bool? italic,
    bool? underline,
    bool? inverse,
    bool? strikethrough,
  }) {
    return TerminalStyle(
      foreground: foreground ?? this.foreground,
      background: background ?? this.background,
      bold: bold ?? this.bold,
      dim: dim ?? this.dim,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      inverse: inverse ?? this.inverse,
      strikethrough: strikethrough ?? this.strikethrough,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalStyle &&
        other.foreground == foreground &&
        other.background == background &&
        other.bold == bold &&
        other.dim == dim &&
        other.italic == italic &&
        other.underline == underline &&
        other.inverse == inverse &&
        other.strikethrough == strikethrough;
  }

  @override
  int get hashCode => Object.hash(
    foreground,
    background,
    bold,
    dim,
    italic,
    underline,
    inverse,
    strikethrough,
  );
}
