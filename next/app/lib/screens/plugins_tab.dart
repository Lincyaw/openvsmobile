// Plugins tab (design §3 / issue C4).
//
// App-grid layout: every installed plugin gets an icon card. Tapping an
// enabled plugin drills into its panel host (`PluginDetailScreen`);
// tapping a disabled plugin drills into the info screen
// (`PluginInfoScreen`) which exposes Enable/Disable + capability chips
// + the filesystem path hint. Long-pressing any card opens a
// BottomSheet with the same enable/disable affordance.
//
// State sourcing: AppState owns the PluginsModel + UiPanelsModel; this
// screen only listens. Per CLAUDE.md first principle #1, the backend is
// the source of truth — we never optimistically mutate `_byId`. Toggle
// affordances call `plugin.enable` / `plugin.disable` and rely on the
// matching `plugin.stateChanged` push to flip the wire-state.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/plugins_model.dart';
import '../ui/app_tokens.dart';
import '../ui/ui_node.dart';
import '../ui/ui_renderer.dart';

const String _kFilesystemPluginsDir =
    '~/.local/share/openvsmobile-next/plugins/';

/// Breakpoint between phone-portrait and wider layouts. Anything below
/// renders 3 columns; anything at-or-above renders 5.
const double _kGridWideBreakpoint = 600;

class PluginsTab extends StatelessWidget {
  final AppState appState;
  const PluginsTab({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final model = appState.plugins;
        final plugins = model.plugins;
        if (plugins.isEmpty) {
          return _PluginsEmptyState(loaded: model.isLoaded);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= _kGridWideBreakpoint
                ? 5
                : 3;
            return GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.md),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.85,
              ),
              itemCount: plugins.length,
              itemBuilder: (context, i) {
                final p = plugins[i];
                return _PluginGridCard(
                  info: p,
                  onTap: () => _openPrimary(context, p),
                  onLongPress: () => _showActionSheet(context, p),
                  onToggle: (enabled) => _onToggle(context, p, enabled),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _onToggle(
    BuildContext context,
    PluginInfo info,
    bool enabled,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (enabled) {
        await appState.plugins.enable(info.id);
      } else {
        await appState.plugins.disable(info.id);
      }
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to ${enabled ? "enable" : "disable"} ${info.name}: $e',
          ),
        ),
      );
    }
  }

  /// Primary tap target: enabled plugins go straight to their panel host;
  /// disabled plugins go to the info screen so the user can enable them.
  void _openPrimary(BuildContext context, PluginInfo info) {
    if (info.state == PluginWireState.disabled) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              PluginInfoScreen(appState: appState, pluginId: info.id),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PluginDetailScreen(appState: appState, pluginId: info.id),
      ),
    );
  }

  void _showActionSheet(BuildContext context, PluginInfo info) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => _PluginActionSheet(
        info: info,
        onEnable: () async {
          Navigator.of(sheetContext).pop();
          await _onToggle(context, info, true);
        },
        onDisable: () async {
          Navigator.of(sheetContext).pop();
          await _onToggle(context, info, false);
        },
        onOpenInTerminal: () async {
          Navigator.of(sheetContext).pop();
          final cmd = 'cd $_kFilesystemPluginsDir${info.id}';
          await Clipboard.setData(ClipboardData(text: cmd));
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text('Copied to clipboard: $cmd')),
            );
          }
        },
      ),
    );
  }
}

