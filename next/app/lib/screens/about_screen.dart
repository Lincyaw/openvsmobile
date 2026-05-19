// About screen: app + paired backend version, project links. Minimal —
// the design doc treats About as informational, not configurable.

import 'package:flutter/material.dart';

import '../ui/app_tokens.dart';
import '../version.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _projectUrl =
      'https://github.com/Lincyaw/openvsmobile';
  static const String _licenseName = 'Apache-2.0';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xl,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              children: [
                Icon(
                  Icons.terminal_outlined,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'MobileCode',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Mobile-native code workbench',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.dns_outlined),
            title: Text('Paired backend version'),
            subtitle: Text(kBackendVersion),
          ),
          const ListTile(
            leading: Icon(Icons.gavel_outlined),
            title: Text('License'),
            subtitle: Text(_licenseName),
          ),
          const ListTile(
            leading: Icon(Icons.link),
            title: Text('Project'),
            subtitle: Text(_projectUrl),
          ),
        ],
      ),
    );
  }
}
