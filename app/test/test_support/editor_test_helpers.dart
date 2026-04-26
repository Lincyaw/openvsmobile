import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    SettingsService? settings,
    super.client,
  }) : files = Map<String, String>.from(seedFiles ?? const <String, String>{}),
       super(settings: settings ?? SettingsService());

  final Map<String, String> files;
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
