// "More" tab: secondary entries that don't deserve their own bottom-nav
// slot yet. The Backends manager is the primary entrypoint; from there the
// user adds via SSH or manual entry, switches, renames, deletes.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import 'notification_settings_screen.dart';
import 'system_tray_debug_screen.dart';

class MoreTab extends StatelessWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  final SystemTrayController systemTrayController;
  final VoidCallback onOpenBackends;
  final Future<void> Function() onNotificationPrefsChanged;
  const MoreTab({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.systemTrayController,
    required this.onOpenBackends,
    required this.onNotificationPrefsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Backends'),
          subtitle: const Text(
            'Add, switch, rename, or remove servers',
          ),
          onTap: onOpenBackends,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Notifications'),
          subtitle: const Text(
            'Background service, per-source mute, quiet hours, TTL',
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NotificationSettingsScreen(
                  appState: appState,
                  settingsStore: settingsStore,
                  onChanged: onNotificationPrefsChanged,
                ),
              ),
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics'),
          subtitle: const Text('System status, send test notification'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SystemTrayDebugScreen(controller: systemTrayController),
              ),
            );
          },
        ),
      ],
    );
  }
}
