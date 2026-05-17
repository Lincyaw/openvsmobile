// Widget tests for BackendsScreen — empty state and a single-entry list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/backends_screen.dart';
import 'package:mobilecode/settings_store.dart';

BackendTarget _target({
  String id = 'b1',
  String name = 'home',
  String host = 'h.local',
  int port = 7860,
  String token = 't',
}) =>
    BackendTarget(
      id: id,
      name: name,
      host: host,
      port: port,
      token: token,
      origin: BackendOrigin.manual,
      addedAt: 0,
    );

Future<void> _pump(WidgetTester tester, AppPersistedState state,
    {AppState? appState}) async {
  appState ??= AppState(client: BackendClient());
  await tester.pumpWidget(
    MaterialApp(
      home: BackendsScreen(
        state: state,
        appState: appState,
        onAdd: (_, {required bool makeActive}) async {},
        onUpdate: (_) async {},
        onDelete: (_) async {},
        onSwitch: (_) async {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders empty state with add CTA', (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    await _pump(tester, const AppPersistedState(), appState: appState);
    expect(find.text('No backends yet'), findsOneWidget);
    expect(find.text('Add your first backend'), findsOneWidget);
  });

  testWidgets('renders a single backend with host:port subtitle and menu',
      (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    final state = AppPersistedState(
      backends: [_target()],
      activeBackendId: 'b1',
    );
    await _pump(tester, state, appState: appState);
    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('h.local:7860'), findsOneWidget);
    // Active marker (filled circle) renders.
    expect(find.byIcon(Icons.circle), findsOneWidget);
    // PopupMenuButton is present.
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });
}
