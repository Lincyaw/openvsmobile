// Smoke test: the app builds and shows the first-run settings screen when
// SharedPreferences are empty.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobilecode/main.dart';

void main() {
  testWidgets('first run shows settings prompt',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MobileCodeApp());
    // Initial frame is the splash; pump until settings prompt appears.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('Connect to backend'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(find.text('Save'), findsOneWidget);
  });
}
