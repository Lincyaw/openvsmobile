import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'providers/workspace_provider.dart';
import 'providers/file_provider.dart';
import 'providers/git_provider.dart';
import 'screens/files_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/git_screen.dart';
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
  final _fileWatch = _FileWatchClient();

  @override
  void dispose() {
    _fileWatch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wsPath = context.watch<WorkspaceProvider>().currentPath;
    final settings = context.watch<SettingsService>();

    // Sync file watcher to current workspace.
    _fileWatch.connect(
      settings.serverUrl,
      settings.authToken,
      wsPath,
      () {
        if (!mounted) return;
        context.read<FileProvider>().refresh();
        context.read<GitProvider>().refreshRepository();
      },
    );

    final tabs = <Widget>[
      const FilesScreen(),
      TerminalScreen(
        baseUrl: settings.serverUrl,
        token: settings.authToken,
        workDir: wsPath,
        isActive: _currentIndex == 1,
      ),
      const ChatScreen(),
      const GitScreen(),
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
        ],
      ),
    );
  }
}

/// Lightweight WebSocket client for /ws/files that watches the current workspace.
class _FileWatchClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  String? _lastPath;
  Timer? _debounceTimer;

  void connect(
    String baseUrl,
    String token,
    String path,
    VoidCallback onRefresh,
  ) {
    if (_lastPath == path && _channel != null) return;
    _lastPath = path;

    _subscription?.cancel();
    _channel?.sink.close();

    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/ws/files?token=$token');

    try {
      _channel = WebSocketChannel.connect(uri);
      _subscription = _channel!.stream.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final type = msg['type'] as String?;
          if (type == 'file_changed') {
            _debounceTimer?.cancel();
            _debounceTimer = Timer(const Duration(milliseconds: 500), () {
              onRefresh();
            });
          }
        },
        onError: (_) {},
        onDone: () {},
      );
      _channel!.sink.add(jsonEncode({'type': 'watch', 'path': path}));
    } catch (_) {}
  }

  void dispose() {
    _debounceTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
