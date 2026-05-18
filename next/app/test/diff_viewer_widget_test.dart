// Widget tests for the DiffViewerScreen. Issue #55 acceptance:
//   * Hunks render with the right line markers + content.
//   * `isBinary: true` short-circuits to the placeholder.
//   * `tooLarge: true` short-circuits to the placeholder.
//
// The diff RPC is injected via the `diffOverride` test seam on
// DiffViewerScreen — production wires it to `AppState.gitDiff`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/diff_viewer.dart';

Future<void> _pumpDiff(
  WidgetTester tester,
  AppState appState,
  Map<String, dynamic> response,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: DiffViewerScreen(
        appState: appState,
        workspaceId: 'ws-1',
        path: 'lib/foo.dart',
        diffOverride: ({required workspaceId, required path}) async => response,
      ),
    ),
  );
  // Allow the initState future to resolve and the FutureBuilder to rebuild.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'hunks render with +/- markers and per-line content',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      await _pumpDiff(tester, appState, {
        'baseSha': 'aaaa',
        'headSha': 'bbbb',
        'isBinary': false,
        'hunks': [
          {
            'oldStart': 1,
            'oldLines': 2,
            'newStart': 1,
            'newLines': 3,
            'lines': [
              {'kind': 'context', 'text': 'unchanged 1'},
              {'kind': 'del', 'text': 'removed line'},
              {'kind': 'add', 'text': 'added line A'},
              {'kind': 'add', 'text': 'added line B'},
            ],
          },
        ],
      });

      // Header shows the path and the +/- counts (computed off the hunks).
      expect(find.text('foo.dart'), findsOneWidget); // AppBar title
      expect(find.text('lib/foo.dart'), findsOneWidget); // header path
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(find.text('vs HEAD'), findsOneWidget);

      // Hunk header rendered with the standard `@@ -a,b +c,d @@` shape.
      expect(find.textContaining('@@ -1,2 +1,3 @@'), findsOneWidget);

      // Line contents (rendered as SelectableText inside the row).
      expect(find.text('unchanged 1'), findsOneWidget);
      expect(find.text('removed line'), findsOneWidget);
      expect(find.text('added line A'), findsOneWidget);
      expect(find.text('added line B'), findsOneWidget);

      // Marker column shows the right glyph for each line kind. The marker
      // column reuses a SizedBox so finding by exact text on a single char
      // can match multiple cells — assert at least one of each appeared.
      expect(find.text('+'), findsWidgets);
      expect(find.text('-'), findsWidgets);

      // No placeholders.
      expect(find.text('Binary file — diff not shown.'), findsNothing);
      expect(find.text('Diff exceeds the 500 KB cap. View in terminal.'),
          findsNothing);
    },
  );

  testWidgets(
    'isBinary: true renders the binary placeholder, not hunks',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      await _pumpDiff(tester, appState, {
        'baseSha': 'aaaa',
        'headSha': 'bbbb',
        'isBinary': true,
        // Even if hunks were somehow present, the binary flag wins. The
        // backend never emits both, but the client must be defensive.
        'hunks': const [],
      });

      expect(find.text('Binary file — diff not shown.'), findsOneWidget);
      // No hunk header should be visible.
      expect(find.textContaining('@@'), findsNothing);
    },
  );

  testWidgets(
    'tooLarge: true renders the oversize placeholder',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      await _pumpDiff(tester, appState, {
        'baseSha': 'aaaa',
        'headSha': 'bbbb',
        'isBinary': false,
        'tooLarge': true,
        'hunks': const [],
      });

      expect(
        find.text('Diff exceeds the 500 KB cap. View in terminal.'),
        findsOneWidget,
      );
      expect(find.textContaining('@@'), findsNothing);
    },
  );

  testWidgets(
    'empty hunks list with no flags renders the "no changes" placeholder',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      await _pumpDiff(tester, appState, {
        'baseSha': 'aaaa',
        'headSha': 'bbbb',
        'isBinary': false,
        'hunks': const [],
      });
      expect(find.text('No changes vs HEAD.'), findsOneWidget);
    },
  );
}
