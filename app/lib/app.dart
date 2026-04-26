import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/workspace_provider.dart';
import 'providers/file_provider.dart';
import 'providers/git_provider.dart';
import 'providers/terminal_provider.dart';
import 'screens/files_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/terminal_workspace_screen.dart';
import 'screens/git_screen.dart';
import 'screens/more_screen.dart';
import 'services/bridge_events_client.dart';
import 'services/settings_service.dart';

class VSCodeMobileApp extends StatelessWidget {
  const VSCodeMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VSCode Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final BridgeEventsClient _bridgeEvents = BridgeEventsClient();
  String? _bridgeEventsBaseUrl;
  String? _bridgeEventsToken;

  @override
  void initState() {
    super.initState();
    // Single push-based events socket, fanned out to providers via handlers.
    // Providers no longer own their own /bridge/ws/events connections.
    _bridgeEvents.on('git.repositoryChanged', (_) {
      if (!mounted) return;
      context.read<GitProvider>().refreshRepository();
      // File-tree may need to refresh too because git operations
      // (checkout/stash/pull) frequently mutate the working tree.
      context.read<FileProvider>().refresh();
    });
    _bridgeEvents.on('diagnostics.changed', (_) {
      if (!mounted) return;
      // No consumer wired yet — diagnostics are pulled on demand by the
      // editor screen. Keeping the subscription so we can hook
      // EditorProvider here once it gains a refresh API.
    });
    // Terminal session lifecycle events arrive on the same socket. Refreshing
    // the inventory is the simplest correct response — TerminalProvider knows
    // how to merge new/updated/closed sessions in one pass.
    _bridgeEvents.on('terminal.session.created', (_) {
      if (!mounted) return;
      context.read<TerminalProvider>().refreshSessions();
    });
    _bridgeEvents.on('terminal.session.updated', (_) {
      if (!mounted) return;
      context.read<TerminalProvider>().refreshSessions();
    });
    _bridgeEvents.on('terminal.session.closed', (_) {
      if (!mounted) return;
      context.read<TerminalProvider>().refreshSessions();
    });
  }

  @override
  void dispose() {
    _bridgeEvents.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    // We watch WorkspaceProvider so the shell rebuilds on workspace switches,
    // which keeps tabs scoped to the active project.
    context.watch<WorkspaceProvider>();

    // (Re)connect the bridge events stream whenever server settings change.
    if (_bridgeEventsBaseUrl != settings.serverUrl ||
        _bridgeEventsToken != settings.authToken) {
      _bridgeEventsBaseUrl = settings.serverUrl;
      _bridgeEventsToken = settings.authToken;
      _bridgeEvents.connect(settings.serverUrl, settings.authToken);
    }

    final tabs = <Widget>[
      const FilesScreen(),
      TerminalWorkspaceScreen(isActive: _currentIndex == 1),
      const ChatScreen(),
      const GitScreen(),
      const MoreScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Terminal',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_outlined),
            selectedIcon: Icon(Icons.chat),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.commit_outlined),
            selectedIcon: Icon(Icons.commit),
            label: 'Git',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz_outlined),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }
}
