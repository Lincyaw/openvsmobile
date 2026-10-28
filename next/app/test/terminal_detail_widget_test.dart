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

  testWidgets('compact companion bar fits both rows and the keyboard toggle', (
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

    // The test font draws every glyph full-width, so only the leading keys
    // of each row are guaranteed on-screen here; real fonts fit all five.
    final dpadLeft = tester.getRect(find.text('←')).left;
    for (final label in ['Esc', 'Ctrl', 'Alt', 'Home', 'End', 'PgUp']) {
      expect(tester.getRect(find.text(label)).right, lessThan(dpadLeft));
    }
    final toggle = tester.getRect(
      find.byKey(const ValueKey('terminal-keyboard-toggle')),
    );
    expect(toggle.right, lessThanOrEqualTo(360));
    expect(
      toggle.bottom,
      lessThanOrEqualTo(tester.getRect(find.text('←')).top),
    );
  });

  group('key bar input', () {
    late Terminal terminal;
    late List<String> captured;
    late List<String> textInputCalls;

    Future<void> mount(WidgetTester tester) async {
      terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      captured = <String>[];
      terminal.onOutput = captured.add;
      textInputCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, (call) async {
            textInputCalls.add(call.method);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.textInput, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TerminalSessionView(terminal: terminal)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      captured.clear();
      textInputCalls.clear();
    }

    testWidgets('key bar keys do not reopen the soft keyboard', (tester) async {
      await mount(tester);
      await tester.tap(find.text('PgUp'));
      await tester.tap(find.text('↓'));
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(captured, ['\x1b[5~', '\x1b[B']);
      expect(textInputCalls, isNot(contains('TextInput.show')));
    });

    testWidgets('sticky Ctrl survives terminal replies and applies to typing', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      // Primary device-attributes query: xterm answers through onOutput.
      terminal.write('\x1b[c');
      expect(captured, isNotEmpty);
      expect(captured.single.codeUnitAt(0), 0x1b);
      terminal.textInput('c');
      await tester.pump();
      expect(captured.last, '\x03');
      // Disarmed after one character.
      terminal.textInput('c');
      expect(captured.last, 'c');
    });

    testWidgets('sticky Alt prefixes ESC; Shift+Tab emits back-tab', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.text('Alt'));
      await tester.pump();
      terminal.textInput('n');
      expect(captured.last, '\x1bn');
      await tester.tap(find.text('⇧Tab'));
      await tester.pump();
      expect(captured.last, '\x1b[Z');
    });

    testWidgets('holding an arrow key auto-repeats', (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('←')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pump();
      final count = captured.length;
      expect(count, greaterThan(3));
      expect(captured.every((s) => s == '\x1bOD' || s == '\x1b[D'), isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(captured.length, count, reason: 'repeat must stop on lift');
    });
  });
}
