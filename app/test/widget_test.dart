import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscode_mobile/app.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/chat_api_client.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/providers/file_provider.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/providers/search_provider.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    // Use a dummy base URL -- no real HTTP calls are made in this test.
    const baseUrl = 'http://localhost:0';
    const token = 'test-token';

    final apiClient = ApiClient(baseUrl: baseUrl, token: token);
    final chatApiClient = ChatApiClient(baseUrl: baseUrl, token: token);
    final gitApiClient = GitApiClient(baseUrl: baseUrl, token: token);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
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
      ),
    );
    expect(find.text('Files'), findsWidgets);
  });
}
