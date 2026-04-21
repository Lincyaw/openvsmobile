import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vscode_mobile/models/diagnostic.dart';
import 'package:vscode_mobile/models/editor_models.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/editor_api_client.dart';

import '../test_support/editor_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fetches bridge capabilities with typed protocol metadata', () async {
    final settings = await createTestSettings();
    final client = EditorApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/bridge/capabilities');
        expect(request.headers['Authorization'], 'Bearer dev-token');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'state': 'ready',
            'generation': 'gen-editor',
            'protocolVersion': '2026-04-20',
            'bridgeVersion': '0.3.0',
            'capabilities': <String, dynamic>{
              'completion': <String, dynamic>{
                'enabled': true,
                'textEdit': true,
              },
              'rename': <String, dynamic>{'enabled': false},
            },
          }),
          200,
        );
      }),
    );

    final document = await client.getCapabilities();

    expect(document.state, 'ready');
    expect(document.generation, 'gen-editor');
    expect(document.protocolVersion, '2026-04-20');
    expect(document.bridgeVersion, '0.3.0');
    expect(document.isEnabled('completion'), isTrue);
    expect(document.capabilities['completion']?.raw['textEdit'], isTrue);
    expect(document.isEnabled('rename'), isFalse);
  });

  test('sends versioned document lifecycle payloads to the bridge', () async {
    final settings = await createTestSettings();
    var requestIndex = 0;
    final client = EditorApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;

        switch (requestIndex++) {
          case 0:
            expect(request.method, 'POST');
            expect(request.url.path, '/bridge/doc/open');
            expect(body, <String, dynamic>{
              'path': '/workspace/lib/main.dart',
              'version': 1,
              'content': 'void main() {}\n',
            });
            return http.Response(
              jsonEncode(<String, dynamic>{
                'path': '/workspace/lib/main.dart',
                'version': 1,
                'content': 'void main() {}\n',
              }),
              200,
            );
          case 1:
            expect(request.method, 'POST');
            expect(request.url.path, '/bridge/doc/change');
            expect(body, <String, dynamic>{
              'path': '/workspace/lib/main.dart',
              'version': 2,
              'changes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'range': <String, dynamic>{
                    'start': <String, dynamic>{'line': 0, 'character': 13},
                    'end': <String, dynamic>{'line': 0, 'character': 13},
                  },
                  'text': '\nprint("hi");',
                },
              ],
            });
            return http.Response(
              jsonEncode(<String, dynamic>{
                'path': '/workspace/lib/main.dart',
                'version': 2,
                'content': 'void main() {}\nprint("hi");',
              }),
              200,
            );
          case 2:
            expect(request.method, 'POST');
            expect(request.url.path, '/bridge/doc/save');
            expect(body, <String, dynamic>{'path': '/workspace/lib/main.dart'});
            return http.Response(
              jsonEncode(<String, dynamic>{
                'path': '/workspace/lib/main.dart',
                'version': 2,
                'content': 'void main() {}\nprint("hi");',
              }),
              200,
            );
          case 3:
            expect(request.method, 'POST');
            expect(request.url.path, '/bridge/doc/close');
            expect(body, <String, dynamic>{'path': '/workspace/lib/main.dart'});
            return http.Response(
              jsonEncode(<String, dynamic>{'closed': true}),
              200,
            );
          default:
            fail('Unexpected request #$requestIndex');
        }
      }),
    );

    final opened = await client.openDocument(
      path: '/workspace/lib/main.dart',
      version: 1,
      content: 'void main() {}\n',
    );
    final changed = await client.changeDocument(
      path: '/workspace/lib/main.dart',
      version: 2,
      changes: <DocumentChange>[
        const DocumentChange(
          text: '\nprint("hi");',
          range: DocumentRange(
            start: DocumentPosition(line: 0, character: 13),
            end: DocumentPosition(line: 0, character: 13),
          ),
        ),
      ],
    );
    final saved = await client.saveDocument('/workspace/lib/main.dart');
    await client.closeDocument('/workspace/lib/main.dart');

    expect(opened.version, 1);
    expect(changed.version, 2);
    expect(saved.content, contains('print("hi");'));
    expect(requestIndex, 4);
  });

  test(
    'parses completion, diagnostics, and workspace edits into typed models',
    () async {
      final settings = await createTestSettings();
      final client = EditorApiClient(
        settings: settings,
        client: MockClient((http.Request request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          switch (request.url.path) {
            case '/bridge/editor/completion':
              expect(body['position'], <String, dynamic>{
                'line': 3,
                'character': 10,
              });
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'isIncomplete': false,
                  'items': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'label': 'print',
                      'detail': 'dart:core',
                      'textEdit': <String, dynamic>{
                        'range': <String, dynamic>{
                          'start': <String, dynamic>{'line': 3, 'character': 7},
                          'end': <String, dynamic>{'line': 3, 'character': 10},
                        },
                        'newText': 'print()',
                      },
                      'additionalTextEdits': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'range': <String, dynamic>{
                            'start': <String, dynamic>{
                              'line': 0,
                              'character': 0,
                            },
                            'end': <String, dynamic>{'line': 0, 'character': 0},
                          },
                          'newText': "import 'dart:developer';\\n",
                        },
                      ],
                    },
                  ],
                }),
                200,
              );
            case '/bridge/editor/diagnostics':
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'path': '/workspace/lib/main.dart',
                  'diagnostics': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'range': <String, dynamic>{
                        'start': <String, dynamic>{'line': 4, 'character': 2},
                        'end': <String, dynamic>{'line': 4, 'character': 8},
                      },
                      'severity': 1,
                      'message': 'Undefined name',
                      'source': 'dart',
                    },
                  ],
                }),
                200,
              );
            case '/bridge/editor/rename':
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'changes': <String, dynamic>{
                    '/workspace/lib/main.dart': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'range': <String, dynamic>{
                          'start': <String, dynamic>{'line': 1, 'character': 4},
                          'end': <String, dynamic>{'line': 1, 'character': 7},
                        },
                        'newText': 'renamedValue',
                      },
                    ],
                  },
                }),
                200,
              );
            default:
              fail('Unexpected editor RPC ${request.url.path}');
          }
        }),
      );

      final completions = await client.completion(
        path: '/workspace/lib/main.dart',
        version: 4,
        position: const DocumentPosition(line: 3, character: 10),
        workDir: '/workspace/lib',
      );
      final diagnostics = await client.diagnostics(
        path: '/workspace/lib/main.dart',
        version: 4,
        workDir: '/workspace/lib',
      );
      final renameEdit = await client.rename(
        path: '/workspace/lib/main.dart',
        version: 4,
        position: const DocumentPosition(line: 1, character: 4),
        newName: 'renamedValue',
        workDir: '/workspace/lib',
      );

      expect(completions.isIncomplete, isFalse);
      expect(completions.items, hasLength(1));
      expect(completions.items.single.label, 'print');
      expect(completions.items.single.textEdit?.newText, 'print()');
      expect(
        completions.items.single.additionalTextEdits.single.newText,
        "import 'dart:developer';\\n",
      );

      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, isA<Diagnostic>());
      expect(diagnostics.single.line, 5);
      expect(diagnostics.single.severity, 'error');
      expect(diagnostics.single.message, 'Undefined name');

      expect(renameEdit.changes.keys, contains('/workspace/lib/main.dart'));
      final fileEdits = renameEdit.changes['/workspace/lib/main.dart']!;
      expect(fileEdits.single.newText, 'renamedValue');
      expect(fileEdits.single.range.start.line, 1);
    },
  );

  test('surfaces structured bridge errors through ApiException', () async {
    final settings = await createTestSettings();
    final client = EditorApiClient(
      settings: settings,
      client: MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/bridge/editor/rename');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'version_conflict',
            'message': 'document version does not match the tracked buffer',
          }),
          409,
        );
      }),
    );

    await expectLater(
      () => client.rename(
        path: '/workspace/lib/main.dart',
        version: 3,
        position: const DocumentPosition(line: 5, character: 8),
        newName: 'renamedValue',
        workDir: '/workspace/lib',
      ),
      throwsA(
        isA<ApiException>()
            .having((ApiException error) => error.statusCode, 'statusCode', 409)
            .having(
              (ApiException error) => error.toString(),
              'message',
              allOf(
                contains('version_conflict'),
                contains('document version does not match the tracked buffer'),
              ),
            ),
      ),
    );
  });

  test('builds the unified bridge events websocket URI', () async {
    final settings = await createTestSettings();
    Uri? capturedUri;
    final client = EditorApiClient(
      settings: settings,
      channelFactory: (Uri uri) {
        capturedUri = uri;
        return RecordingJsonChannel();
      },
    );

    final channel = client.connectEventsWebSocket();

    expect(
      capturedUri?.toString(),
      'ws://server.test/bridge/ws/events?token=dev-token',
    );
    await channel.sink.close();
  });
}
