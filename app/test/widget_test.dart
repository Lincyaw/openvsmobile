import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscode_mobile/app.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/chat_api_client.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';
import 'package:vscode_mobile/providers/file_provider.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/providers/search_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';

Widget buildTestApp() {
  final settings = SettingsService();

  final apiClient = ApiClient(settings: settings);
  final chatApiClient = ChatApiClient(settings: settings);
  final gitApiClient = GitApiClient(settings: settings);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider(create: (_) => WorkspaceProvider()),
      ChangeNotifierProvider(
        create: (_) => FileProvider(apiClient: apiClient)..setProject('/'),
      ),
      ChangeNotifierProvider(
        create: (_) => EditorProvider(apiClient: apiClient),
      ),
      ChangeNotifierProvider(
        create: (_) => ChatProvider(apiClient: chatApiClient),
      ),
      ChangeNotifierProvider(
        create: (_) => GitProvider(apiClient: gitApiClient),
      ),
      ChangeNotifierProvider(
        create: (_) => SearchProvider(apiClient: apiClient),
      ),
    ],
    child: const VSCodeMobileApp(),
  );
}

void main() {
  testWidgets('App renders navigation bar with all tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTestApp());

    // The bottom navigation bar should show all 4 tabs.
    expect(find.text('Files'), findsWidgets);
    expect(find.text('Terminal'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Git'), findsWidgets);
  });
}
