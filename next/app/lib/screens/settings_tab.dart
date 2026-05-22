// Settings tab: iOS-Settings-style inset-grouped list of entry tiles for
// backend management, SSH bootstrap, notification preferences, diagnostics,
// and About. Per design doc / issue C5 this replaces the transitional More
// tab. Each tile pushes a dedicated screen — Settings itself is intentionally
// not a long scroll of controls.
//
// Visual rework (Batch 2 — §4.3): the surface now uses the same
// `InsetSection` primitive the plugin UI renderer uses when a plugin
// author emits `UiSection { variant: 'inset' }`. Tiles are normal
// `ListTile`s wrapped in that surface; the picker for Theme stays a
// dialog (it's a tri-state radio, and turning it into a `UiSelect`
// would require either a host-side widget shim or driving Settings
// through `UiRenderer` — that's the heavier Option 2, out of scope for
// this batch).

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';
import 'about_screen.dart';
import 'notification_settings_screen.dart';
import 'ssh_bootstrap_screen.dart';
import 'system_tray_debug_screen.dart';
import 'webhook_tokens_screen.dart';

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

  /// Current app-wide theme mode. Drives the Theme tile's subtitle so the
  /// user can see the active choice without opening the picker.
  final ThemeMode themeMode;

  /// Persist + apply a new theme mode. The Theme picker calls this when
  /// the user selects a radio option; the change becomes visible on the
  /// next `MaterialApp` rebuild driven from main.dart.
  final Future<void> Function(ThemeMode mode) onThemeModeChanged;

  const SettingsTab({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.systemTrayController,
    required this.onOpenBackends,
    required this.onBackendInstalled,
    required this.onNotificationPrefsChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
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

  void _openWebhookTokens(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebhookTokensScreen(appState: appState),
      ),
    );
  }

  void _openDiagnostics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SystemTrayDebugScreen(controller: systemTrayController),
      ),
    );
  }

  void _openAbout(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen()));
  }

  Future<void> _openThemePicker(BuildContext context) async {
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogContext) {
        ThemeMode draft = themeMode;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Theme'),
            content: RadioGroup<ThemeMode>(
              groupValue: draft,
              onChanged: (v) {
                if (v == null) return;
                setDialogState(() => draft = v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in _kThemeOptions)
                    RadioListTile<ThemeMode>(
                      key: ValueKey<String>(
                        'theme-option:${_themeModeKey(entry.mode)}',
                      ),
                      value: entry.mode,
                      title: Text(entry.label),
                      subtitle: Text(entry.hint),
                      dense: true,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(draft),
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    await onThemeModeChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    // Grouped into three inset sections so the reader's eye finds related
    // concerns together: Connection (Backends + SSH bootstrap), Appearance
    // (Theme), and System (Notifications + Diagnostics + About). Same row
    // primitive everywhere — a Material ListTile inside `InsetSection`.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      children: [
        InsetSection(
          title: 'Connection',
          surfaceKey: const ValueKey<String>('settings-section:connection'),
          children: [
            ListTile(
              key: const ValueKey<String>('settings-tile-backends'),
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Backends'),
              subtitle: const Text('Add, switch, rename, or remove servers'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenBackends,
            ),
            ListTile(
              key: const ValueKey<String>('settings-tile-ssh-bootstrap'),
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('SSH bootstrap'),
              subtitle: const Text(
                'Install a backend on a remote host via SSH',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openSshBootstrap(context),
            ),
          ],
        ),
        InsetSection(
          title: 'Appearance',
          surfaceKey: const ValueKey<String>('settings-section:appearance'),
          children: [
            ListTile(
              key: const ValueKey<String>('settings-theme-tile'),
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('Theme'),
              subtitle: Text(_describeThemeMode(themeMode)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openThemePicker(context),
            ),
          ],
        ),
        InsetSection(
          title: 'System',
          surfaceKey: const ValueKey<String>('settings-section:system'),
          children: [
            ListTile(
              key: const ValueKey<String>('settings-tile-notifications'),
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              subtitle: const Text(
                'Background service, per-source mute, quiet hours, TTL',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openNotifications(context),
            ),
            ListTile(
              key: const ValueKey<String>('settings-tile-webhook-tokens'),
              leading: const Icon(Icons.key_outlined),
              title: const Text('Webhook tokens'),
              subtitle: const Text(
                'Publish-only tokens for CI, monitoring, webhooks',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openWebhookTokens(context),
            ),
            ListTile(
              key: const ValueKey<String>('settings-tile-diagnostics'),
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Diagnostics'),
              subtitle: const Text('System status, send test notification'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openDiagnostics(context),
            ),
            ListTile(
              key: const ValueKey<String>('settings-tile-about'),
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              subtitle: const Text('Version, license, project links'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openAbout(context),
            ),
          ],
        ),
      ],
    );
  }
}

/// One row in the Theme picker. Held as a top-level constant so the
/// list ordering — System / Light / Dark — stays explicit and the
/// widget-test keys can be derived from `mode` without leaking
/// internal labels.
class _ThemeOption {
  final ThemeMode mode;
  final String label;
  final String hint;
  const _ThemeOption(this.mode, this.label, this.hint);
}

const List<_ThemeOption> _kThemeOptions = [
  _ThemeOption(ThemeMode.system, 'System default', 'Follow the OS appearance'),
  _ThemeOption(ThemeMode.light, 'Light', 'Always use the light palette'),
  _ThemeOption(ThemeMode.dark, 'Dark', 'Always use the dark palette'),
];

String _themeModeKey(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

String _describeThemeMode(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'System default',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};
