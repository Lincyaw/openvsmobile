import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:vscode_mobile/models/search_result.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/providers/search_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';
import 'package:vscode_mobile/screens/code_screen.dart';
import 'package:vscode_mobile/screens/search_screen.dart';

import '../test_support/editor_test_helpers.dart';

Future<
  ({
    FakeFileApiClient fileApi,
    FakeEditorApiClient editorApi,
    EditorProvider editorProvider,
    SearchProvider searchProvider,
    WorkspaceProvider workspaceProvider,
  })
>
_createSearchHarness() async {
  final settings = await createTestSettings();
  final fileApi = FakeFileApiClient(
    settings: settings,
    seedFiles: <String, String>{
      '/workspace/lib/main.dart': 'line 1\nneedle match\nline 3\n',
      '/workspace/lib/other.dart': 'other file\n',
    },
    seedFileSearchResults: <Map<String, dynamic>>[
      <String, dynamic>{
        'path': '/workspace/lib/main.dart',
        'name': 'main.dart',
        'isDir': false,
      },
    ],
    seedContentSearchResults: const <ContentSearchResult>[
      ContentSearchResult(
        file: '/workspace/lib/main.dart',
        line: 2,
        content: 'needle match',
      ),
    ],
  );
  final editorApi = FakeEditorApiClient(
    settings: settings,
    seedDocuments: <String, String>{
      '/workspace/lib/main.dart': 'line 1\nneedle match\nline 3\n',
      '/workspace/lib/other.dart': 'other file\n',
    },
  );
  final workspaceProvider = WorkspaceProvider();
  await workspaceProvider.setWorkspace('/workspace');
  final editorProvider = EditorProvider(
    apiClient: fileApi,
    editorApiClient: editorApi,
  );
  final searchProvider = SearchProvider(apiClient: fileApi);
  return (
    fileApi: fileApi,
    editorApi: editorApi,
    editorProvider: editorProvider,
    searchProvider: searchProvider,
    workspaceProvider: workspaceProvider,
  );
}

Widget _buildScreen({
  required EditorProvider editorProvider,
  required SearchProvider searchProvider,
  required WorkspaceProvider workspaceProvider,
}) {
  return wrapWithMaterialApp(
    providers: <SingleChildWidget>[
      ChangeNotifierProvider<EditorProvider>.value(value: editorProvider),
      ChangeNotifierProvider<SearchProvider>.value(value: searchProvider),
      ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaceProvider),
    ],
    child: const SearchScreen(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'tapping a file search result opens the file in the code screen',
    (WidgetTester tester) async {
      final setup = await _createSearchHarness();
      addTearDown(() async {
        await disposeEditorHarness(
          setup.editorProvider,
          setup.editorApi,
          tester,
        );
      });

      await setup.searchProvider.search('main', '/workspace');
      await tester.pumpWidget(
        _buildScreen(
          editorProvider: setup.editorProvider,
          searchProvider: setup.searchProvider,
          workspaceProvider: setup.workspaceProvider,
        ),
      );
      await pumpEditorUi(tester);

      expect(find.text('main.dart'), findsOneWidget);

      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('main.dart'),
              matching: find.byType(ListTile),
            ),
          )
          .onTap!
          .call();
      await pumpEditorUi(tester);

      expect(find.byType(CodeScreen), findsOneWidget);
      expect(
        setup.editorProvider.currentFile?.path,
        '/workspace/lib/main.dart',
      );
      expect(setup.editorProvider.selection, isNull);
      expect(setup.editorProvider.cursor?.line, 1);

      Navigator.of(tester.element(find.byType(CodeScreen))).pop();
      await pumpEditorUi(tester);
    },
  );

  testWidgets('tapping a content result opens and locates the matching line', (
    WidgetTester tester,
  ) async {
    final setup = await _createSearchHarness();
    addTearDown(() async {
      await disposeEditorHarness(setup.editorProvider, setup.editorApi, tester);
    });

    await setup.editorProvider.openFile('/workspace/lib/other.dart');

    setup.searchProvider.setSearchMode(SearchMode.fileContent);
    await setup.searchProvider.searchContent('needle', '/workspace');
    await tester.pumpWidget(
      _buildScreen(
        editorProvider: setup.editorProvider,
        searchProvider: setup.searchProvider,
        workspaceProvider: setup.workspaceProvider,
      ),
    );
    await pumpEditorUi(tester);

    expect(find.text('main.dart:2'), findsOneWidget);

    tester
        .widget<ListTile>(
          find.ancestor(
            of: find.text('main.dart:2'),
            matching: find.byType(ListTile),
          ),
        )
        .onTap!
        .call();
    await pumpEditorUi(tester);

    expect(find.byType(CodeScreen), findsOneWidget);
    expect(setup.editorProvider.currentFile?.path, '/workspace/lib/main.dart');
    expect(setup.editorProvider.selection?.start.line, 2);
    expect(setup.editorProvider.selection?.end.line, 2);
    expect(setup.editorProvider.revealSelection?.start.line, 2);
    expect(setup.editorProvider.cursor?.line, 2);
    expect(setup.editorProvider.canJumpBack, isTrue);

    final jumped = await setup.editorProvider.jumpBack();
    await pumpEditorUi(tester);

    expect(jumped, isTrue);
    expect(setup.editorProvider.currentFile?.path, '/workspace/lib/other.dart');

    Navigator.of(tester.element(find.byType(CodeScreen))).pop();
    await pumpEditorUi(tester);
  });
}
