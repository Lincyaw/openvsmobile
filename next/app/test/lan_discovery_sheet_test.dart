import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/screens/lan_discovery_sheet.dart';
import 'package:mobilecode/services/mdns_discovery.dart';

void main() {
  testWidgets('shows scanning state initially', (tester) async {
    final pendingScan = Completer<List<DiscoveredBackend>>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LanDiscoverySheet(
            onAdd: (_, {required bool makeActive}) {},
            scanBackends: () => pendingScan.future,
          ),
        ),
      ),
    );
    // Should show the sheet title and a spinner while scanning.
    expect(find.text('Discovered backends'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows empty state after scan completes with no results', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LanDiscoverySheet(
            onAdd: (_, {required bool makeActive}) {},
            scanBackends: () async => const <DiscoveredBackend>[],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No backends found'), findsOneWidget);
    expect(
      find.text(
        'Make sure your backend is running and connected to the same WiFi network.',
      ),
      findsOneWidget,
    );
  });
}
