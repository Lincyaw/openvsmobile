// Plugins tab (design §3 / issue C4).
//
// Two screens behind a single tab slot:
//
//   * `PluginsTab` — list view of installed plugins. Tap a row to drill
//     into the detail view.
//   * `PluginDetailScreen` — header bar + body. Body renders the
//     plugin's panels through the shared `UiRenderer` from C3. Multiple
//     panels become a `TabBar`. A `crashed` plugin renders a banner
//     + Reload button instead.
//
// State sourcing: AppState owns the PluginsModel + UiPanelsModel; this
// screen only listens. Per CLAUDE.md first principle #1, the backend is
// the source of truth — we never optimistically mutate `_byId`. Toggle
// switches call `plugin.enable` / `plugin.disable` and rely on the
// matching `plugin.stateChanged` push to flip the wire-state.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/plugins_model.dart';
import '../ui/ui_node.dart';
import '../ui/ui_renderer.dart';

const String _kFilesystemPluginsDir =
    '~/.local/share/openvsmobile-next/plugins/';

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
        return ListView.separated(
          itemCount: plugins.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final p = plugins[i];
            return _PluginListTile(
              info: p,
              onTap: () => _openDetail(context, p),
              onToggle: (enabled) => _onToggle(context, p, enabled),
            );
          },
        );
      },
    );
  }

  Future<void> _onToggle(
    BuildContext context, PluginInfo info, bool enabled) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (enabled) {
        await appState.plugins.enable(info.id);
      } else {
        await appState.plugins.disable(info.id);
      }
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Failed to ${enabled ? "enable" : "disable"} ${info.name}: $e')),
      );
    }
  }

  void _openDetail(BuildContext context, PluginInfo info) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PluginDetailScreen(appState: appState, pluginId: info.id),
      ),
    );
  }
}

class _PluginListTile extends StatelessWidget {
  final PluginInfo info;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  const _PluginListTile({
    required this.info,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDisabled = info.state == PluginWireState.disabled;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      decoration: isDisabled ? TextDecoration.lineThrough : null,
      color: isDisabled ? theme.disabledColor : null,
    );
    return ListTile(
      key: ValueKey<String>('plugin-row:${info.id}'),
      onTap: onTap,
      title: Row(
        children: [
          Expanded(
            child: Text(
              info.name,
              style: titleStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            info.version,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      subtitle: PluginStateBadge(state: info.state, reason: info.crashReason),
      trailing: Switch(
        key: ValueKey<String>('plugin-toggle:${info.id}'),
        value: info.state != PluginWireState.disabled,
        onChanged: onToggle,
      ),
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
    final (label, color) = switch (state) {
      PluginWireState.running => ('running', Colors.green),
      PluginWireState.stopped => ('stopped', theme.disabledColor),
      PluginWireState.crashed => ('crashed', theme.colorScheme.error),
      PluginWireState.disabled => ('disabled', theme.disabledColor),
      PluginWireState.unknown => ('unknown', theme.disabledColor),
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
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodySmall),
        if (state == PluginWireState.crashed &&
            reason != null && reason!.isNotEmpty) ...[
          const SizedBox(width: 6),
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.extension_outlined, size: 48, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              loaded ? 'No plugins installed' : 'Loading plugins…',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Drop a plugin directory under $_kFilesystemPluginsDir on the '
              'backend host. Workbench will pick it up on the next backend '
              'restart.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Detail view ----

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
        actions: [
          _PluginKebabMenu(appState: appState, info: info),
        ],
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
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Plugin log: $path')),
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
            await _safeCall(context, () => appState.plugins.disable(info.id),
                label: 'Disable ${info.name}');
            break;
          case 'enable':
            await _safeCall(context, () => appState.plugins.enable(info.id),
                label: 'Enable ${info.name}');
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
            tabs: [
              for (final p in panels) Tab(text: p.title),
            ],
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
      padding: const EdgeInsets.all(12),
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
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty_outlined,
                size: 36, color: Theme.of(context).hintColor),
            const SizedBox(height: 8),
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
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PluginStateBadge(state: info.state),
            const SizedBox(height: 12),
            Text(
              '"${info.name}" does not contribute any panels.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'It may still respond to commands; the Plugins tab only '
              'renders panels.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
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
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PluginStateBadge(state: info.state),
            const SizedBox(height: 12),
            Text(
              '"${info.name}" is disabled.',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
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
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Plugin log: $path')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey<String>('plugin-crashed-banner'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
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
                const SizedBox(height: 8),
                Text(
                  'There is no automatic restart. Inspect the log to see '
                  'why this plugin exited, then tap Reload once you have '
                  'a fix in place.',
                  style: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey<String>('plugin-view-log'),
                      onPressed: () => _showLog(context),
                      child: const Text('View log'),
                    ),
                    const SizedBox(width: 8),
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