class _PluginGridCard extends StatelessWidget {
  final PluginInfo info;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool> onToggle;
  const _PluginGridCard({
    required this.info,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = info.state != PluginWireState.disabled;
    final isCrashed = info.state == PluginWireState.crashed;

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        key: ValueKey<String>('plugin-card:${info.id}'),
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outline, width: 1),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top row: status dot + tiny toggle keeps the contract that
              // `plugin-toggle:<id>` Switch is reachable from the main view.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    key: ValueKey<String>('plugin-card-dot:${info.id}'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dotColor(theme, info.state),
                    ),
                  ),
                  Transform.scale(
                    scale: 0.7,
                    alignment: Alignment.centerRight,
                    child: Switch(
                      key: ValueKey<String>('plugin-toggle:${info.id}'),
                      value: isEnabled,
                      onChanged: onToggle,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: _PluginIconAvatar(info: info, dim: !isEnabled),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                info.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isEnabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              // Status badge — preserves wire-state labels and crash
              // reason text required by the contract tests.
              Center(
                child: PluginStateBadge(
                  state: info.state,
                  reason: isCrashed ? info.crashReason : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _dotColor(ThemeData theme, PluginWireState state) {
    switch (state) {
      case PluginWireState.running:
        return theme.colorScheme.primary;
      case PluginWireState.crashed:
        return theme.colorScheme.error;
      case PluginWireState.stopped:
      case PluginWireState.disabled:
      case PluginWireState.unknown:
        return theme.colorScheme.outlineVariant;
    }
  }
}

class _PluginIconAvatar extends StatelessWidget {
  final PluginInfo info;
  final bool dim;
  const _PluginIconAvatar({required this.info, required this.dim});

  @override
  Widget build(BuildContext context) {
    // Manifest schema has no `icon` field in v0; we render a neutral
    // Material glyph that signals "plugin" regardless of identity. The
    // background tint keeps cards visually distinct from the page
    // surface without introducing per-plugin theming.
    final scheme = Theme.of(context).colorScheme;
    final fg = dim ? scheme.onSurfaceVariant : scheme.onSurface;
    return Container(
      width: AppIconSize.lg,
      height: AppIconSize.lg,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: scheme.outline, width: 1),
      ),
      child: Icon(Icons.extension, size: AppIconSize.md, color: fg),
    );
  }
}

class PluginStateBadge extends StatelessWidget {
  final PluginWireState state;
  final String? reason;
  const PluginStateBadge({super.key, required this.state, this.reason});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color) = switch (state) {
      PluginWireState.running => ('running', scheme.primary),
      PluginWireState.stopped => ('stopped', scheme.onSurfaceVariant),
      PluginWireState.crashed => ('crashed', scheme.error),
      PluginWireState.disabled => ('disabled', scheme.onSurfaceVariant),
      PluginWireState.unknown => ('unknown', scheme.onSurfaceVariant),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: ValueKey<String>('plugin-state-dot:$label'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: theme.textTheme.bodySmall),
        if (state == PluginWireState.crashed &&
            reason != null &&
            reason!.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              reason!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ],
    );
  }
}

