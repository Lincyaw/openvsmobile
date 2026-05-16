// App entrypoint. Boots the BackendClient + AppState, loads saved settings,
// wires connectivity + app-lifecycle to the always-on reconnect loop, and
// drops the user into either the home shell or the first-run settings prompt.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'backend_client.dart';
import 'screens/home_shell.dart';
import 'screens/settings_screen.dart';
import 'settings_store.dart';

void main() {
  runApp(const OpenVsMobileApp());
}

/// Production probe backed by `connectivity_plus`. Maps the list of active
/// link types to a single boolean — we don't care which link, only whether
/// at least one is up.
class _ConnectivityPlusProbe implements ConnectivityProbe {
  final Connectivity _impl = Connectivity();

  @override
  Stream<bool> get changes => _impl.onConnectivityChanged.map(_anyOnline);

  @override
  Future<bool> isOnline() async {
    try {
      return _anyOnline(await _impl.checkConnectivity());
    } catch (_) {
      // Plugin not implemented on this platform (e.g. desktop) → assume yes.
      return true;
    }
  }

  bool _anyOnline(List<ConnectivityResult> rs) =>
      rs.any((r) => r != ConnectivityResult.none);
}

class OpenVsMobileApp extends StatefulWidget {
  const OpenVsMobileApp({super.key});

  @override
  State<OpenVsMobileApp> createState() => _OpenVsMobileAppState();
}

class _OpenVsMobileAppState extends State<OpenVsMobileApp>
    with WidgetsBindingObserver {
  final SettingsStore _settingsStore = SettingsStore();
  late final BackendClient _client =
      BackendClient(probe: _ConnectivityPlusProbe());
  late final AppState _appState = AppState(client: _client);

  Settings? _settings;
  bool _loadingSettings = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final s = await _settingsStore.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _loadingSettings = false;
    });
    if (s.isComplete) {
      _client.configure(host: s.host, port: s.port, token: s.token);
      await _client.start();
    }
  }

  Future<void> _onSettingsSaved(Settings s) async {
    await _settingsStore.save(s);
    if (!mounted) return;
    setState(() => _settings = s);
    await _client.userDisconnect();
    if (s.isComplete) {
      _client.configure(host: s.host, port: s.port, token: s.token);
      await _client.start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user yanks the app back from background, fast-path the
    // reconnect instead of letting the backoff timer finish.
    if (state == AppLifecycleState.resumed) {
      _client.requestReconnectNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
