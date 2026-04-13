import 'package:flutter/material.dart';
import '../main.dart' show serverBaseUrl, serverAuthToken;
import 'git_screen.dart';
import 'terminal_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.commit),
            title: const Text('Git Status'),
            subtitle: const Text('View changes, log, and branches'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const GitScreen()));
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const Text('Terminal'),
            subtitle: const Text('Open a shell session'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const TerminalScreen(
                    baseUrl: serverBaseUrl,
                    token: serverAuthToken,
                  ),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            subtitle: const Text('App configuration'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings coming soon')),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('App information'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'VSCode Mobile',
                // TODO: read version from package_info_plus at runtime
                applicationVersion: '1.0.0',
                children: [
                  const Text(
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
