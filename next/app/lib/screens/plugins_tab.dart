// Plugins tab (design §3 / issue C4; Batch 1 — §4.3).
//
// Renders the installed-plugin catalog through the same `UiAppGrid`
// renderer that ships in the widget vocabulary for plugin-authored
// panels — eating our own dogfood proves the new widget works against
// real data, not just synthetic tests.
//
// Tapping a tile drills into the existing detail screen (info screen
// for disabled plugins, panel host for enabled). The enable/disable
// switch now lives only in the detail screen — Batch 1 spec moved it
// off the grid tile.
//
// State sourcing: AppState owns the PluginsModel + UiPanelsModel; this
// screen only listens. Per CLAUDE.md first principle #1, the backend is
// the source of truth — we never optimistically mutate `_byId`. Toggle
// affordances call `plugin.enable` / `plugin.disable` and rely on the
// matching `plugin.stateChanged` push to flip the wire-state.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/plugins_model.dart';
import '../ui/app_tokens.dart';
import '../ui/ui_modal_renderer.dart';
import '../ui/ui_node.dart';
import '../ui/ui_renderer.dart';

const String _kFilesystemPluginsDir =
    '~/.local/share/openvsmobile-next/plugins/';

/// Stable id for the host-emitted Plugins app-grid. Stays constant across
/// re-renders so the renderer's reconciliation keeps grid scroll position.
const String _kPluginsGridId = 'host.plugins.grid';

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
        final grid = _buildGrid(plugins);
        return SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: UiRenderer(
            tree: grid,
            onEvent: (e) => _onGridEvent(context, plugins, e),
            // Long-press on a launcher tile opens the contextual action
            // sheet (Enable/Disable + Copy cd command), matching the
            // iOS / WeChat launcher gesture. The hook is screen-local
            // (not part of the UiAppGrid wire contract) — plugin-
            // authored UiAppGrid panels don't carry this affordance.
            // TODO(batch 4 SwipeAction): once UiAppGrid grows an
            // onLongPressEvent, drive this through the widget.
            onAppTileLongPress: (gridId, tileId) =>
                _showActionSheet(context, plugins, tileId),
          ),
        );
      },
    );
  }

  UiAppGrid _buildGrid(List<PluginInfo> plugins) {
    return UiAppGrid(
      id: _kPluginsGridId,
      onLaunchEvent: 'launch',
      items: [
        for (final p in plugins)
          UiAppTile(
            id: p.id,
            name: p.name,
            icon: const UiAppTileIconName('package'),
            badge: _badgeFor(p),
            // Per-plugin themeColor flows through the AccentToken.brand
            // path inside the detail screen — here on the grid we keep
            // the app's primary so the launcher reads as one product.
            accent: AccentToken.brand,
          ),
      ],
    );
  }

  /// Wire-state → tile-corner badge. Only `crashed` raises a badge in
  /// Batch 1 (a single `!` text); the slim [UiAppTileBadge] shape from
  /// the doc spec (`{ count?, text? }`) doesn't carry an accent or
  /// variant, so visual differentiation across the other wire states
  /// stays in the detail screen, not on the launcher tile.
  UiAppTileBadge? _badgeFor(PluginInfo p) {
    switch (p.state) {
      case PluginWireState.crashed:
        return const UiAppTileBadge(text: '!');
      case PluginWireState.disabled:
      case PluginWireState.running:
      case PluginWireState.stopped:
      case PluginWireState.unknown:
        return null;
    }
  }

  void _onGridEvent(
    BuildContext context,
    List<PluginInfo> plugins,
    UiNodeEvent event,
  ) {
    final tileId = event.payload?['tileId'];
    if (tileId is! String) return;
    final info = plugins.firstWhere(
      (p) => p.id == tileId,
      orElse: () => plugins.first,
    );
    _openPrimary(context, info);
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

  void _showActionSheet(
    BuildContext context,
    List<PluginInfo> plugins,
    String tileId,
  ) {
    final info = plugins.firstWhere(
      (p) => p.id == tileId,
      orElse: () => plugins.first,
    );
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

/// Long-press contextual sheet on a launcher tile. Surfaces the
/// Enable/Disable toggle and a "copy cd command" shortcut so the user
/// can jump into the plugin's directory from a terminal without
/// retyping the path. Restored in the review pass — pre-Batch-1 had
/// this gesture and the launcher feels much worse without it.
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
              style: AppText.monoCaption(
                context,
              ).copyWith(color: theme.colorScheme.onSurfaceVariant),
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
              style: AppText.monoCode(
                context,
              ).copyWith(color: scheme.onSurface),
            ),
          ],
        ),
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
                          style: AppText.monoCaption(
                            context,
                          ).copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                for (final c in info.commands)
                  ActionChip(
                    key: ValueKey<String>('plugin-command:${info.id}:${c.id}'),
                    label: Text(c.title),
                    onPressed: () => _invokeCommand(context, appState, info, c),
                  ),
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
            style: AppText.monoCode(
              context,
            ).copyWith(color: theme.colorScheme.onSurface),
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
    return _PluginThemeScope(
      themeColor: info.themeColor,
      child: Scaffold(
        appBar: AppBar(
          title: Text(info.name),
          actions: [_PluginKebabMenu(appState: appState, info: info)],
        ),
        body: _DetailBody(appState: appState, info: info),
      ),
    );
  }
}

