import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/api_client.dart';
import 'services/chat_api_client.dart';
import 'services/git_api_client.dart';
import 'services/settings_service.dart';
import 'providers/file_provider.dart';
import 'providers/editor_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/git_provider.dart';
import 'providers/search_provider.dart';
import 'providers/workspace_provider.dart';

// Compile-time defaults (overridable via --dart-define)
const _defaultServerUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8080',
);
const _defaultAuthToken = String.fromEnvironment(
  'AUTH_TOKEN',
  defaultValue: 'dev-token',
);

// Runtime values loaded from SharedPreferences (set after settings load)
late String serverBaseUrl;
late String serverAuthToken;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load persisted settings, fall back to compile-time defaults
  final settings = SettingsService();
  await settings.load();
  serverBaseUrl = settings.serverUrl.isNotEmpty
      ? settings.serverUrl
      : _defaultServerUrl;
  serverAuthToken = settings.authToken.isNotEmpty
      ? settings.authToken
      : _defaultAuthToken;

  final apiClient = ApiClient(baseUrl: serverBaseUrl, token: serverAuthToken);

  final chatApiClient = ChatApiClient(
    baseUrl: serverBaseUrl,
    token: serverAuthToken,
  );

  final gitApiClient = GitApiClient(
    baseUrl: serverBaseUrl,
    token: serverAuthToken,
  );

  // Load workspace before building the widget tree.
  final workspaceProvider = WorkspaceProvider();
  await workspaceProvider.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: workspaceProvider),
        ChangeNotifierProvider(
          create: (_) => FileProvider(apiClient: apiClient)
            ..setProject(workspaceProvider.currentPath),
        ),
        ChangeNotifierProvider(
          create: (_) => EditorProvider(apiClient: apiClient),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(apiClient: chatApiClient)
            ..setWorkspace(workspaceProvider.currentPath),
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
