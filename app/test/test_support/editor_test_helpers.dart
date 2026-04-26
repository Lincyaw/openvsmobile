import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/diagnostic.dart';
import 'package:vscode_mobile/models/editor_models.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

Future<SettingsService> createTestSettings({
  String serverUrl = 'http://server.test',
  String token = 'dev-token',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsService();
  await settings.load();
  await settings.save(serverUrl, token);
  return settings;
}

Future<void> settleAsync([int turns = 6]) async {
  for (var index = 0; index < turns; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> pumpEditorUi(
  WidgetTester tester, {
  Duration settleFor = const Duration(milliseconds: 350),
}) async {
  await tester.pump();
  await tester.pump(settleFor);
}

class FakeFileApiClient extends ApiClient {
  FakeFileApiClient({
    Map<String, String>? seedFiles,
    Map<String, List<Diagnostic>>? seedDiagnostics,
    SettingsService? settings,
    super.client,
  }) : files = Map<String, String>.from(seedFiles ?? const <String, String>{}),
       diagnosticsByPath = Map<String, List<Diagnostic>>.from(
         seedDiagnostics ?? const <String, List<Diagnostic>>{},
       ),
       super(settings: settings ?? SettingsService());

  final Map<String, String> files;
  final Map<String, List<Diagnostic>> diagnosticsByPath;
  final List<Map<String, dynamic>> lifecycleCalls = <Map<String, dynamic>>[];

  @override
  Future<String> readFile(String path) async {
    lifecycleCalls.add(<String, dynamic>{'method': 'readFile', 'path': path});
    return files[path] ?? '';
  }

  @override
  Future<void> writeFile(String path, String content) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'writeFile',
      'path': path,
      'content': content,
    });
    files[path] = content;
  }

  @override
  Future<List<Diagnostic>> getDiagnostics({
    String? filePath,
    String workDir = '/',
  }) async {
    lifecycleCalls.add(<String, dynamic>{
      'method': 'getDiagnostics',
      'path': filePath,
      'workDir': workDir,
    });
    return List<Diagnostic>.from(
      diagnosticsByPath[filePath] ?? const <Diagnostic>[],
    );
  }
}

Diagnostic diagnostic({
  String path = '/workspace/lib/main.dart',
  int startLine = 0,
  int startCharacter = 0,
  int endLine = 0,
  int endCharacter = 1,
  String severity = 'error',
  String message = 'Example problem',
  String source = 'test',
}) {
  return Diagnostic(
    filePath: path,
    range: DocumentRange(
      start: DocumentPosition(line: startLine, character: startCharacter),
      end: DocumentPosition(line: endLine, character: endCharacter),
    ),
    severity: severity,
    message: message,
    source: source,
  );
}

Widget wrapWithMaterialApp({
  required Widget child,
  List<SingleChildWidget> providers = const <SingleChildWidget>[],
}) {
  return MultiProvider(
    providers: providers,
    child: MaterialApp(home: child),
  );
}