/// Per-plugin `Theme` override (Batch 1 — design §4.3). When a plugin
/// declares `themeColor` in its manifest, we scope a fresh ColorScheme
/// with `primary` swapped to the plugin's color so the `brand`
/// `AccentToken` resolves inside the plugin's panel only. Plugins
/// without a `themeColor` get the surrounding theme verbatim.
///
/// Scope is the panel host (`PluginDetailView`) only — the brand color
/// is for the plugin's content surface, not its metadata card. The
/// info screen (`PluginInfoView`, for disabled plugins) deliberately
/// inherits the app's default theme so the metadata reads as host
/// chrome, not plugin chrome.
class _PluginThemeScope extends StatelessWidget {
  final String? themeColor;
  final Widget child;
  const _PluginThemeScope({required this.themeColor, required this.child});

  @override
  Widget build(BuildContext context) {
    final resolved = resolvePluginThemeColor(themeColor);
    if (resolved == null) return child;
    final base = Theme.of(context);
    final scheme = base.colorScheme.copyWith(primary: resolved);
    return Theme(
      data: base.copyWith(colorScheme: scheme),
      child: child,
    );
  }
}

class _PluginKebabMenu extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _PluginKebabMenu({required this.appState, required this.info});

  void _openLog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PluginLogScreen(appState: appState, info: info),
      ),
    );
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
            _openLog(context);
            break;
        }
      },
    );
  }
}

class PluginLogScreen extends StatefulWidget {
  final AppState appState;
  final PluginInfo info;

  const PluginLogScreen({
    super.key,
    required this.appState,
    required this.info,
  });

  @override
  State<PluginLogScreen> createState() => _PluginLogScreenState();
}

class _PluginLogScreenState extends State<PluginLogScreen> {
  late Future<PluginLogTail> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<PluginLogTail> _load() {
    return widget.appState.plugins.fetchLog(widget.info.id);
  }

  void _refresh() {
    setState(() => _future = _load());
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Copied $label')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.info.name} log'),
        actions: [
          IconButton(
            tooltip: 'Refresh log',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<PluginLogTail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _PluginLogError(error: snapshot.error, onRetry: _refresh);
          }
          final log = snapshot.data;
          if (log == null) {
            return _PluginLogError(error: 'No log response', onRetry: _refresh);
          }
          return _PluginLogView(
            log: log,
            onCopyPath: () => _copy('path', log.path),
            onCopyText: log.text.isEmpty ? null : () => _copy('log', log.text),
          );
        },
      ),
    );
  }
}

