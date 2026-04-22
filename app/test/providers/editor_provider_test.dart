import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/editor_context.dart';
import 'package:vscode_mobile/models/editor_models.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';

import '../test_support/editor_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFileApiClient fileApi;
  late FakeEditorApiClient editorApi;
  late EditorProvider provider;

  setUp(() async {
    final settings = await createTestSettings();
    fileApi = FakeFileApiClient(
      settings: settings,
      seedFiles: <String, String>{
        '/workspace/lib/main.dart': 'foo();\n',
        '/workspace/lib/helper.dart': 'foo();\n',
      },
    );
    editorApi = FakeEditorApiClient(
      settings: settings,
      seedDocuments: <String, String>{
        '/workspace/lib/main.dart': 'foo();\n',
        '/workspace/lib/helper.dart': 'foo();\n',
      },
    );
    provider = EditorProvider(apiClient: fileApi, editorApiClient: editorApi);
    await settleAsync();
  });

  tearDown(() async {
    provider.dispose();
    await editorApi.disposeFakes();
  });

  test(
    'tracks bridge-backed open, change, save, and close lifecycle',
    () async {
      await provider.openFile('/workspace/lib/main.dart');
      await settleAsync();

      expect(provider.currentFile?.bridgeTracking, isTrue);
      expect(provider.currentFile?.version, 1);
      expect(
        editorApi.lifecycleCalls.map(
          (Map<String, dynamic> call) => call['method'],
        ),
        contains('doc/open'),
      );

      provider.updateCursor(const EditorCursor(line: 1, column: 1));
      provider.updateContent('bar();\n');
      await settleAsync();

      expect(provider.currentFile?.hasUnsavedChanges, isTrue);
      expect(
        editorApi.lifecycleCalls.map(
          (Map<String, dynamic> call) => call['method'],
        ),
        contains('doc/change'),
      );

      final saved = await provider.saveCurrentFile();
      expect(saved, isTrue);
      expect(provider.currentFile?.hasUnsavedChanges, isFalse);
      expect(
        editorApi.lifecycleCalls.map(
          (Map<String, dynamic> call) => call['method'],
        ),
        contains('doc/save'),
      );

      final closed = await provider.closeFile(0);
      expect(closed, isTrue);
      expect(provider.openFiles, isEmpty);
      expect(
        editorApi.lifecycleCalls.map(
          (Map<String, dynamic> call) => call['method'],
        ),
        contains('doc/close'),
      );
    },
  );

  test(
    'applies completion edits and workspace edits across open files',
    () async {
      await provider.openFile('/workspace/lib/main.dart');
      await settleAsync();

      provider.updateCursor(const EditorCursor(line: 1, column: 4));
      final completionApplied = await provider.applyCompletionItem(
        completionItem(
          label: 'print',
          primaryEdit: textEdit(
            startLine: 0,
            startCharacter: 0,
            endLine: 0,
            endCharacter: 5,
            newText: 'print()',
          ),
          additionalTextEdits: <EditorTextEdit>[
            textEdit(
              startLine: 0,
              startCharacter: 0,
              endLine: 0,
              endCharacter: 0,
              newText: '// generated\n',
            ),
          ],
        ),
      );
      await settleAsync();

      expect(completionApplied, isTrue);
      expect(provider.currentFile?.currentContent, '// generated\nprint();\n');

      final workspaceApplied = await provider.applyWorkspaceEdit(
        const EditorWorkspaceEdit(
          changes: <String, List<EditorTextEdit>>{
            '/workspace/lib/main.dart': <EditorTextEdit>[
              EditorTextEdit(
                range: DocumentRange(
                  start: DocumentPosition(line: 1, character: 0),
                  end: DocumentPosition(line: 1, character: 5),
                ),
                newText: 'log()',
              ),
            ],
            '/workspace/lib/helper.dart': <EditorTextEdit>[
              EditorTextEdit(
                range: DocumentRange(
                  start: DocumentPosition(line: 0, character: 0),
                  end: DocumentPosition(line: 0, character: 3),
                ),
                newText: 'log',
              ),
            ],
          },
        ),
      );
      await settleAsync();

      expect(workspaceApplied, isTrue);
      final helper = provider.openFiles.firstWhere(
        (OpenFile file) => file.path == '/workspace/lib/helper.dart',
      );
      expect(helper.currentContent, 'log();\n');
    },
  );

  test(
    'applies formatting, quick fix, and rename workspace edits from bridge',
    () async {
      await provider.openFile('/workspace/lib/main.dart');
      await settleAsync();

      editorApi.formattingResponse = <EditorTextEdit>[
        textEdit(
          startLine: 0,
          startCharacter: 0,
          endLine: 0,
          endCharacter: 6,
          newText: 'print();',
        ),
      ];

      final formatted = await provider.formatCurrentFile();
      await settleAsync();

      expect(formatted, isTrue);
      expect(provider.currentFile?.currentContent, 'print();\n');

      editorApi.codeActionsResponse = <EditorCodeAction>[
        EditorCodeAction(
          title: 'Apply quick fix',
          kind: 'quickfix',
          edit: const EditorWorkspaceEdit(
            changes: <String, List<EditorTextEdit>>{
              '/workspace/lib/main.dart': <EditorTextEdit>[
                EditorTextEdit(
                  range: DocumentRange(
                    start: DocumentPosition(line: 0, character: 0),
                    end: DocumentPosition(line: 0, character: 5),
                  ),
                  newText: 'fixed',
                ),
              ],
            },
          ),
          raw: const <String, dynamic>{'title': 'Apply quick fix'},
        ),
      ];

      final actions = await provider.loadCodeActions(quickFixOnly: true);
      expect(actions, hasLength(1));

      final quickFixed = await provider.applyCodeAction(actions.single);
      await settleAsync();

      expect(quickFixed, isTrue);
      expect(provider.currentFile?.currentContent, 'fixed();\n');

      editorApi.renameResponse = const EditorWorkspaceEdit(
        changes: <String, List<EditorTextEdit>>{
          '/workspace/lib/main.dart': <EditorTextEdit>[
            EditorTextEdit(
              range: DocumentRange(
                start: DocumentPosition(line: 0, character: 0),
                end: DocumentPosition(line: 0, character: 5),
              ),
              newText: 'renamed',
            ),
          ],
          '/workspace/lib/helper.dart': <EditorTextEdit>[
            EditorTextEdit(
              range: DocumentRange(
                start: DocumentPosition(line: 0, character: 0),
                end: DocumentPosition(line: 0, character: 3),
              ),
              newText: 'renamed',
            ),
          ],
        },
      );

      provider.updateCursor(const EditorCursor(line: 1, column: 2));
      final renamed = await provider.renameSymbol('renamed');
      await settleAsync();

      expect(renamed, isTrue);
      expect(provider.currentFile?.currentContent, 'renamed();\n');

      final helper = provider.openFiles.firstWhere(
        (OpenFile file) => file.path == '/workspace/lib/helper.dart',
      );
      expect(helper.currentContent, 'renamed();\n');
      expect(helper.version, greaterThanOrEqualTo(2));
    },
  );

  test(
    'records jump history and jumps back to the previous location',
    () async {
      await provider.openFileAt('/workspace/lib/main.dart', line: 1);
      await provider.openFileAt('/workspace/lib/helper.dart', line: 1);
      await settleAsync();

      expect(provider.currentFile?.path, '/workspace/lib/helper.dart');
      expect(provider.canJumpBack, isTrue);

      final jumped = await provider.jumpBack();
      await settleAsync();

      expect(jumped, isTrue);
      expect(provider.currentFile?.path, '/workspace/lib/main.dart');
      expect(provider.revealSelection?.start.line, 1);
    },
  );

  test(
    'gates unavailable capabilities and refreshes diagnostics from bridge events',
    () async {
      editorApi.capabilitiesDocument = defaultCapabilities(
        overrides: <String, dynamic>{
          'completion': <String, dynamic>{'enabled': false},
        },
      );
      await provider.refreshCapabilities();
      await provider.openFile('/workspace/lib/main.dart');
      await settleAsync();

      final completions = await provider.requestCompletion();
      expect(completions, isEmpty);
      expect(provider.error, contains('Completion'));

      editorApi.eventsChannel.serverSendJson(<String, dynamic>{
        'type': 'document/diagnosticsChanged',
        'payload': <String, dynamic>{
          'file': '/workspace/lib/main.dart',
          'diagnostics': <Map<String, dynamic>>[
            <String, dynamic>{
              'range': <String, dynamic>{
                'start': <String, dynamic>{'line': 2, 'character': 1},
                'end': <String, dynamic>{'line': 2, 'character': 5},
              },
              'severity': 2,
              'message': 'unused value',
              'source': 'dart',
            },
          ],
        },
      });
      await settleAsync();

      expect(provider.diagnostics, hasLength(1));
      expect(provider.diagnostics.single.message, 'unused value');
      expect(provider.diagnostics.single.severity, 'warning');
    },
  );
}
