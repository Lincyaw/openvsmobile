// Settings tab: list of entry tiles for backend management, SSH bootstrap,
// notification preferences, diagnostics, and About. Per design doc / issue
// C5 this replaces the transitional More tab. Each tile pushes a dedicated
// screen — Settings itself is intentionally not a long scroll of controls.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import 'about_screen.dart';
import 'notification_settings_screen.dart';
import 'ssh_bootstrap_screen.dart';
import 'system_tray_debug_screen.dart';

class SettingsTab extends StatelessWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  final SystemTrayController systemTrayController;

  /// Push the Backends management screen on the root navigator. Owned by
  /// main.dart so the route lives outside the bottom-nav IndexedStack.
  final VoidCallback onOpenBackends;

  /// Wire a freshly-bootstrapped backend back into the persisted list.
  /// Mirrors the contract used by BackendsScreen's add-sheet so SSH
  /// bootstrap launched from Settings produces the same outcome.
  final Future<void> Function(BackendTarget target, {required bool makeActive})
      onBackendInstalled;

  /// Notify main.dart that notification preferences changed so it can
  /// (re)start or stop the foreground service. Forwarded straight to
  /// NotificationSettingsScreen.onChanged.
  final Future<void> Function() onNotificationPrefsChanged;

  const SettingsTab({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.systemTrayController,
    required this.onOpenBackends,
    required this.onBackendInstalled,
    required this.onNotificationPrefsChanged,
  });

  void _openSshBootstrap(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SshBootstrapScreen(
          appState: appState,
          onBackendInstalled: (target) async {
            await onBackendInstalled(target, makeActive: true);
          },
        ),
      ),
    );
  }

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NotificationSettingsScreen(
          appState: appState,
          settingsStore: settingsStore,
          onChanged: onNotificationPrefsChanged,
        ),
      ),
    );
  }

  void _openDiagnostics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SystemTrayDebugScreen(controller: systemTrayController),
      ),
    );
  }

  void _openAbout(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AboutScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Backends'),
          subtitle: const Text('Add, switch, rename, or remove servers'),
          onTap: onOpenBackends,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: const Text('SSH bootstrap'),
          subtitle: const Text('Install a backend on a remote host via SSH'),
          onTap: () => _openSshBootstrap(context),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Notifications'),
          subtitle: const Text(
            'Background service, per-source mute, quiet hours, TTL',
          ),
          onTap: () => _openNotifications(context),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics'),
          subtitle: const Text('System status, send test notification'),
          onTap: () => _openDiagnostics(context),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About'),
          subtitle: const Text('Version, license, project links'),
          onTap: () => _openAbout(context),
        ),
      ],
    );
  }
}
