import 'package:flutter/material.dart';

const List<String> kMonospaceFontFallback = <String>[
  'Roboto Mono',
  'Noto Sans Mono',
  'Noto Sans Mono CJK SC',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'PingFang SC',
  'Hiragino Sans GB',
  'Heiti SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'WenQuanYi Zen Hei',
  'Noto Color Emoji',
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'sans-serif',
];

TextStyle monospaceTextStyle({
  Color? color,
  Color? backgroundColor,
  double? fontSize,
  double? height,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  TextDecoration? decoration,
  String fontFamily = 'monospace',
}) {
  return TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: kMonospaceFontFallback,
    color: color,
    backgroundColor: backgroundColor,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    decoration: decoration,
  );
}

TextStyle withMonospaceFallback(TextStyle style, {String fontFamily = 'monospace'}) {
  final mergedFallback = <String>{
    ...?style.fontFamilyFallback,
    ...kMonospaceFontFallback,
  }.toList(growable: false);
  return style.copyWith(
    fontFamily: fontFamily,
    fontFamilyFallback: mergedFallback,
  );
}
