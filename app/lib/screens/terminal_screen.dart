import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/terminal_provider.dart';
import '../widgets/terminal_pane.dart';
import '../widgets/terminal_session_list.dart';

class TerminalScreen extends StatefulWidget {
  final String baseUrl;
  final String token;
  final String workDir;
  final bool isActive;
  final TerminalProvider? provider;

  const TerminalScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    this.workDir = '/',
    this.isActive = true,
    this.provider,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final TerminalProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider ?? TerminalProvider();
    _ownsProvider = widget.provider == null;
    _provider.configure(
      baseUrl: widget.baseUrl,
      token: widget.token,
      workDir: widget.workDir,
    );
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _provider.ensureInitialized();
      });
    }
  }

  @override
  void didUpdateWidget(covariant TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _provider.configure(
      baseUrl: widget.baseUrl,
      token: widget.token,
      workDir: widget.workDir,
    );
    if (widget.isActive && !oldWidget.isActive) {
      _provider.ensureInitialized();
    }
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _showRenameDialog(BuildContext context, String sessionId) async {
    final session = _provider.sessionFor(sessionId);
    if (session == null) {
      return;
    }
    final controller = TextEditingController(text: session.session.displayName);
    final nextName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename session'),
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
    if (nextName != null && nextName.isNotEmpty) {
      await _provider.renameSession(sessionId, nextName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalProvider>.value(
      value: _provider,
      child: Consumer<TerminalProvider>(
        builder: (context, provider, _) {
          final isWide = MediaQuery.sizeOf(context).width >= 900;
          final sessions = provider.sessions;

          return Scaffold(
            appBar: AppBar(
              title: const Text('Terminal Sessions'),
              actions: [
                IconButton(
                  tooltip: 'Refresh sessions',
                  onPressed: provider.isLoading
                      ? null
                      : () => provider.refreshSessions(),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Create session',
                  onPressed: provider.isLoading
                      ? null
                      : () => provider.createSession(),
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: isWide
                      ? (provider.splitViewEnabled
                            ? 'Disable split view'
                            : 'Enable split view')
                      : 'Split view unavailable on narrow layouts',
                  onPressed: isWide
                      ? () => provider.setSplitViewEnabled(
                          !provider.splitViewEnabled,
                        )
                      : null,
                  icon: const Icon(Icons.view_week_outlined),
                ),
                if (isWide && provider.activeSessionId != null)
                  IconButton(
                    tooltip: 'Split active session',
                    onPressed: () =>
                        provider.splitSession(provider.activeSessionId!),
                    icon: const Icon(Icons.call_split),
                  ),
              ],
            ),
            body: Column(
              children: [
                if (!isWide && provider.splitViewEnabled)
                  MaterialBanner(
                    content: const Text(
                      'Split view is available on wider screens. This layout falls back to one visible terminal pane.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => provider.setSplitViewEnabled(false),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                if (provider.inventoryError != null)
                  MaterialBanner(
                    content: Text(provider.inventoryError!),
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.errorContainer,
                    actions: [
                      TextButton(
                        onPressed: () => provider.refreshSessions(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                Expanded(
                  child: provider.isLoading && !provider.hasLoaded
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('Loading terminal sessions...'),
                            ],
                          ),
                        )
                      : isWide
                      ? Row(
                          children: [
                            SizedBox(
                              width: 320,
                              child: TerminalSessionList(
                                sessions: sessions,
                                activeSessionId: provider.activeSessionId,
                                secondarySessionId: provider.secondarySessionId,
                                allowSecondarySelection:
                                    provider.splitViewEnabled,
                                onSelect: (id) => provider.activateSession(id),
                                onRename: (id) =>
                                    _showRenameDialog(context, id),
                                onClose: (id) => provider.closeSession(id),
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _TerminalPaneLayout(
                                provider: provider,
                                isWide: true,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            SizedBox(
                              height: 220,
                              child: TerminalSessionList(
                                sessions: sessions,
                                activeSessionId: provider.activeSessionId,
                                secondarySessionId: null,
                                allowSecondarySelection: false,
                                onSelect: (id) => provider.activateSession(id),
                                onRename: (id) =>
                                    _showRenameDialog(context, id),
                                onClose: (id) => provider.closeSession(id),
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: _TerminalPaneLayout(
                                provider: provider,
                                isWide: false,
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
}

class _TerminalPaneLayout extends StatelessWidget {
  const _TerminalPaneLayout({required this.provider, required this.isWide});

  final TerminalProvider provider;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final primary = provider.activeSession;
    if (primary == null) {
      return const Center(
        child: Text('Create or attach a terminal session to begin.'),
      );
    }

    final secondary = isWide && provider.splitViewEnabled
        ? provider.secondarySession
        : null;

    final panes = <Widget>[
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: TerminalPane(
            key: ValueKey<String>('pane-${primary.session.id}'),
            sessionId: primary.session.id,
            view: primary,
            isActive: true,
            onSubmit: (value) => provider.sendInput(primary.session.id, value),
            onDraftChanged: (value) =>
                provider.setInputDraft(primary.session.id, value),
            onResize: (rows, cols) =>
                provider.resizeSession(primary.session.id, rows, cols),
          ),
        ),
      ),
    ];

    if (secondary != null) {
      panes.add(
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            child: TerminalPane(
              key: ValueKey<String>('pane-${secondary.session.id}'),
              sessionId: secondary.session.id,
              view: secondary,
              isActive: false,
              onSubmit: (value) =>
                  provider.sendInput(secondary.session.id, value),
              onDraftChanged: (value) =>
                  provider.setInputDraft(secondary.session.id, value),
              onResize: (rows, cols) =>
                  provider.resizeSession(secondary.session.id, rows, cols),
            ),
          ),
        ),
      );
    }

    return Row(children: panes);
  }
}
