import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/api_client.dart';
import 'services/chat_api_client.dart';
import 'services/git_api_client.dart';
import 'providers/file_provider.dart';
import 'providers/editor_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/git_provider.dart';
import 'providers/search_provider.dart';

// Configurable via --dart-define: SERVER_URL, AUTH_TOKEN
// 10.0.2.2 is the Android emulator's alias for host localhost
const serverBaseUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.0.2.2:8080');
const serverAuthToken = String.fromEnvironment('AUTH_TOKEN', defaultValue: 'dev-token');

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final apiClient = ApiClient(baseUrl: serverBaseUrl, token: serverAuthToken);

  final chatApiClient = ChatApiClient(baseUrl: serverBaseUrl, token: serverAuthToken);

  final gitApiClient = GitApiClient(baseUrl: serverBaseUrl, token: serverAuthToken);

  runApp(
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
}
