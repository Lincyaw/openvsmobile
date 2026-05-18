// In-house syntax-highlight palette for `flutter_highlight`.
//
// Shape mirrors highlight.js theme maps (keys are token classes; values are
// `TextStyle` fragments merged onto the base `textStyle` passed to
// `HighlightView`). The `root` entry intentionally has no `backgroundColor`
// so the surface beneath shows through and the viewer stays consistent
// with the rest of the app chrome.
//
// All accents are picked to sit calmly on `AppColors.surface`: the brand
// green is reserved for keywords (and held to a desaturated tint so a
// keyword-dense file does not turn into a green wall), strings ride a warm
// amber, numbers/symbols ride a cool VSCode-ish cyan, functions a soft
// blue, and comments are the same dim grey the app already uses for
// secondary text.

import 'package:flutter/painting.dart';

import 'app_tokens.dart';

const Color _keywordGreen = Color(0xFF9BD9A6);
const Color _stringAmber = Color(0xFFE6C76A);
const Color _numberCyan = Color(0xFF9CDCFE);
const Color _functionBlue = Color(0xFF82AAFF);
const Color _typeTeal = Color(0xFFB5E5C2);
const Color _attrLilac = Color(0xFFC9A8E8);
const Color _punctuationDim = Color(0xFFBFC4CB);

final Map<String, TextStyle> appHighlightTheme = {
  'root': const TextStyle(color: AppColors.onSurface),

  'keyword': const TextStyle(color: _keywordGreen),
  'selector-tag': const TextStyle(color: _keywordGreen),
  'built_in': const TextStyle(color: _keywordGreen),
  'builtin-name': const TextStyle(color: _keywordGreen),
  'literal': const TextStyle(color: _keywordGreen),

  'type': const TextStyle(color: _typeTeal),
  'class': const TextStyle(color: _typeTeal),
  'title': const TextStyle(color: _functionBlue),
  'function': const TextStyle(color: _functionBlue),
  'section': const TextStyle(color: _functionBlue),

  'string': const TextStyle(color: _stringAmber),
  'regexp': const TextStyle(color: _stringAmber),
  'template-variable': const TextStyle(color: _stringAmber),
  'addition': const TextStyle(color: _stringAmber),

  'number': const TextStyle(color: _numberCyan),
  'symbol': const TextStyle(color: _numberCyan),
  'bullet': const TextStyle(color: _numberCyan),
  'quote': const TextStyle(color: _numberCyan),
  'link': const TextStyle(color: _numberCyan),

  'attr': const TextStyle(color: _attrLilac),
  'attribute': const TextStyle(color: _attrLilac),
  'name': const TextStyle(color: _attrLilac),
  'selector-class': const TextStyle(color: _attrLilac),
  'selector-id': const TextStyle(color: _attrLilac),
  'selector-attr': const TextStyle(color: _attrLilac),
  'selector-pseudo': const TextStyle(color: _attrLilac),
  'tag': const TextStyle(color: _attrLilac),

  'variable': const TextStyle(color: AppColors.onSurface),
  'params': const TextStyle(color: AppColors.onSurface),
  'subst': const TextStyle(color: AppColors.onSurface),
  'punctuation': const TextStyle(color: _punctuationDim),
  'operator': const TextStyle(color: _punctuationDim),

  'comment': const TextStyle(
    color: AppColors.onSurfaceVariant,
    fontStyle: FontStyle.italic,
  ),
  'deletion': const TextStyle(color: AppColors.onSurfaceVariant),

  'meta': const TextStyle(color: AppColors.onSurfaceVariant),
  'meta-keyword': const TextStyle(color: _keywordGreen),
  'meta-string': const TextStyle(color: _stringAmber),

  'strong': const TextStyle(
    color: AppColors.onSurface,
    fontWeight: FontWeight.bold,
  ),
  'emphasis': const TextStyle(
    color: AppColors.onSurface,
    fontStyle: FontStyle.italic,
  ),
};
