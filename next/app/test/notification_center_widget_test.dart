// Widget tests for the notification center + bell icon.
//
// Same pattern as files_tab_widget_test.dart: feed AppState through its
// push handlers (no WS), pump the widget, assert on the render.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/notification.dart';
import 'package:mobilecode/screens/notification_center.dart';

class _RecordingBackendClient extends BackendClient {
  final List<({String method, Map<String, dynamic>? params})> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    return <String, dynamic>{'ok': true};
  }
}

AppNotification _n({
  required String id,
  required String title,
  String source = 'demo',
  NotificationLevel level = NotificationLevel.info,
  int? ts,
  String? body,
}) =>
    AppNotification(
      id: id,
      source: source,
      level: level,
      title: title,
      body: body,
      timestamp: ts ?? DateTime.now().millisecondsSinceEpoch,
    );

Future<void> _pumpCenter(WidgetTester tester, AppState appState) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: NotificationCenterScreen(appState: appState),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows empty state when no notifications', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    await _pumpCenter(tester, appState);
    expect(find.text('No notifications yet'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
  });

  testWidgets('renders a card with source pill, title, body', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(_n(
      id: 'n1',
      title: 'Build green',
      source: 'ci:nightly',
      body: 'all 42 checks passed',
      level: NotificationLevel.success,
    ));
    await _pumpCenter(tester, appState);
    expect(find.text('Build green'), findsOneWidget);
    // Source string appears both in the pill on the card and in the
    // filter ChoiceChip row at the top — that's two widgets, both
    // intended. Asserting `findsNWidgets(2)` would be brittle if the row
    // layout changes; `findsAtLeastNWidgets(1)` captures the contract.
    expect(find.text('ci:nightly'), findsAtLeastNWidgets(1));
    // Body is collapsed by default.
    expect(find.text('all 42 checks passed'), findsNothing);
    // Tap to expand.
    await tester.tap(find.text('Build green'));
    await tester.pump();
    expect(find.text('all 42 checks passed'), findsOneWidget);
  });

  testWidgets('filter pill narrows the list', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(_n(id: '1', title: 'CI msg', source: 'ci'));
    appState.notifications.onShow(_n(id: '2', title: 'Claude msg', source: 'claude'));
    await _pumpCenter(tester, appState);
    expect(find.text('CI msg'), findsOneWidget);
    expect(find.text('Claude msg'), findsOneWidget);
    // Tap the 'ci' pill.
    await tester.tap(find.widgetWithText(ChoiceChip, 'ci'));
    await tester.pump();
    expect(find.text('CI msg'), findsOneWidget);
    expect(find.text('Claude msg'), findsNothing);
  });

  testWidgets('bell icon shows badge when unread > 0', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(_n(id: '1', title: 'first'));
    appState.notifications.onShow(_n(id: '2', title: 'second'));
    expect(appState.notifications.unreadCount, 2);

    // Render the bare bell + badge harness rather than HomeShell (which
    // would need a fully-wired SettingsStore). The badge widget itself is
    // what the assertion targets.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                icon: appState.notifications.unreadCount > 0
                    ? Badge.count(
                        count: appState.notifications.unreadCount,
                        child: const Icon(Icons.notifications_outlined),
                      )
                    : const Icon(Icons.notifications_outlined),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Badge), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('opening the center only marks rendered visible cards as read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);

    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 18; i++) {
      appState.notifications.onShow(_n(
        id: 'n$i',
        title: 'Notification $i',
        source: 'ci',
        ts: now - i,
        body: 'body $i',
      ));
    }

    await _pumpCenter(tester, appState);
    await tester.pump(const Duration(milliseconds: 650));

    final markReadCalls =
        client.calls.where((c) => c.method == 'notification.markRead').toList();
    expect(markReadCalls, isNotEmpty);
    final markedIds = <String>{
      for (final c in markReadCalls)
        ...((c.params?['ids'] as List?) ?? const []).whereType<String>(),
    };

    expect(markedIds, contains('n0'));
    expect(markedIds, isNot(contains('n17')));
    expect(appState.notifications.isRead('n0'), isTrue);
    expect(appState.notifications.isRead('n17'), isFalse);
  });
}
