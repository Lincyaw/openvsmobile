// Smoke-level coverage for the read-only file viewer. The intent is to
// catch dependency / wiring regressions in the syntax-highlight path —
// asserting specific token colours is out of scope.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/screens/file_viewer.dart';
import 'package:mobilecode/state/plugins_model.dart';
import 'package:mobilecode/ui/app_tokens.dart';
import 'package:mobilecode/ui/highlight_theme.dart';

FileContent _text(String source) =>
    FileContent(bytes: utf8.encode(source), isBinary: false);

Future<void> _pumpViewer(
  WidgetTester tester, {
  required String path,
  required FileContent content,
  ThemeData? theme,
  AppState? appState,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FileViewerScreen(path: path, content: content, appState: appState),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders a .dart snippet through the highlight pipeline', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      path: 'lib/sample.dart',
      content: _text("void main() {\n  print('hello');\n}\n"),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(find.text('sample.dart'), findsOneWidget);

    final highlight = tester.widget<HighlightView>(find.byType(HighlightView));
    // The default `MaterialApp` has no `darkTheme` wired in this harness
    // so the brightness resolves to light; the helper should return the
    // matching map.
    expect(highlight.theme, same(appHighlightThemeLight));
    expect(highlight.language, 'dart');
  });

  testWidgets('highlighted files use the dark theme background in dark mode', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      path: 'lib/sample.dart',
      content: _text("void main() {\n  print('hello');\n}\n"),
      theme: ThemeData(brightness: Brightness.dark),
    );
    expect(tester.takeException(), isNull);

    final highlight = tester.widget<HighlightView>(find.byType(HighlightView));
    expect(highlight.theme, same(appHighlightThemeDark));
    expect(highlight.theme['root']?.backgroundColor, AppColors.surface);
  });

  testWidgets('unknown extension falls back to plain SelectableText', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      path: 'notes/random.unknownext',
      content: _text('hello world'),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('text viewer shows line numbers and find-in-file summary', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      path: 'lib/sample.dart',
      content: _text("void main() {\n  print('hello');\n}\n"),
    );

    expect(
      find.byKey(const ValueKey<String>('file-line-number:1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('file-line-number:2')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('file-search-toggle')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('file-search-field')),
      'print',
    );
    await tester.pumpAndSettle();

    expect(find.text('1 of 1 · line 2'), findsOneWidget);
  });

  testWidgets('binary content still shows the byte-count placeholder', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      path: 'assets/blob.bin',
      content: const FileContent(bytes: [0, 1, 2, 3], isBinary: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Binary file, 4 bytes'), findsOneWidget);
  });

  testWidgets(
    'extensionless known filename routes through highlight pipeline',
    (tester) async {
      await _pumpViewer(
        tester,
        path: 'Makefile',
        content: _text('all:\n\techo hi\n'),
      );
      expect(tester.takeException(), isNull);
      final highlight = tester.widget<HighlightView>(
        find.byType(HighlightView),
      );
      expect(highlight.language, 'makefile');
    },
  );

  testWidgets('files larger than the highlight threshold fall back to plain', (
    tester,
  ) async {
    final bigSource = 'void f() {}\n' * 20000;
    await _pumpViewer(tester, path: 'lib/huge.dart', content: _text(bigSource));
    expect(tester.takeException(), isNull);
    expect(find.byType(HighlightView), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('plugin command receives structured file selection context', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.debugSetActiveWorkspace(
      const Workspace(id: 'ws-1', root: '/repo', label: 'repo', createdAt: 0),
    );
    appState.plugins.debugSeed([
      const PluginInfo(
        id: 'p',
        name: 'Plugin',
        version: '1.0.0',
        state: PluginWireState.running,
        crashReason: null,
        panels: [],
        commands: [PluginCommandStub(id: 'p.act', title: 'Act')],
      ),
    ]);
    Map<String, dynamic>? rpcParams;
    appState.plugins.debugRpcOverride = (method, params) async {
      if (method == 'plugin.invokeCommand') rpcParams = params;
      return <String, dynamic>{'ok': true};
    };

    await _pumpViewer(
      tester,
      path: '/repo/notes/random.unknownext',
      content: _text('hello world\nnext line'),
      appState: appState,
    );

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    selectable.onSelectionChanged!(
      const TextSelection(baseOffset: 6, extentOffset: 11),
      SelectionChangedCause.longPress,
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('selection-plugin-actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plugin: Act'));
    await tester.pumpAndSettle();

    expect(rpcParams?['id'], 'p');
    expect(rpcParams?['commandId'], 'p.act');
    final args = rpcParams?['args'] as Map<String, dynamic>;
    final selection = args['selection'] as Map<String, dynamic>;
    expect(selection['source'], 'file');
    expect(selection['workspaceId'], 'ws-1');
    expect(selection['workspaceRoot'], '/repo');
    expect(selection['path'], '/repo/notes/random.unknownext');
    expect(selection['relativePath'], 'notes/random.unknownext');
    expect(selection['text'], 'world');
    final range = selection['range'] as Map<String, dynamic>;
    expect(range['start'], {'line': 1, 'column': 7});
    expect(range['end'], {'line': 1, 'column': 12});
    expect(range['endExclusive'], isTrue);
  });
}
