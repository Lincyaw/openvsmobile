import 'package:flutter/material.dart';

import 'github_auth_screen.dart';
import 'settings_screen.dart';

/// Catch-all menu surface for entry points that aren't worth their own tab:
/// GitHub connection (workbuddy needs the token) and server-side settings.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('GitHub Connection'),
            subtitle: const Text('Device-flow sign-in for git operations'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const GitHubAuthScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            subtitle: const Text('Server URL and authentication token'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'VSCode Mobile',
                applicationVersion: '1.0.0',
                children: const [
                  Text(
                    'A mobile client for OpenVSCode Server with AI chat.',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
