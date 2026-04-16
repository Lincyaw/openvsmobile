import 'package:flutter/material.dart';
import '../screens/settings_screen.dart';

/// Reusable popup menu for app bar actions (Settings, About).
class AppBarMenu extends StatelessWidget {
  const AppBarMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'settings':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
            break;
          case 'about':
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
            break;
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'settings', child: Text('Settings')),
        PopupMenuItem(value: 'about', child: Text('About')),
      ],
    );
  }
}
