import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/screens/terminal_detail.dart';

const _workspace = Workspace(
  id: 'ws-1',
  root: '/tmp/ws-1',
  label: 'ws-1',
  createdAt: 0,
);

const _session = TerminalSession(
  id: 'term-1',
  workspaceId: 'ws-1',
  cols: 80,
  rows: 24,
  cwd: '/tmp/ws-1',
  createdAt: 0,
);

Widget _wrap(AppState appState, String sessionId) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    ),
    home: TerminalDetailScreen(
      appState: appState,
      sessionId: sessionId,
      title: 'sh',
    ),
  );
}

void main() {
  testWidgets('terminal detail shows ended state after exit', (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.debugSetActiveWorkspace(_workspace);
    appState.debugSeedTerminals(_workspace.id, const [_session]);

    await tester.pumpWidget(_wrap(appState, _session.id));
    await tester.pump();

    expect(find.byType(TerminalSessionView), findsOneWidget);
    expect(find.text('Terminal session ended.'), findsNothing);

    appState.debugApplyTerminalExit(_session.id, workspaceId: _workspace.id);
    await tester.pump();

    expect(find.byType(TerminalSessionView), findsNothing);
    expect(find.text('Terminal session ended.'), findsOneWidget);
    expect(find.text('Back to sessions'), findsOneWidget);
  });

  testWidgets('unknown terminal id does not create a local terminal', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.debugSetActiveWorkspace(_workspace);

    await tester.pumpWidget(_wrap(appState, 'missing'));
    await tester.pump();

    expect(appState.terminalForIfKnown('missing'), isNull);
    expect(find.byType(TerminalSessionView), findsNothing);
    expect(find.text('Terminal session ended.'), findsOneWidget);
  });

  testWidgets('compact terminal detail truncates long app bar title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const session = TerminalSession(
      id: 'term-long-title',
      title: 'deploy shell with a very long title that must not overflow',
      workspaceId: 'ws-1',
      workspaceRoot: '/tmp/ws-1',
      cols: 80,
      rows: 24,
      cwd: '/tmp/ws-1',
      createdAt: 0,
      externalSessionId:
          'very-long-zellij-session-name-that-also-needs-ellipsis',
    );
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.debugSetActiveWorkspace(_workspace);
    appState.debugSeedTerminals(_workspace.id, const [session]);

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalDetailScreen(
          appState: appState,
          sessionId: session.id,
          title: session.title!,
          onOpenFiles: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text(session.title!), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('companion key taps emit selection haptic feedback', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalSessionView(terminal: terminal)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Ctrl'));
    await tester.pump();

    expect(
      calls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'HapticFeedback.vibrate')
            .having(
              (c) => c.arguments,
              'arguments',
              'HapticFeedbackType.selectionClick',
            ),
      ),
    );
  });

  testWidgets('compact companion bar keeps End visible and Kbd on second row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalSessionView(terminal: terminal)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final endRect = tester.getRect(find.text('End'));
    final kbdRect = tester.getRect(find.text('Kbd'));
    final selRect = tester.getRect(find.text('Sel'));

    expect(endRect.left, greaterThanOrEqualTo(0));
    expect(endRect.right, lessThanOrEqualTo(360));
    expect(kbdRect.top, greaterThan(endRect.top));
    expect(kbdRect.left, greaterThan(selRect.left));
  });
}
