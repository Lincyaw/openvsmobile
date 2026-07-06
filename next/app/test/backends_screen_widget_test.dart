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
}) => BackendTarget(
  id: id,
  name: name,
  host: host,
  port: port,
  token: token,
  origin: BackendOrigin.manual,
  addedAt: 0,
);

Future<void> _pump(
  WidgetTester tester,
  AppPersistedState state, {
  AppState? appState,
  Future<bool> Function()? onExport,
  Future<int?> Function()? onImport,
  Future<void> Function(String)? onSwitch,
}) async {
  appState ??= AppState(client: BackendClient());
  await tester.pumpWidget(
    MaterialApp(
      home: BackendsScreen(
        state: state,
        appState: appState,
        onAdd: (_, {required bool makeActive}) async {},
        onUpdate: (_) async {},
        onDelete: (_) async {},
        onSwitch: onSwitch ?? (_) async {},
        onExport: onExport ?? () async => true,
        onImport: onImport ?? () async => 1,
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

  testWidgets('renders active backend as the Files/Plugins target', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    final state = AppPersistedState(
      backends: [_target()],
      activeBackendId: 'b1',
    );
    await _pump(tester, state, appState: appState);
    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('h.local:7860'), findsOneWidget);
    expect(find.textContaining('Files/Plugins target'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    // PopupMenuButton is present.
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });

  testWidgets('switching workspace target is explicit in the row menu', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    String? switched;
    final state = AppPersistedState(
      backends: [
        _target(id: 'b1', name: 'home'),
        _target(id: 'b2', name: 'work', host: 'work.local'),
      ],
      activeBackendId: 'b1',
    );
    await _pump(
      tester,
      state,
      appState: appState,
      onSwitch: (id) async => switched = id,
    );

    await tester.tap(find.text('work'));
    await tester.pump();
    expect(switched, isNull);

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use for Files/Plugins'));
    await tester.pumpAndSettle();

    expect(switched, 'b2');
  });

  testWidgets('exports backend backup from the overflow menu', (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    var exported = false;
    final state = AppPersistedState(
      backends: [_target()],
      activeBackendId: 'b1',
    );
    await _pump(
      tester,
      state,
      appState: appState,
      onExport: () async {
        exported = true;
        return true;
      },
    );

    await tester.tap(find.byTooltip('Backend backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bearer tokens'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(exported, isTrue);
    expect(find.text('Backend backup saved'), findsOneWidget);
  });

  testWidgets('imports backend backup from the empty state', (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    var imported = false;
    await _pump(
      tester,
      const AppPersistedState(),
      appState: appState,
      onImport: () async {
        imported = true;
        return 2;
      },
    );

    await tester.tap(find.byTooltip('Backend backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();

    expect(imported, isTrue);
    expect(find.text('Imported 2 backends'), findsOneWidget);
  });
}
