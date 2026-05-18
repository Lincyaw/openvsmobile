// Centralised `ThemeData` for the app. Owns the seed colour, AppBar
// title / icon roles, and the IconTheme default size so every screen
// inherits the same chrome treatment without each `AppBar` declaring
// its own `titleTextStyle`. Token values are pulled from `AppTokens`
// (see app_tokens.dart) — this file is the wiring, not the source of
// truth for numbers.

import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  const AppTheme._();

  static ThemeData light() {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    );
    return base.copyWith(
      iconTheme: base.iconTheme.copyWith(size: AppIconSize.md),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.textTheme.titleLarge,
        iconTheme: base.iconTheme.copyWith(size: AppIconSize.md),
        actionsIconTheme: base.iconTheme.copyWith(size: AppIconSize.md),
      ),
    );
  }
}