class _PluginsEmptyState extends StatelessWidget {
  final bool loaded;
  const _PluginsEmptyState({required this.loaded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.extension_outlined,
              size: AppIconSize.lg,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              loaded ? 'No plugins installed' : 'Loading plugins…',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Drop a plugin directory into',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _kFilesystemPluginsDir,
              textAlign: TextAlign.center,
              style: AppText.mono(fontSize: 13, color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Action sheet (long-press) ----

class _PluginActionSheet extends StatelessWidget {
  final PluginInfo info;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onOpenInTerminal;
  const _PluginActionSheet({
    required this.info,
    required this.onEnable,
    required this.onDisable,
    required this.onOpenInTerminal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = info.state != PluginWireState.disabled;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(info.name, style: theme.textTheme.titleMedium),
                ),
                Text(
                  info.version,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            key: ValueKey<String>('plugin-sheet-toggle:${info.id}'),
            leading: Icon(
              isEnabled ? Icons.toggle_off_outlined : Icons.toggle_on_outlined,
            ),
            title: Text(isEnabled ? 'Disable' : 'Enable'),
            onTap: isEnabled ? onDisable : onEnable,
          ),
          ListTile(
            key: ValueKey<String>('plugin-sheet-terminal:${info.id}'),
            leading: const Icon(Icons.terminal),
            title: const Text('Copy cd command'),
            subtitle: Text(
              '$_kFilesystemPluginsDir${info.id}',
              style: AppText.mono(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: onOpenInTerminal,
          ),
        ],
      ),
    );
  }
}

// ---- Info screen (disabled-plugin landing + metadata) ----

class PluginInfoScreen extends StatelessWidget {
  final AppState appState;
  final String pluginId;
  const PluginInfoScreen({
    super.key,
    required this.appState,
    required this.pluginId,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final info = appState.plugins.plugin(pluginId);
        if (info == null) {
          return Scaffold(
            appBar: AppBar(title: Text(pluginId)),
            body: const Center(child: Text('Plugin not found')),
          );
        }
        return PluginInfoView(appState: appState, info: info);
      },
    );
  }
}

/// Exposed for widget tests so they can mount the info view without
/// pushing through Navigator.
class PluginInfoView extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const PluginInfoView({super.key, required this.appState, required this.info});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = info.state != PluginWireState.disabled;
    return Scaffold(
      appBar: AppBar(title: Text(info.name)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PluginIconAvatar(info: info, dim: !isEnabled),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(info.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Text(
                          info.version,
                          style: AppText.mono(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: ValueKey<String>('plugin-info-toggle:${info.id}'),
              onPressed: () => _safeCall(
                context,
                () => isEnabled
                    ? appState.plugins.disable(info.id)
                    : appState.plugins.enable(info.id),
                label: '${isEnabled ? "Disable" : "Enable"} ${info.name}',
              ),
              child: Text(isEnabled ? 'Disable' : 'Enable'),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionTitle('Capabilities'),
          const SizedBox(height: AppSpacing.sm),
          _CapabilityChips(capabilities: info.capabilities),
          const SizedBox(height: AppSpacing.xl),
          _SectionTitle('Panels'),
          const SizedBox(height: AppSpacing.sm),
          if (info.panels.isEmpty)
            Text(
              'No panels contributed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final p in info.panels) Chip(label: Text(p.title)),
              ],
            ),
          const SizedBox(height: AppSpacing.xl),
          _SectionTitle('Commands'),
          const SizedBox(height: AppSpacing.sm),
          if (info.commands.isEmpty)
            Text(
              'No commands contributed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final c in info.commands) Chip(label: Text(c.title)),
              ],
            ),
          const SizedBox(height: AppSpacing.xl),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Installed at',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '$_kFilesystemPluginsDir${info.id}/',
            style: AppText.mono(
              fontSize: 13,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Install and uninstall are filesystem operations — '
            'cp/rm directories under the path above.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _CapabilityChips extends StatelessWidget {
  final Map<String, dynamic> capabilities;
  const _CapabilityChips({required this.capabilities});

  @override
  Widget build(BuildContext context) {
    final declared = <String>[];
    // Known capability keys in the v0 manifest (see backend
    // ManifestCapabilities). `fs` is tri-state; everything else is a
    // boolean. Anything else surfaced by a newer backend appears as a
    // generic chip so the row stays informative.
    const knownBoolKeys = ['terminal', 'network', 'secrets', 'ui'];
    final fs = capabilities['fs'];
    if (fs is String && fs.isNotEmpty && fs != 'none') {
      declared.add('fs: $fs');
    }
    for (final k in knownBoolKeys) {
      if (capabilities[k] == true) declared.add(k);
    }
    for (final entry in capabilities.entries) {
      if (entry.key == 'fs') continue;
      if (knownBoolKeys.contains(entry.key)) continue;
      if (entry.value == true) declared.add(entry.key);
    }
    if (declared.isEmpty) {
      final theme = Theme.of(context);
      return Text(
        'No capabilities declared.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [for (final label in declared) Chip(label: Text(label))],
    );
  }
}

// ---- Panel host (existing — drilled into for enabled plugins) ----

class PluginDetailScreen extends StatelessWidget {
  final AppState appState;
  final String pluginId;
  const PluginDetailScreen({
    super.key,
    required this.appState,
    required this.pluginId,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final info = appState.plugins.plugin(pluginId);
        if (info == null) {
          return Scaffold(
            appBar: AppBar(title: Text(pluginId)),
            body: const Center(child: Text('Plugin not found')),
          );
        }
        return PluginDetailView(appState: appState, info: info);
      },
    );
  }
}

/// Inner detail view exposed for widget tests so they can mount it
/// without pushing through Navigator. Production code goes through
/// `PluginDetailScreen` which adapts to live state changes.
class PluginDetailView extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const PluginDetailView({
    super.key,
    required this.appState,
    required this.info,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(info.name),
        actions: [_PluginKebabMenu(appState: appState, info: info)],
      ),
      body: _DetailBody(appState: appState, info: info),
    );
  }
}

class _PluginKebabMenu extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _PluginKebabMenu({required this.appState, required this.info});

  void _showLogPath(BuildContext context) {
    // The host writes stderr logs to
    // ~/.local/state/openvsmobile-next/plugins/<id>.stderr.log
    // (see host.ts). No in-app viewer in v0 — settled decision; we
    // surface the path so the user knows where to tail.
    final path =
        '~/.local/state/openvsmobile-next/plugins/${info.id}.stderr.log';
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Plugin log: $path')));
  }

  @override
  Widget build(BuildContext context) {
    final enabled = info.state != PluginWireState.disabled;
    return PopupMenuButton<String>(
      key: const ValueKey<String>('plugin-kebab'),
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: enabled ? 'disable' : 'enable',
          child: Text(enabled ? 'Disable' : 'Enable'),
        ),
        const PopupMenuItem<String>(
          value: 'log',
          child: Text('View stderr log location'),
        ),
      ],
      onSelected: (v) async {
        switch (v) {
          case 'disable':
            await _safeCall(
              context,
              () => appState.plugins.disable(info.id),
              label: 'Disable ${info.name}',
            );
            break;
          case 'enable':
            await _safeCall(
              context,
              () => appState.plugins.enable(info.id),
              label: 'Enable ${info.name}',
            );
            break;
          case 'log':
            _showLogPath(context);
            break;
        }
      },
    );
  }
}

