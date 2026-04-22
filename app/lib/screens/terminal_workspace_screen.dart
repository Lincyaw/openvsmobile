import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/terminal_provider.dart';
import '../providers/workspace_provider.dart';
import '../services/settings_service.dart';
import '../widgets/terminal_pane.dart';
import '../widgets/terminal_session_list.dart';

class TerminalWorkspaceScreen extends StatefulWidget {
  const TerminalWorkspaceScreen({super.key, required this.isActive});

  final bool isActive;

  @override
  State<TerminalWorkspaceScreen> createState() => _TerminalWorkspaceScreenState();
}

class _TerminalWorkspaceScreenState extends State<TerminalWorkspaceScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureProvider();
  }

  @override
  void didUpdateWidget(covariant TerminalWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _configureProvider(ensureInitialized: true);
    }
  }

  void _configureProvider({bool ensureInitialized = false}) {
    final settings = context.read<SettingsService>();
    final workspace = context.read<WorkspaceProvider>();
    final provider = context.read<TerminalProvider>();
    provider.configure(
      baseUrl: settings.serverUrl,
      token: settings.authToken,
      workDir: workspace.currentPath,
    );
    if (widget.isActive || ensureInitialized) {
      Future.microtask(provider.ensureInitialized);
    }
  }

  Future<void> _showNameDialog({
    required String title,
    String? initialValue,
    required ValueChanged<String> onConfirm,
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Session name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) {
      return;
    }
    onConfirm(value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TerminalProvider>();
    final workspace = context.watch<WorkspaceProvider>();

    final active = provider.activeSession;
    final secondary = provider.hasSecondarySession ? provider.secondarySession : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 900;
        final panes = <Widget>[
          if (active != null)
            TerminalPane(
              sessionId: active.session.id,
              view: active,
              isActive: true,
              onSubmit: (input) {
                unawaited(provider.sendInput(active.session.id, input));
              },
              onSendRaw: (input) {
                unawaited(provider.sendInput(active.session.id, input));
              },
              onDraftChanged: (value) =>
                  provider.setInputDraft(active.session.id, value),
              onResize: (rows, cols) =>
                  provider.resizeSession(active.session.id, rows, cols),
            ),
          if (secondary != null)
            TerminalPane(
              sessionId: secondary.session.id,
              view: secondary,
              isActive: true,
              onSubmit: (input) {
                unawaited(provider.sendInput(secondary.session.id, input));
              },
              onSendRaw: (input) {
                unawaited(provider.sendInput(secondary.session.id, input));
              },
              onDraftChanged: (value) =>
                  provider.setInputDraft(secondary.session.id, value),
              onResize: (rows, cols) =>
                  provider.resizeSession(secondary.session.id, rows, cols),
            ),
        ];

        final list = TerminalSessionList(
          sessions: provider.sessions,
          activeSessionId: provider.activeSessionId,
          secondarySessionId: provider.secondarySessionId,
          allowSecondarySelection: provider.splitViewEnabled,
          onSelect: (sessionId) => provider.activateSession(sessionId),
          onRename: (sessionId) {
            final current = provider.sessionFor(sessionId);
            _showNameDialog(
              title: 'Rename terminal',
              initialValue: current?.session.displayName,
              onConfirm: (value) => provider.renameSession(sessionId, value),
            );
          },
          onClose: provider.closeSession,
        );

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _TerminalToolbar(
                  workspaceName: workspace.displayName,
                  isLoading: provider.isLoading,
                  splitViewEnabled: provider.splitViewEnabled,
                  canSplitCurrent: provider.activeSession != null,
                  canSwap: provider.hasSecondarySession,
                  onCreate: () => _showNameDialog(
                    title: 'New terminal',
                    onConfirm: (value) => provider.createSession(name: value),
                  ),
                  onCreateUntitled: () {
                    provider.createSession();
                  },
                  onRefresh: () {
                    provider.refreshSessions();
                  },
                  onToggleSplit: () =>
                      provider.setSplitViewEnabled(!provider.splitViewEnabled),
                  onSplitActive: () {
                    final activeSessionId = provider.activeSessionId;
                    if (activeSessionId == null) {
                      return;
                    }
                    provider.splitSession(activeSessionId);
                  },
                  onSwap: provider.swapSplitSessions,
                ),
                if (provider.inventoryError != null)
                  MaterialBanner(
                    content: Text(provider.inventoryError!),
                    actions: [
                      TextButton(
                        onPressed: provider.refreshSessions,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                Expanded(
                  child: isCompact
                      ? Column(
                          children: [
                            SizedBox(height: 220, child: list),
                            const Divider(height: 1),
                            Expanded(
                              child: panes.isEmpty
                                  ? const _EmptyTerminalState()
                                  : panes.length == 1
                                      ? panes.first
                                      : Column(
                                          children: [
                                            Expanded(child: panes.first),
                                            const SizedBox(height: 8),
                                            Expanded(child: panes.last),
                                          ],
                                        ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            SizedBox(width: 300, child: list),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: panes.isEmpty
                                  ? const _EmptyTerminalState()
                                  : panes.length == 1
                                      ? panes.first
                                      : Row(
                                          children: [
                                            Expanded(child: panes.first),
                                            const SizedBox(width: 8),
                                            Expanded(child: panes.last),
                                          ],
                                        ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TerminalToolbar extends StatelessWidget {
  const _TerminalToolbar({
    required this.workspaceName,
    required this.isLoading,
    required this.splitViewEnabled,
    required this.canSplitCurrent,
    required this.canSwap,
    required this.onCreate,
    required this.onCreateUntitled,
    required this.onRefresh,
    required this.onToggleSplit,
    required this.onSplitActive,
    required this.onSwap,
  });

  final String workspaceName;
  final bool isLoading;
  final bool splitViewEnabled;
  final bool canSplitCurrent;
  final bool canSwap;
  final VoidCallback onCreate;
  final VoidCallback onCreateUntitled;
  final VoidCallback onRefresh;
  final VoidCallback onToggleSplit;
  final VoidCallback onSplitActive;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            avatar: const Icon(Icons.folder_open, size: 18),
            label: Text(workspaceName),
          ),
          FilledButton.icon(
            onPressed: onCreateUntitled,
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
          OutlinedButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.edit),
            label: const Text('Named'),
          ),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: Icon(isLoading ? Icons.sync : Icons.refresh),
            label: const Text('Refresh'),
          ),
          FilterChip(
            selected: splitViewEnabled,
            onSelected: (_) => onToggleSplit(),
            label: const Text('Split view'),
          ),
          OutlinedButton.icon(
            onPressed: canSplitCurrent ? onSplitActive : null,
            icon: const Icon(Icons.call_split),
            label: const Text('Split current'),
          ),
          OutlinedButton.icon(
            onPressed: canSwap ? onSwap : null,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Swap'),
          ),
        ],
      ),
    );
  }
}

class _EmptyTerminalState extends StatelessWidget {
  const _EmptyTerminalState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Create or select a terminal session to begin.'),
    );
  }
}
