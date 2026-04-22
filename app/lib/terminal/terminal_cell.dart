import 'terminal_style.dart';

class TerminalCell {
  const TerminalCell({
    required this.text,
    this.style = TerminalStyle.reset,
    this.width = 1,
    this.isPlaceholder = false,
  });

  final String text;
  final TerminalStyle style;
  final int width;
  final bool isPlaceholder;

  static const TerminalCell blank = TerminalCell(text: ' ');
  static const TerminalCell placeholder = TerminalCell(
    text: '',
    width: 0,
    isPlaceholder: true,
  );

  String get displayText => isPlaceholder ? '' : text;

  TerminalCell copyWith({
    String? text,
    TerminalStyle? style,
    int? width,
    bool? isPlaceholder,
  }) {
    return TerminalCell(
      text: text ?? this.text,
      style: style ?? this.style,
      width: width ?? this.width,
      isPlaceholder: isPlaceholder ?? this.isPlaceholder,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalCell &&
        other.text == text &&
        other.style == style &&
        other.width == width &&
        other.isPlaceholder == isPlaceholder;
  }

  @override
  int get hashCode => Object.hash(text, style, width, isPlaceholder);
}
