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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load persisted settings, fall back to compile-time defaults
  final settings = SettingsService();
  await settings.load();

  final apiClient = ApiClient(settings: settings);
  final chatApiClient = ChatApiClient(settings: settings);
  final gitApiClient = GitApiClient(settings: settings);

  // Load workspace before building the widget tree.
  final workspaceProvider = WorkspaceProvider();
  await workspaceProvider.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
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
            ..setWorkspace(workspaceProvider.currentPath)
            ..loadPersistedSession(),
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
