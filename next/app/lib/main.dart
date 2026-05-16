// App entrypoint. Boots the BackendClient + AppState, loads saved settings,
// and either drops the user into the home shell or prompts for settings.

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'backend_client.dart';
import 'screens/home_shell.dart';
import 'screens/settings_screen.dart';
import 'settings_store.dart';

void main() {
  runApp(const OpenVsMobileApp());
}

class OpenVsMobileApp extends StatefulWidget {
  const OpenVsMobileApp({super.key});

  @override
  State<OpenVsMobileApp> createState() => _OpenVsMobileAppState();
}

class _OpenVsMobileAppState extends State<OpenVsMobileApp> {
  final SettingsStore _settingsStore = SettingsStore();
  final BackendClient _client = BackendClient();
  late final AppState _appState = AppState(client: _client);

  Settings? _settings;
  bool _loadingSettings = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final s = await _settingsStore.load();
    setState(() {
      _settings = s;
      _loadingSettings = false;
    });
    if (s.isComplete) {
      await _client.connect(host: s.host, port: s.port, token: s.token);
    }
  }

  Future<void> _onSettingsSaved(Settings s) async {
    await _settingsStore.save(s);
    setState(() => _settings = s);
    await _client.disconnect();
    if (s.isComplete) {
      await _client.connect(host: s.host, port: s.port, token: s.token);
    }
  }

  @override
  void dispose() {
    _appState.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openvsmobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: _loadingSettings
          ? const _BootSplash()
          : (_settings == null || !_settings!.isComplete)
              ? SettingsScreen(
                  initial: _settings ??
                      const Settings(host: '', port: 7860, token: ''),
                  isFirstRun: true,
                  onSave: _onSettingsSaved,
                )
              : HomeShell(
                  appState: _appState,
                  settingsStore: _settingsStore,
                  currentSettings: _settings!,
                  onSettingsSaved: _onSettingsSaved,
                ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
