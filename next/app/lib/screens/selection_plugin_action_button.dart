import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/plugins_model.dart';

class SelectionPluginActionButton extends StatelessWidget {
  final AppState appState;

  const SelectionPluginActionButton({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final selection = appState.selectionContext;
        final targets = _commandTargets(appState.plugins.plugins);
        return PopupMenuButton<_SelectionCommandTarget>(
          key: const ValueKey<String>('selection-plugin-actions'),
          tooltip: selection == null
              ? 'Select text to send to a plugin'
              : 'Send selection to plugin',
          enabled: selection != null && targets.isNotEmpty,
          icon: const Icon(Icons.extension_outlined),
          onSelected: (target) => _invoke(context, target),
          itemBuilder: (context) {
            if (targets.isEmpty) {
              return const [
                PopupMenuItem<_SelectionCommandTarget>(
                  enabled: false,
                  child: Text('No plugin commands'),
                ),
              ];
            }
            return [
              for (final target in targets)
                PopupMenuItem<_SelectionCommandTarget>(
                  key: ValueKey<String>(
                    'selection-plugin-command:${target.plugin.id}:${target.command.id}',
                  ),
                  value: target,
                  child: Text('${target.plugin.name}: ${target.command.title}'),
                ),
            ];
          },
        );
      },
    );
  }

  List<_SelectionCommandTarget> _commandTargets(List<PluginInfo> plugins) {
    final out = <_SelectionCommandTarget>[];
    for (final plugin in plugins) {
      final commandable =
          plugin.state == PluginWireState.running ||
          plugin.state == PluginWireState.stopped;
      if (!commandable) continue;
      for (final command in plugin.commands) {
        out.add(_SelectionCommandTarget(plugin: plugin, command: command));
      }
    }
    return out;
  }

  Future<void> _invoke(
    BuildContext context,
    _SelectionCommandTarget target,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await appState.invokePluginCommandWithSelection(
        pluginId: target.plugin.id,
        commandId: target.command.id,
      );
      messenger?.showSnackBar(
        SnackBar(content: Text('Sent selection to ${target.plugin.name}')),
      );
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Command failed: $e')));
    }
  }
}

class _SelectionCommandTarget {
  final PluginInfo plugin;
  final PluginCommandStub command;

  const _SelectionCommandTarget({required this.plugin, required this.command});
}