Future<void> _safeCall(
  BuildContext context,
  Future<void> Function() op, {
  required String label,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await op();
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$label failed: $e')));
  }
}

class _DetailBody extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _DetailBody({required this.appState, required this.info});

  @override
  Widget build(BuildContext context) {
    if (info.state == PluginWireState.crashed) {
      return _CrashedBanner(appState: appState, info: info);
    }
    if (info.state == PluginWireState.disabled) {
      return _DisabledHint(appState: appState, info: info);
    }
    final panels = info.panels;
    if (panels.isEmpty) {
      return _NoPanelsHint(info: info);
    }
    if (panels.length == 1) {
      return _PanelRenderer(
        appState: appState,
        pluginId: info.id,
        panel: panels.single,
      );
    }
    return DefaultTabController(
      length: panels.length,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabs: [for (final p in panels) Tab(text: p.title)],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final p in panels)
                  _PanelRenderer(
                    appState: appState,
                    pluginId: info.id,
                    panel: p,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelRenderer extends StatelessWidget {
  final AppState appState;
  final String pluginId;
  final PluginPanelStub panel;
  const _PanelRenderer({
    required this.appState,
    required this.pluginId,
    required this.panel,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = appState.uiPanels.snapshotFor(pluginId, panel.id);
    final tree = snapshot?.tree;
    if (tree == null) {
      return _PanelEmpty(title: panel.title);
    }
    return SingleChildScrollView(
      key: ValueKey<String>('plugin-panel:$pluginId/${panel.id}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: UiRenderer(
        tree: tree,
        onEvent: (event) => _dispatch(panel.id, event),
      ),
    );
  }

  void _dispatch(String panelId, UiNodeEvent event) {
    appState.uiPanels.dispatchEvent(
      pluginId: pluginId,
      panelId: panelId,
      event: event,
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  final String title;
  const _PanelEmpty({required this.title});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_empty_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Waiting for "$title" content from the plugin…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPanelsHint extends StatelessWidget {
  final PluginInfo info;
  const _NoPanelsHint({required this.info});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PluginStateBadge(state: info.state),
            const SizedBox(height: AppSpacing.md),
            Text(
              '"${info.name}" does not contribute any panels.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'It may still respond to commands; the Plugins tab only '
              'renders panels.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (info.commands.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  for (final c in info.commands) Chip(label: Text(c.title)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DisabledHint extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _DisabledHint({required this.appState, required this.info});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PluginStateBadge(state: info.state),
            const SizedBox(height: AppSpacing.md),
            Text(
              '"${info.name}" is disabled.',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: () => _safeCall(
                context,
                () => appState.plugins.enable(info.id),
                label: 'Enable ${info.name}',
              ),
              child: const Text('Enable'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CrashedBanner extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _CrashedBanner({required this.appState, required this.info});

  void _showLog(BuildContext context) {
    final path =
        '~/.local/state/openvsmobile-next/plugins/${info.id}.stderr.log';
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Plugin log: $path')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey<String>('plugin-crashed-banner'),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plugin crashed: ${info.crashReason ?? "unknown reason"}',
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'There is no automatic restart. Inspect the log to see '
                  'why this plugin exited, then tap Reload once you have '
                  'a fix in place.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey<String>('plugin-view-log'),
                      onPressed: () => _showLog(context),
                      child: const Text('View log'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      key: const ValueKey<String>('plugin-reload'),
                      onPressed: () => _safeCall(
                        context,
                        () => appState.plugins.reload(info.id),
                        label: 'Reload ${info.name}',
                      ),
                      child: const Text('Reload'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