class _PluginLogError extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const _PluginLogError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: AppIconSize.lg,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Could not load plugin log',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PluginLogView extends StatelessWidget {
  final PluginLogTail log;
  final VoidCallback onCopyPath;
  final VoidCallback? onCopyText;

  const _PluginLogView({
    required this.log,
    required this.onCopyPath,
    required this.onCopyText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = log.bytes == 0
        ? 'No stderr output yet'
        : '${log.bytes} bytes${log.truncated ? ' · showing tail' : ''}';
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Log file', style: theme.textTheme.labelLarge),
        const SizedBox(height: AppSpacing.xs),
        SelectableText(
          log.path,
          style: AppText.monoCaption(
            context,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            OutlinedButton.icon(
              onPressed: onCopyPath,
              icon: const Icon(Icons.copy),
              label: const Text('Copy path'),
            ),
            OutlinedButton.icon(
              onPressed: onCopyText,
              icon: const Icon(Icons.content_copy),
              label: const Text('Copy log'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(meta, style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: SelectableText(
            log.text.isEmpty ? 'No stderr output yet.' : log.text,
            style: AppText.monoCode(context),
          ),
        ),
      ],
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

Future<void> _invokeCommand(
  BuildContext context,
  AppState appState,
  PluginInfo info,
  PluginCommandStub command,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await appState.plugins.invokeCommand(info.id, command.id);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Invoked ${command.title}')));
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Command ${command.title} failed: $e')),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _DetailBody({required this.appState, required this.info});

  @override
  Widget build(BuildContext context) {
    if (info.state == PluginWireState.disabled) {
      return _DisabledHint(appState: appState, info: info);
    }
    final frozen = info.state == PluginWireState.crashed;
    final body = _buildPanelBody(frozen: frozen);
    if (frozen) {
      return Column(
        children: [
          _CrashedBanner(appState: appState, info: info),
          if (info.panels.isNotEmpty) Expanded(child: body),
        ],
      );
    }
    return body;
  }

  Widget _buildPanelBody({required bool frozen}) {
    final panels = info.panels;
    if (panels.isEmpty) {
      return _NoPanelsHint(appState: appState, info: info);
    }
    if (panels.length == 1) {
      return _PanelRenderer(
        appState: appState,
        pluginId: info.id,
        panel: panels.single,
        frozen: frozen,
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
                    frozen: frozen,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelRenderer extends StatefulWidget {
  final AppState appState;
  final String pluginId;
  final PluginPanelStub panel;
  final bool frozen;
  const _PanelRenderer({
    required this.appState,
    required this.pluginId,
    required this.panel,
    this.frozen = false,
  });

  @override
  State<_PanelRenderer> createState() => _PanelRendererState();
}

class _PanelRendererState extends State<_PanelRenderer> {
  StreamSubscription<UiModalPush>? _modalSub;

  @override
  void initState() {
    super.initState();
    widget.appState.uiPanels.addListener(_onPanelsChanged);
    _attachModalListener();
  }

  @override
  void didUpdateWidget(covariant _PanelRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState.uiPanels != widget.appState.uiPanels) {
      oldWidget.appState.uiPanels.removeListener(_onPanelsChanged);
      widget.appState.uiPanels.addListener(_onPanelsChanged);
      _modalSub?.cancel();
      _attachModalListener();
    }
  }

  @override
  void dispose() {
    widget.appState.uiPanels.removeListener(_onPanelsChanged);
    _modalSub?.cancel();
    super.dispose();
  }

  void _attachModalListener() {
    _modalSub = widget.appState.uiPanels.modals.listen((push) {
      if (widget.frozen) return;
      // Filter to this panel only. The model broadcasts every modal to
      // every listener; routing happens here so a panel that isn't this
      // (pluginId, panelId) doesn't open another panel's dialog.
      if (push.pluginId != widget.pluginId) return;
      if (push.panelId != widget.panel.id) return;
      if (!mounted) return;
      // showUiModal owns the modal lifecycle: it picks the right
      // platform widget (AlertDialog / ActionSheet / BottomSheet), wires
      // up dismissal, and dispatches the resulting eventId back through
      // UiPanelsModel.dispatchEvent.
      showUiModal(
        context: context,
        push: push,
        onEvent: (event) => widget.appState.uiPanels.dispatchEvent(
          pluginId: widget.pluginId,
          panelId: widget.panel.id,
          event: event,
        ),
      );
    });
  }

  void _onPanelsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.appState.uiPanels.snapshotFor(
      widget.pluginId,
      widget.panel.id,
    );
    final tree = snapshot?.tree;
    if (tree == null) {
      return _PanelEmpty(
        title: widget.panel.title,
        hasSnapshot: snapshot != null,
        panelCount: widget.appState.uiPanels.panels.length,
      );
    }
    final renderer = UiRenderer(
      tree: tree,
      onEvent: widget.frozen
          ? (_) {}
          : (event) => _dispatch(widget.panel.id, event),
    );
    return SingleChildScrollView(
      key: ValueKey<String>(
        'plugin-panel:${widget.pluginId}/${widget.panel.id}',
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: widget.frozen
          ? AbsorbPointer(child: Opacity(opacity: 0.72, child: renderer))
          : renderer,
    );
  }

  void _dispatch(String panelId, UiNodeEvent event) {
    widget.appState.uiPanels.dispatchEvent(
      pluginId: widget.pluginId,
      panelId: panelId,
      event: event,
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  final String title;
  final bool hasSnapshot;
  final int panelCount;
  const _PanelEmpty({
    required this.title,
    this.hasSnapshot = false,
    this.panelCount = 0,
  });
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
            const SizedBox(height: AppSpacing.sm),
            Text(
              'snapshot=${hasSnapshot ? "yes" : "no"}  panels=$panelCount',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPanelsHint extends StatelessWidget {
  final AppState appState;
  final PluginInfo info;
  const _NoPanelsHint({required this.appState, required this.info});
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
                  for (final c in info.commands)
                    ActionChip(
                      key: ValueKey<String>(
                        'plugin-command:${info.id}:${c.id}',
                      ),
                      label: Text(c.title),
                      onPressed: () =>
                          _invokeCommand(context, appState, info, c),
                    ),
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PluginLogScreen(appState: appState, info: info),
      ),
    );
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
