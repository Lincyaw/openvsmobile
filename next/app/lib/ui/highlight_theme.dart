// In-house syntax-highlight palette for `flutter_highlight`.
//
// Shape mirrors highlight.js theme maps (keys are token classes; values are
// `TextStyle` fragments merged onto the base `textStyle` passed to
// `HighlightView`). The `root` entry includes a background color because
// `flutter_highlight` falls back to white when it is absent.
//
// Two variants ship: [appHighlightThemeDark] is the dark default tuned for
// `AppColors.surface`; [appHighlightThemeLight] mirrors the same token
// vocabulary tuned for `AppColorsLight.surface`. The light palette
// follows the "Light Modern" idiom and is checked to keep ≥4.5:1
// contrast on a near-white background. Pick at render time via
// [highlightThemeForBrightness] so the viewer stays consistent with the
// active `ThemeData`.

import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

import 'app_tokens.dart';

// ---- Dark palette (default) ----

const Color _keywordGreen = Color(0xFF9BD9A6);
const Color _stringAmber = Color(0xFFE6C76A);
const Color _numberCyan = Color(0xFF9CDCFE);
const Color _functionBlue = Color(0xFF82AAFF);
const Color _typeTeal = Color(0xFFB5E5C2);
const Color _attrLilac = Color(0xFFC9A8E8);
const Color _punctuationDim = Color(0xFFBFC4CB);

final Map<String, TextStyle> appHighlightThemeDark = {
  'root': const TextStyle(
    color: AppColors.onSurface,
    backgroundColor: AppColors.surface,
  ),

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

// ---- Light palette ----
//
// Token → colour table follows the "Light Modern" idiom (white surface,
// dark tokens). Every accent below is picked to give ≥4.5:1 contrast
// against `AppColorsLight.surface` (#FAFAFB) so syntax stays legible
// without depending on the dark-mode token brightness budget.

const Color _lightKeywordPurple = Color(0xFF7E3FB8);
const Color _lightStringRed = Color(0xFFA31515);
const Color _lightNumberGreen = Color(0xFF066A47);
const Color _lightFunctionBrown = Color(0xFF795E26);
const Color _lightTypeTeal = Color(0xFF1E687F);
const Color _lightAttrRed = Color(0xFFE50000);
const Color _lightCommentGreen = Color(0xFF008000);
const Color _lightPunctuation = Color(0xFF3C4148);

final Map<String, TextStyle> appHighlightThemeLight = {
  'root': const TextStyle(
    color: AppColorsLight.onSurface,
    backgroundColor: AppColorsLight.surface,
  ),

  'keyword': const TextStyle(color: _lightKeywordPurple),
  'selector-tag': const TextStyle(color: _lightKeywordPurple),
  'built_in': const TextStyle(color: _lightKeywordPurple),
  'builtin-name': const TextStyle(color: _lightKeywordPurple),
  'literal': const TextStyle(color: _lightNumberGreen),

  'type': const TextStyle(color: _lightTypeTeal),
  'class': const TextStyle(color: _lightTypeTeal),
  'title': const TextStyle(color: _lightFunctionBrown),
  'function': const TextStyle(color: _lightFunctionBrown),
  'section': const TextStyle(color: _lightFunctionBrown),

  'string': const TextStyle(color: _lightStringRed),
  'regexp': const TextStyle(color: _lightStringRed),
  'template-variable': const TextStyle(color: _lightStringRed),
  'addition': const TextStyle(color: _lightStringRed),

  'number': const TextStyle(color: _lightNumberGreen),
  'symbol': const TextStyle(color: _lightNumberGreen),
  'bullet': const TextStyle(color: _lightNumberGreen),
  'quote': const TextStyle(color: _lightNumberGreen),
  'link': const TextStyle(color: _lightNumberGreen),

  'attr': const TextStyle(color: _lightAttrRed),
  'attribute': const TextStyle(color: _lightAttrRed),
  'name': const TextStyle(color: _lightAttrRed),
  'selector-class': const TextStyle(color: _lightAttrRed),
  'selector-id': const TextStyle(color: _lightAttrRed),
  'selector-attr': const TextStyle(color: _lightAttrRed),
  'selector-pseudo': const TextStyle(color: _lightAttrRed),
  'tag': const TextStyle(color: _lightAttrRed),

  'variable': const TextStyle(color: AppColorsLight.onSurface),
  'params': const TextStyle(color: AppColorsLight.onSurface),
  'subst': const TextStyle(color: AppColorsLight.onSurface),
  'punctuation': const TextStyle(color: _lightPunctuation),
  'operator': const TextStyle(color: _lightPunctuation),

  'comment': const TextStyle(
    color: _lightCommentGreen,
    fontStyle: FontStyle.italic,
  ),
  'deletion': const TextStyle(color: AppColorsLight.onSurfaceVariant),

  'meta': const TextStyle(color: AppColorsLight.onSurfaceVariant),
  'meta-keyword': const TextStyle(color: _lightKeywordPurple),
  'meta-string': const TextStyle(color: _lightStringRed),

  'strong': const TextStyle(
    color: AppColorsLight.onSurface,
    fontWeight: FontWeight.bold,
  ),
  'emphasis': const TextStyle(
    color: AppColorsLight.onSurface,
    fontStyle: FontStyle.italic,
  ),
};

/// Return the highlight theme matching [brightness]. Callers typically
/// pass `Theme.of(context).brightness` so the syntax viewer flips in
/// lockstep with the active `ThemeData`.
Map<String, TextStyle> highlightThemeForBrightness(Brightness brightness) =>
    switch (brightness) {
      Brightness.light => appHighlightThemeLight,
      Brightness.dark => appHighlightThemeDark,
    };
