// Smoke test: the app builds and shows the Backends-screen empty state
// when SharedPreferences are empty.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobilecode/main.dart';

void main() {
  testWidgets('first run shows backends empty state', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MobileCodeApp(enableSystemTray: false));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('Backends'), findsOneWidget);
    expect(find.text('No backends yet'), findsOneWidget);
    expect(find.text('Add your first backend'), findsOneWidget);
  });
}
