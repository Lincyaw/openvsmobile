// About screen: product identity plus runtime diagnostics that help users
// verify the phone is connected to the expected backend build.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';
import '../version.dart';

class AboutScreen extends StatelessWidget {
  final AppState appState;

  const AboutScreen({super.key, required this.appState});

  static const String _projectUrl = 'https://github.com/Lincyaw/openvsmobile';
  static const String _licenseName = 'Apache-2.0';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) => ListView(
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
                  Text('MobileCode', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Remote code workbench',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            InsetSection(
              title: 'Runtime',
              children: [
                const ListTile(
                  leading: Icon(Icons.system_update_outlined),
                  title: Text('Target backend release'),
                  subtitle: Text('v$kBackendVersion'),
                ),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Connected backend'),
                  subtitle: Text(_backendVersionLabel(appState)),
                ),
                ListTile(
                  leading: const Icon(Icons.sync_alt_outlined),
                  title: const Text('Connection state'),
                  subtitle: Text(_connectionLabel(appState.connectionState)),
                ),
              ],
            ),
            const InsetSection(
              title: 'Project',
              children: [
                ListTile(
                  leading: Icon(Icons.gavel_outlined),
                  title: Text('License'),
                  subtitle: Text(_licenseName),
                ),
                ListTile(
                  leading: Icon(Icons.link),
                  title: Text('Project'),
                  subtitle: Text(_projectUrl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _backendVersionLabel(AppState appState) {
  final version = appState.connectedBackendVersion;
  if (version == null || version.isEmpty) return 'Not connected';
  if (version == kBackendVersion) return 'v$version';
  return 'v$version (expected v$kBackendVersion)';
}

String _connectionLabel(BackendConnectionState state) => switch (state) {
  BackendConnectionState.disconnected => 'Disconnected',
  BackendConnectionState.connecting => 'Connecting',
  BackendConnectionState.connected => 'Connected',
  BackendConnectionState.reconnecting => 'Reconnecting',
  BackendConnectionState.waitingForNetwork => 'Waiting for network',
  BackendConnectionState.failed => 'Failed',
};
