// "More" tab: bootstrap installer + settings entry. Placed after Files and
// Terminal so the chat-style primary tabs stay at the left.

import 'package:flutter/material.dart';

import '../settings_store.dart';
import 'settings_screen.dart';
import 'ssh_bootstrap_screen.dart';

class MoreTab extends StatelessWidget {
  final Settings currentSettings;
  final Future<void> Function(Settings) onSettingsSaved;
  const MoreTab({
    super.key,
    required this.currentSettings,
    required this.onSettingsSaved,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        // First entry on purpose: the "I just got here, let me get going" path.
        ListTile(
          leading: const Icon(Icons.cloud_download),
          title: const Text('Install backend via SSH'),
          subtitle: const Text(
            'Run install.sh on a remote host and pre-fill connection settings',
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<Settings>(
                builder: (_) => SshBootstrapScreen(
                  onSettingsSaved: onSettingsSaved,
                ),
              ),
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.settings),
          title: const Text('Settings'),
          subtitle: const Text('Host, port, bearer token'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<Settings>(
                builder: (_) => SettingsScreen(
                  initial: currentSettings,
                  onSave: onSettingsSaved,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
