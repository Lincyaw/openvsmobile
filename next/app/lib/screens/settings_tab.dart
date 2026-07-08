// Settings tab: iOS-Settings-style inset-grouped list of entry tiles for
// backend management, notification preferences, diagnostics, and About. Per
// design doc / issue C5 this replaces the transitional More tab. Each tile
// pushes a dedicated screen — Settings itself is intentionally not a long
// scroll of controls.
//
// Visual rework (Batch 2 — §4.3): the surface now uses the same
// `InsetSection` primitive the plugin UI renderer uses when a plugin
// author emits `UiSection { variant: 'inset' }`. Tiles are normal
// `ListTile`s wrapped in that surface; the picker for Theme stays a
// dialog (it's a tri-state radio, and turning it into a `UiSelect`
// would require either a host-side widget shim or driving Settings
// through `UiRenderer` — that's the heavier Option 2, out of scope for
// this batch).

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';
import '../ui/inset_section.dart';
import '../version.dart';
import 'agent_hooks_screen.dart';
import 'about_screen.dart';
import 'app_update_screen.dart';
import 'notification_settings_screen.dart';
import 'system_tray_debug_screen.dart';

class SettingsTab extends StatelessWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  final AppPersistedState backendState;
  final SystemTrayController systemTrayController;
  final bool isActive;

  /// Push the Backends management screen on the root navigator. Owned by
  /// main.dart so the route lives outside the bottom-nav IndexedStack.
  final VoidCallback onOpenBackends;

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
    required this.backendState,
    required this.systemTrayController,
    this.isActive = true,
    required this.onOpenBackends,
    required this.onNotificationPrefsChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

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

  void _openAgentHooks(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentHooksScreen(appState: appState),
      ),
    );
  }

  void _openDiagnostics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SystemTrayDebugScreen(
          controller: systemTrayController,
          settingsStore: settingsStore,
        ),
      ),
    );
  }

  void _openAppUpdate(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AppUpdateScreen()));
  }

  void _openAbout(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AboutScreen(appState: appState)),
    );
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
    // Keep the top-level settings page focused on user-facing jobs:
    // connect to a backend, receive agent/status updates, tune app
    // preferences, and inspect maintenance surfaces.
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(0, AppSpacing.sm, 0, AppSpacing.xl),
        children: [
          _AgentHookStatusAutoRefresh(appState: appState, active: isActive),
          _RemoteControlSummary(appState: appState, backendState: backendState),
          InsetSection(
            title: 'Backend',
            surfaceKey: const ValueKey<String>('settings-section:backend'),
            children: [
              ListTile(
                key: const ValueKey<String>('settings-tile-backends'),
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Backend servers'),
                subtitle: const Text('Add, switch, rename, or remove servers'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onOpenBackends,
              ),
            ],
          ),
          InsetSection(
            title: 'Workflow',
            surfaceKey: const ValueKey<String>('settings-section:workflow'),
            children: [
              ListTile(
                key: const ValueKey<String>('settings-tile-notifications'),
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Notifications'),
                subtitle: const Text(
                  'Background delivery, source mute, quiet hours',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openNotifications(context),
              ),
              ListTile(
                key: const ValueKey<String>('settings-tile-agent-hooks'),
                leading: const Icon(Icons.bolt_outlined),
                title: const Text('Agent hooks'),
                subtitle: const Text('Claude/Codex completion notifications'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openAgentHooks(context),
              ),
            ],
          ),
          InsetSection(
            title: 'Preferences',
            surfaceKey: const ValueKey<String>('settings-section:preferences'),
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
            title: 'Maintenance',
            surfaceKey: const ValueKey<String>('settings-section:maintenance'),
            children: [
              ListTile(
                key: const ValueKey<String>('settings-tile-app-update'),
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('Updates'),
                subtitle: const Text('v$kBackendVersion'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openAppUpdate(context),
              ),
              ListTile(
                key: const ValueKey<String>('settings-tile-diagnostics'),
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('Diagnostics'),
                subtitle: const Text(
                  'Connection trace, tray tests, debug tools',
                ),
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
      ),
    );
  }
}

class _AgentHookStatusAutoRefresh extends StatefulWidget {
  final AppState appState;
  final bool active;

  const _AgentHookStatusAutoRefresh({
    required this.appState,
    required this.active,
  });

  @override
  State<_AgentHookStatusAutoRefresh> createState() =>
      _AgentHookStatusAutoRefreshState();
}

class _AgentHookStatusAutoRefreshState
    extends State<_AgentHookStatusAutoRefresh> {
  int? _lastRequestedBackendEpoch;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _maybeSchedule();
  }

  @override
  void didUpdateWidget(covariant _AgentHookStatusAutoRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeSchedule();
  }

  void _maybeSchedule() {
    final appState = widget.appState;
    final hooks = appState.agentHooks;
    if (!widget.active ||
        appState.connectionState != BackendConnectionState.connected ||
        hooks.checking ||
        hooks.installing ||
        hooks.statusUnsupported ||
        hooks.lastResult != null ||
        _lastRequestedBackendEpoch == appState.backendSessionEpoch ||
        _scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final epoch = widget.appState.backendSessionEpoch;
      final hooks = widget.appState.agentHooks;
      if (!widget.active ||
          widget.appState.connectionState != BackendConnectionState.connected ||
          hooks.checking ||
          hooks.installing ||
          hooks.statusUnsupported ||
          hooks.lastResult != null ||
          _lastRequestedBackendEpoch == epoch) {
        return;
      }
      _lastRequestedBackendEpoch = epoch;
      unawaited(_refreshStatus());
    });
  }

  Future<void> _refreshStatus() async {
    try {
      await widget.appState.agentHooks.refreshStatus();
    } catch (_) {
      // AgentHooksModel reports the user-visible error; Settings should not
      // turn a background status chip refresh into a second failure surface.
    }
  }

  @override
  Widget build(BuildContext context) {
    _maybeSchedule();
    return const SizedBox.shrink();
  }
}

class _RemoteControlSummary extends StatelessWidget {
  final AppState appState;
  final AppPersistedState backendState;

  const _RemoteControlSummary({
    required this.appState,
    required this.backendState,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = backendState.activeBackend;
    final connection = _connectionPresentation(
      appState.connectionState,
      scheme,
    );
    final title = active == null ? 'No backend selected' : _backendName(active);
    final endpoint = active == null
        ? 'Add a backend to start'
        : _backendEndpointLabel(active);
    final hookChip = _agentHooksPresentation(appState, scheme);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Material(
        key: const ValueKey<String>('settings-remote-summary'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          key: const ValueKey<String>('settings-remote-summary-main'),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    active?.transport == BackendTransport.iroh
                        ? Icons.hub_outlined
                        : Icons.dns_outlined,
                    color: connection.accent,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          endpoint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            fontSize: theme.textTheme.labelMedium?.fontSize,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  _SummaryChip(
                    label: connection.label,
                    accent: connection.accent,
                    showDot: true,
                  ),
                  _SummaryChip(label: _backendCountLabel(backendState)),
                  _SummaryChip(
                    key: const ValueKey<String>('settings-summary-hook-chip'),
                    label: hookChip.label,
                    accent: hookChip.accent,
                    showDot: hookChip.showDot,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final Color? accent;
  final bool showDot;

  const _SummaryChip({
    super.key,
    required this.label,
    this.accent,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = accent ?? scheme.onSurfaceVariant;
    final background = accent == null
        ? scheme.surfaceContainerHighest
        : accent!.withAlpha(AppBannerOpacity.wash);
    final borderColor = accent == null
        ? scheme.outlineVariant
        : accent!.withAlpha(AppBannerOpacity.border);

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      side: BorderSide(color: borderColor),
    );
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDot) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ],
        Text(label, style: labelStyle),
      ],
    );
    return DecoratedBox(
      decoration: ShapeDecoration(color: background, shape: shape),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: content,
      ),
    );
  }
}

class _ConnectionPresentation {
  final String label;
  final Color accent;

  const _ConnectionPresentation({required this.label, required this.accent});
}

_ConnectionPresentation _connectionPresentation(
  BackendConnectionState state,
  ColorScheme scheme,
) {
  return switch (state) {
    BackendConnectionState.connected => _ConnectionPresentation(
      label: 'Connected',
      accent: scheme.primary,
    ),
    BackendConnectionState.connecting => _ConnectionPresentation(
      label: 'Connecting',
      accent: scheme.tertiary,
    ),
    BackendConnectionState.reconnecting => _ConnectionPresentation(
      label: 'Reconnecting',
      accent: scheme.tertiary,
    ),
    BackendConnectionState.waitingForNetwork => _ConnectionPresentation(
      label: 'No network',
      accent: scheme.tertiary,
    ),
    BackendConnectionState.failed => _ConnectionPresentation(
      label: 'Failed',
      accent: scheme.error,
    ),
    BackendConnectionState.disconnected => _ConnectionPresentation(
      label: 'Offline',
      accent: scheme.onSurfaceVariant,
    ),
  };
}

String _backendName(BackendTarget target) {
  final name = target.name.trim();
  if (name.isNotEmpty) return name;
  return _backendEndpointLabel(target);
}

String _backendEndpointLabel(BackendTarget target) =>
    switch (target.transport) {
      BackendTransport.websocket =>
        target.host.isEmpty ? 'websocket' : '${target.host}:${target.port}',
      BackendTransport.iroh => 'iroh:${_shortIrohLabel(target)}',
    };

String _shortIrohLabel(BackendTarget target) {
  final raw = (target.irohEndpointId ?? target.irohTicket ?? '').trim();
  if (raw.isEmpty) return 'ticket';
  return raw.substring(0, raw.length < 12 ? raw.length : 12);
}

String _backendCountLabel(AppPersistedState state) {
  final count = state.backends.length;
  return count == 1 ? '1 backend' : '$count backends';
}

class _SummaryChipPresentation {
  final String label;
  final Color? accent;
  final bool showDot;

  const _SummaryChipPresentation({
    required this.label,
    this.accent,
    this.showDot = false,
  });
}

_SummaryChipPresentation _agentHooksPresentation(
  AppState appState,
  ColorScheme scheme,
) {
  final hooks = appState.agentHooks;
  if (hooks.installing) {
    return _SummaryChipPresentation(
      label: 'Installing hooks',
      accent: scheme.tertiary,
      showDot: true,
    );
  }
  if (hooks.checking) {
    return _SummaryChipPresentation(
      label: 'Checking hooks',
      accent: scheme.tertiary,
      showDot: true,
    );
  }
  if (hooks.statusUnsupported) {
    return const _SummaryChipPresentation(label: 'Hooks unavailable');
  }
  final result = hooks.lastResult;
  if (result == null) {
    return const _SummaryChipPresentation(label: 'Hooks not checked');
  }
  if (!result.ok) {
    return _SummaryChipPresentation(
      label: 'Hook scan failed',
      accent: scheme.error,
      showDot: true,
    );
  }
  final available = result.statuses.where((s) => s.available).toList();
  if (available.isEmpty) {
    return _SummaryChipPresentation(
      label: 'No agents found',
      accent: scheme.onSurfaceVariant,
    );
  }
  final needsSetup = available.any(
    (s) =>
        s.state == 'not-installed' || s.state == 'stale' || s.state == 'error',
  );
  if (needsSetup) {
    return _SummaryChipPresentation(
      label: 'Hooks need setup',
      accent: scheme.tertiary,
      showDot: true,
    );
  }
  return _SummaryChipPresentation(
    label: 'Hooks ready',
    accent: scheme.primary,
    showDot: true,
  );
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
