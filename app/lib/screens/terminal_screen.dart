import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/terminal_provider.dart';
import '../widgets/app_bar_menu.dart';
import '../widgets/terminal_pane.dart';
import '../widgets/terminal_session_list.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    this.workDir = '/',
    this.isActive = true,
    this.provider,
  });

  final String baseUrl;
  final String token;
  final String workDir;
  final bool isActive;
  final TerminalProvider? provider;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late TerminalProvider _provider;
  late bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider ?? TerminalProvider();
    _ownsProvider = widget.provider == null;
    _configureProvider();
  }

  @override
  void didUpdateWidget(covariant TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider && widget.provider != null) {
      if (_ownsProvider) {
        _provider.dispose();
      }
      _provider = widget.provider!;
      _ownsProvider = false;
    }
    _configureProvider();
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  void _configureProvider() {
    _provider.configure(
      baseUrl: widget.baseUrl,
      token: widget.token,
      workDir: widget.workDir,
    );
    if (widget.isActive) {
      unawaited(_provider.ensureInitialized());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalProvider>.value(
      value: _provider,
      child: Consumer<TerminalProvider>(
        builder: (context, provider, _) {
          final width = MediaQuery.sizeOf(context).width;
          final isWide = width >= 900;
          final showSplitPane =
              isWide &&
              provider.splitViewEnabled &&
              provider.hasSecondarySession;
          final active = provider.activeSession;
          final secondary = showSplitPane ? provider.secondarySession : null;

          if (!isWide) {
            return _buildNarrowScaffold(context, provider);
          }

          return Scaffold(
            appBar: _buildAppBar(context, provider, isWide: true),
            body: Row(
              children: [
                SizedBox(
                  width: 320,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Terminal Sessions',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            if (provider.hasSecondarySession)
                              IconButton(
                                tooltip: 'Swap panes',
                                onPressed: provider.swapSplitSessions,
                                icon: const Icon(Icons.swap_horiz),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TerminalSessionList(
                          sessions: provider.sessions,
                          activeSessionId: provider.activeSessionId,
                          secondarySessionId: provider.secondarySessionId,
                          allowSecondarySelection: showSplitPane,
                          onSelect: (sessionId) {
                            unawaited(provider.activateSession(sessionId));
                          },
                          onRename: (sessionId) {
                            unawaited(
                              _promptRenameSession(
                                context,
                                provider,
                                sessionId,
                              ),
                            );
                          },
                          onClose: (sessionId) {
                            unawaited(provider.closeSession(sessionId));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (provider.inventoryError != null)
                        MaterialBanner(
                          content: Text(provider.inventoryError!),
                          actions: [
                            TextButton(
                              onPressed: () => provider.refreshSessions(),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _buildPaneArea(
                            provider: provider,
                            active: active,
                            secondary: secondary,
                            showSplitPane: showSplitPane,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  AppBar _buildAppBar(
    BuildContext context,
    TerminalProvider provider, {
    required bool isWide,
  }) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Terminal'),
          Text(
            _workspaceLabel(widget.workDir),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Create session',
          onPressed: () => provider.createSession(),
          icon: const Icon(Icons.add_box_outlined),
        ),
        IconButton(
          tooltip: 'Refresh sessions',
          onPressed: () => provider.refreshSessions(),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: isWide
              ? 'Split active session'
              : 'Split view unavailable on narrow layouts',
          onPressed: isWide && provider.activeSessionId != null
              ? () => provider.splitSession(provider.activeSessionId!)
              : null,
          icon: const Icon(Icons.splitscreen_outlined),
        ),
        const AppBarMenu(),
      ],
    );
  }

  Widget _buildNarrowScaffold(BuildContext context, TerminalProvider provider) {
    return Scaffold(
      appBar: _buildAppBar(context, provider, isWide: false),
      body: Column(
        children: [
          if (provider.inventoryError != null)
            MaterialBanner(
              content: Text(provider.inventoryError!),
              actions: [
                TextButton(
                  onPressed: () => provider.refreshSessions(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: _TerminalSessionInbox(
              provider: provider,
              onOpenSession: (sessionId) async {
                final navigator = Navigator.of(context);
                await provider.activateSession(sessionId);
                if (!mounted) {
                  return;
                }
                await navigator.push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ChangeNotifierProvider<TerminalProvider>.value(
                          value: provider,
                          child: _TerminalSessionDetailScreen(
                            sessionId: sessionId,
                            workDir: widget.workDir,
                          ),
                        ),
                  ),
                );
              },
              onRename: (sessionId) =>
                  _promptRenameSession(context, provider, sessionId),
              onClose: (sessionId) => provider.closeSession(sessionId),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaneArea({
    required TerminalProvider provider,
    required TerminalSessionView? active,
    required TerminalSessionView? secondary,
    required bool showSplitPane,
  }) {
    if (provider.isLoading && !provider.hasSessions) {
      return const Center(child: CircularProgressIndicator());
    }
    if (active == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => provider.createSession(),
          icon: const Icon(Icons.add_box_outlined),
          label: const Text('Create terminal session'),
        ),
      );
    }

    if (!showSplitPane || secondary == null) {
      return _buildPane(provider, active, true);
    }

    return Row(
      children: [
        Expanded(child: _buildPane(provider, active, true)),
        const SizedBox(width: 12),
        Expanded(child: _buildPane(provider, secondary, false)),
      ],
    );
  }

  Widget _buildPane(
    TerminalProvider provider,
    TerminalSessionView view,
    bool isPrimary,
  ) {
    return TerminalPane(
      sessionId: view.session.id,
      view: view,
      isActive: isPrimary,
      onSubmit: (value) {
        unawaited(provider.sendInput(view.session.id, value));
      },
      onSendRaw: (value) {
        unawaited(provider.sendInput(view.session.id, value));
      },
      onDraftChanged: (value) => provider.setInputDraft(view.session.id, value),
      onResize: (rows, cols) {
        unawaited(provider.resizeSession(view.session.id, rows, cols));
      },
    );
  }
}

class _TerminalSessionInbox extends StatelessWidget {
  const _TerminalSessionInbox({
    required this.provider,
    required this.onOpenSession,
    required this.onRename,
    required this.onClose,
  });

  final TerminalProvider provider;
  final Future<void> Function(String sessionId) onOpenSession;
  final Future<void> Function(String sessionId) onRename;
  final Future<void> Function(String sessionId) onClose;

  @override
  Widget build(BuildContext context) {
    if (provider.isLoading && !provider.hasSessions) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!provider.hasSessions) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => provider.createSession(),
          icon: const Icon(Icons.add_box_outlined),
          label: const Text('Create terminal session'),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: provider.sessions.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Terminal Sessions',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${provider.sessions.length} active',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        }

        final view = provider.sessions[index - 1];
        return _TerminalSessionConversationCard(
          view: view,
          pinned: provider.isPinned(view.session.id),
          active: provider.activeSessionId == view.session.id,
          onTap: () => onOpenSession(view.session.id),
          onDismissed: () => onClose(view.session.id),
          onLongPress: () => _showSessionActions(
            context,
            provider,
            view.session.id,
            onRename: onRename,
            onClose: onClose,
          ),
        );
      },
    );
  }
}

class _TerminalSessionConversationCard extends StatelessWidget {
  const _TerminalSessionConversationCard({
    required this.view,
    required this.pinned,
    required this.active,
    required this.onTap,
    required this.onLongPress,
    required this.onDismissed,
  });

  final TerminalSessionView view;
  final bool pinned;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Future<void> Function() onDismissed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _sessionPreview(view);
    final titleColor = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    return Dismissible(
      key: ValueKey<String>('terminal-session-${view.session.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          Icons.delete_outline,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) async {
        await onDismissed();
        return true;
      },
      child: Material(
        color: active
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.65)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.terminal,
                    color: active
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              view.session.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: titleColor,
                              ),
                            ),
                          ),
                          if (pinned)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Icon(
                                Icons.push_pin,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              view.session.cwd,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              view.statusLabel,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalSessionDetailScreen extends StatelessWidget {
  const _TerminalSessionDetailScreen({
    required this.sessionId,
    required this.workDir,
  });

  final String sessionId;
  final String workDir;

  @override
  Widget build(BuildContext context) {
    return Consumer<TerminalProvider>(
      builder: (context, provider, _) {
        final view = provider.sessionFor(sessionId);
        final sessionName = view?.session.displayName ?? 'Session';

        return Scaffold(
          appBar: AppBar(
            title: Text(
              sessionName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: provider.isPinned(sessionId)
                    ? 'Unpin session'
                    : 'Pin session',
                onPressed: view == null
                    ? null
                    : () => provider.togglePinned(sessionId),
                icon: Icon(
                  provider.isPinned(sessionId)
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                ),
              ),
              if (view != null)
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'rename') {
                      await _promptRenameSession(context, provider, sessionId);
                    } else if (value == 'close') {
                      await provider.closeSession(sessionId);
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'rename',
                      child: Text('Rename'),
                    ),
                    PopupMenuItem<String>(value: 'close', child: Text('Close')),
                  ],
                ),
            ],
          ),
          body: view == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'This terminal session is no longer available.',
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : TerminalPane(
                  sessionId: view.session.id,
                  view: view,
                  isActive: true,
                  compact: true,
                  onSubmit: (value) {
                    unawaited(provider.sendInput(view.session.id, value));
                  },
                  onSendRaw: (value) {
                    unawaited(provider.sendInput(view.session.id, value));
                  },
                  onDraftChanged: (value) =>
                      provider.setInputDraft(view.session.id, value),
                  onResize: (rows, cols) {
                    unawaited(
                      provider.resizeSession(view.session.id, rows, cols),
                    );
                  },
                ),
        );
      },
    );
  }
}

String _workspaceLabel(String workDir) {
  final trimmed = workDir.trim();
  if (trimmed.isEmpty || trimmed == '/') {
    return '/';
  }
  final parts = trimmed.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) {
    return trimmed;
  }
  return parts.last;
}

Future<void> _promptRenameSession(
  BuildContext context,
  TerminalProvider provider,
  String sessionId,
) async {
  final controller = TextEditingController(
    text: provider.sessionFor(sessionId)?.session.name ?? '',
  );
  final nextName = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename terminal'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Session name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (nextName == null || nextName.isEmpty) {
    return;
  }
  await provider.renameSession(sessionId, nextName);
}

String _sessionPreview(TerminalSessionView view) {
  final lines = view.outputText
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) {
    return view.helperText;
  }
  return lines.last;
}

Future<void> _showSessionActions(
  BuildContext context,
  TerminalProvider provider,
  String sessionId, {
  required Future<void> Function(String sessionId) onRename,
  required Future<void> Function(String sessionId) onClose,
}) async {
  final pinned = provider.isPinned(sessionId);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(pinned ? 'Unpin session' : 'Pin to top'),
              onTap: () {
                provider.togglePinned(sessionId);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.of(context).pop();
                await onRename(sessionId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close session'),
              onTap: () async {
                Navigator.of(context).pop();
                await onClose(sessionId);
              },
            ),
          ],
        ),
      );
    },
  );
}
