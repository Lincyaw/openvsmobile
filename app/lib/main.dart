import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'providers/chat_provider.dart';
import 'providers/editor_provider.dart';
import 'providers/file_provider.dart';
import 'providers/git_provider.dart';
import 'providers/github_collaboration_provider.dart';
import 'providers/github_auth_provider.dart';
import 'providers/search_provider.dart';
import 'providers/workspace_provider.dart';
import 'services/api_client.dart';
import 'services/browser_launcher.dart';
import 'services/chat_api_client.dart';
import 'services/editor_api_client.dart';
import 'services/git_api_client.dart';
import 'services/github_collaboration_api_client.dart';
import 'services/github_auth_api_client.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = SettingsService();
  await settings.load();

  final apiClient = ApiClient(settings: settings);
  final chatApiClient = ChatApiClient(settings: settings);
  final editorApiClient = EditorApiClient(settings: settings);
  final gitApiClient = GitApiClient(settings: settings);
  final githubAuthApiClient = GitHubAuthApiClient(settings: settings);
  final githubCollaborationApiClient = GitHubCollaborationApiClient(
    settings: settings,
  );
  final browserLauncher = BrowserLauncher();

  final workspaceProvider = WorkspaceProvider();
  await workspaceProvider.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: workspaceProvider),
        Provider.value(value: browserLauncher),
        ChangeNotifierProvider(
          create: (_) =>
              FileProvider(apiClient: apiClient)
                ..setProject(workspaceProvider.currentPath),
        ),
        ChangeNotifierProvider(
          create: (_) => EditorProvider(
            apiClient: apiClient,
            editorApiClient: editorApiClient,
          ),
        ),
        ChangeNotifierProxyProvider<EditorProvider, ChatProvider>(
          create: (_) =>
              ChatProvider(apiClient: chatApiClient)
                ..setWorkspace(workspaceProvider.currentPath),
          update: (_, editorProvider, chatProvider) {
            chatProvider!.setEditorContext(editorProvider.chatContext);
            return chatProvider;
          },
        ),
        ChangeNotifierProvider(
          create: (_) => GitProvider(apiClient: gitApiClient),
        ),
        ChangeNotifierProvider(
          create: (_) => SearchProvider(apiClient: apiClient),
        ),
        ChangeNotifierProxyProvider<WorkspaceProvider, GitHubAuthProvider>(
          create: (_) => GitHubAuthProvider(
            apiClient: githubAuthApiClient,
            gitApiClient: gitApiClient,
          ),
          update: (_, workspace, githubAuthProvider) {
            final provider = githubAuthProvider!;
            provider.setWorkspacePath(workspace.currentPath);
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<
          WorkspaceProvider,
          GitHubCollaborationProvider
        >(
          create: (_) => GitHubCollaborationProvider(
            apiClient: githubCollaborationApiClient,
          ),
          update: (_, workspace, collaborationProvider) {
            final provider = collaborationProvider!;
            provider.setWorkspacePath(workspace.currentPath);
            return provider;
          },
        ),
      ],
      child: const VSCodeMobileApp(),
    ),
  );
}
