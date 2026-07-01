// Terminal tab — IM-style session list.
//
// Each row shows: auto-generated label, dimmed cwd basename, last-line
// preview (ANSI-stripped, truncated), relative timestamp. Tap a row to push
// the full-screen TerminalDetailScreen via the root navigator — the home
// shell's bottom nav + workspace chooser disappear naturally because the
// detail screen is its own Scaffold on top of the navigation stack.
// Long-press a row to confirm-kill the session.
//
// PTY lifecycle is unchanged: navigation into/out of the detail view never
// disposes a session.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../settings_store.dart';
import '../state/terminal_hub.dart';
import '../ui/app_tokens.dart';
import 'terminal_detail.dart';

class TerminalTab extends StatefulWidget {
  final AppState appState;
  final TerminalHub? terminalHub;
  final String? activeBackendId;
  final SettingsStore? settingsStore;
  final Future<void> Function(TerminalSession session)? onOpenFilesForSession;
  final Future<void> Function(BackendTerminalSession session)?
  onOpenFilesForBackendSession;
  const TerminalTab({
    super.key,
    required this.appState,
    this.terminalHub,
    this.activeBackendId,
    this.settingsStore,
    this.onOpenFilesForSession,
    this.onOpenFilesForBackendSession,
  });

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  // Drives the per-second timestamp tick so "5m" / "2h" stay current while
  // the user keeps the list open. The preview-version listenable handles
  // text changes; this clock handles relative-time staleness.
  Timer? _clockTick;
  int _clockEpoch = 0;
  final Set<String> _collapsedBackendIds = <String>{};

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    widget.terminalHub?.addListener(_onTerminalHubChanged);
    _clockTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _clockEpoch++);
    });
  }

  @override
  void didUpdateWidget(covariant TerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminalHub != widget.terminalHub) {
      oldWidget.terminalHub?.removeListener(_onTerminalHubChanged);
      widget.terminalHub?.addListener(_onTerminalHubChanged);
    }
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState.removeListener(_onAppStateChanged);
      widget.appState.addListener(_onAppStateChanged);
    }
  }

  @override
  void dispose() {
    widget.terminalHub?.removeListener(_onTerminalHubChanged);
    widget.appState.removeListener(_onAppStateChanged);
    _clockTick?.cancel();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onTerminalHubChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showSessionActions(TerminalSession s) async {
    final canDetach = s.externalSessionId != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canDetach)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Detach'),
                subtitle: Text(
                  'Leave the zellij session running on the backend '
                  '(${s.externalSessionId}). Reattach from desktop with '
                  '"zellij attach ${s.externalSessionId}".',
                ),
                onTap: () => Navigator.of(ctx).pop('detach'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              subtitle: Text(_displaySessionLabel(s, 0)),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              subtitle: Text(
                'Kill the session entirely. '
                'Session ${s.id.substring(0, 8)}… will be destroyed.',
              ),
              onTap: () => Navigator.of(ctx).pop('close'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(ctx).pop(null),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'detach') {
      await widget.appState.detachTerminal(s.id);
      if (!mounted) return;
      final name = s.externalSessionId;
      if (name != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Detached. Reattach with: zellij attach $name'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } else if (action == 'close') {
      await widget.appState.disposeTerminal(s.id);
    } else if (action == 'rename') {
      final title = await _promptRename(s);
      if (!mounted || title == _renameCancelled) return;
      await widget.appState.renameTerminal(s.id, title);
    }
  }

  Future<void> _showHubSessionActions(BackendTerminalSession ref) async {
    final s = ref.session;
    final canDetach = s.externalSessionId != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canDetach)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Detach'),
                subtitle: Text(
                  'Leave the zellij session running on ${ref.backend.name} '
                  '(${s.externalSessionId}).',
                ),
                onTap: () => Navigator.of(ctx).pop('detach'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              subtitle: Text(_displaySessionLabel(s, 0)),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              subtitle: Text(
                'Kill ${s.id.substring(0, 8)}… on ${ref.backend.name}.',
              ),
              onTap: () => Navigator.of(ctx).pop('close'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(ctx).pop(null),
            ),
          ],
        ),
      ),
    );
    final hub = widget.terminalHub;
    if (!mounted || hub == null) return;
    if (action == 'detach') {
      await hub.detachTerminal(ref.backendId, ref.sessionId);
      if (!mounted) return;
      final name = s.externalSessionId;
      if (name != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Detached on ${ref.backend.name}: $name'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } else if (action == 'close') {
      await hub.disposeTerminal(ref.backendId, ref.sessionId);
    } else if (action == 'rename') {
      final title = await _promptRename(s);
      if (!mounted || title == _renameCancelled) return;
      await hub.renameTerminal(ref.backendId, ref.sessionId, title);
    }
  }

  Future<String?> _promptRename(TerminalSession session) async {
    final controller = TextEditingController(text: session.title ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename terminal'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Leave empty to use the default label',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_renameCancelled),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == _renameCancelled) return _renameCancelled;
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _openDetail(TerminalSession s, int index) async {
    widget.appState.focusTerminal(s.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalDetailScreen(
          appState: widget.appState,
          settingsStore: widget.settingsStore,
          sessionId: s.id,
          title: _displaySessionLabel(s, index),
          onOpenFiles: widget.onOpenFilesForSession == null
              ? null
              : () => widget.onOpenFilesForSession!(s),
        ),
      ),
    );
  }

  Future<void> _openHubDetail(
    BackendTerminalSession ref,
    int indexInBackend,
  ) async {
    final hub = widget.terminalHub;
    if (hub == null) return;
    hub.focusTerminal(ref.backendId, ref.sessionId);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalDetailScreen(
          terminalHub: hub,
          backendId: ref.backendId,
          settingsStore: widget.settingsStore,
          sessionId: ref.sessionId,
          title: _displaySessionLabel(ref.session, indexInBackend),
          onOpenFiles: widget.onOpenFilesForBackendSession == null
              ? null
              : () => widget.onOpenFilesForBackendSession!(ref),
        ),
      ),
    );
  }

  Future<void> _openDiscoverSheet() async {
    final w = widget.appState.currentWorkspace;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _DiscoverSessionsSheet(
        appState: widget.appState,
        workspaceId: w?.id,
        onAdopted: (session) {
          Navigator.of(sheetCtx).pop();
          final sessions = widget.appState.currentTerminals;
          final idx = sessions.indexWhere((s) => s.id == session.id);
          _openDetail(session, idx >= 0 ? idx : sessions.length - 1);
        },
      ),
    );
  }

  Future<void> _openHubDiscoverSheet(BackendTerminalGroup group) async {
    final hub = widget.terminalHub;
    if (hub == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _HubDiscoverSessionsSheet(
        hub: hub,
        backend: group.backend,
        workspaceId: _currentWorkspaceIdForBackend(group.backend.id),
        onAdopted: (session) {
          Navigator.of(sheetCtx).pop();
          final sessions = hub.sessionsForBackend(group.backend.id);
          final idx = sessions.indexWhere((s) => s.session.id == session.id);
          _openHubDetail(
            BackendTerminalSession(backend: group.backend, session: session),
            idx >= 0 ? idx : sessions.length - 1,
          );
        },
      ),
    );
  }

  Future<void> _createAndOpen() async {
    final w = widget.appState.currentWorkspace;
    final created = await widget.appState.createTerminal(
      workspaceId: w?.id,
      cols: 80,
      rows: 24,
    );
    if (!mounted || created == null) return;
    final sessions = widget.appState.currentTerminals;
    final idx = sessions.indexWhere((s) => s.id == created.id);
    await _openDetail(created, idx >= 0 ? idx : sessions.length - 1);
  }

  Future<void> _openCreateTerminalSheet(BackendTerminalGroup group) async {
    final hub = widget.terminalHub;
    if (hub == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _CreateTerminalSheet(
        hub: hub,
        group: group,
        onCreate: (workspaceRoot) async {
          Navigator.of(sheetCtx).pop();
          await _createHubAndOpen(group, workspaceRoot: workspaceRoot);
        },
      ),
    );
  }

  Future<void> _createHubAndOpen(
    BackendTerminalGroup group, {
    String? workspaceRoot,
  }) async {
    final hub = widget.terminalHub;
    if (hub == null) return;
    final created = await hub.createTerminalForWorkspaceRoot(
      backendId: group.backend.id,
      workspaceRoot: workspaceRoot,
      cols: 80,
      rows: 24,
    );
    if (!mounted || created == null) return;
    final sessions = hub.sessionsForBackend(group.backend.id);
    final idx = sessions.indexWhere((s) => s.session.id == created.id);
    await _openHubDetail(
      BackendTerminalSession(backend: group.backend, session: created),
      idx >= 0 ? idx : sessions.length - 1,
    );
  }

  String? _currentWorkspaceIdForBackend(String backendId) {
    if (backendId != widget.activeBackendId) return null;
    return widget.appState.currentWorkspace?.id;
  }

  void _toggleBackendCollapsed(String backendId) {
    setState(() {
      if (!_collapsedBackendIds.add(backendId)) {
        _collapsedBackendIds.remove(backendId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.terminalHub;
    if (hub != null) return _buildHub(context, hub);

    final sessions = widget.appState.currentTerminals;
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.terminal_outlined, size: AppIconSize.lg),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'No terminal sessions yet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _createAndOpen,
                icon: const Icon(Icons.add),
                label: const Text('Start terminal'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                onPressed: _openDiscoverSheet,
                icon: const Icon(Icons.search),
                label: const Text('Discover external sessions'),
              ),
            ],
          ),
        ),
      );
    }
    return ListenableBuilder(
      // List rebuilds on preview-buffer changes (per-chunk) without
      // depending on AppState's broader notify cascade. Session add/remove
      // already comes through the AppState listener installed in initState.
      listenable: widget.appState.terminalPreviewChanges,
      builder: (context, _) {
        final now = DateTime.now();
        return ListView.separated(
          itemCount: sessions.length + 2,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == sessions.length) {
              return _NewSessionTile(onTap: _createAndOpen);
            }
            if (index == sessions.length + 1) {
              return _DiscoverSessionsTile(onTap: _openDiscoverSheet);
            }
            final s = sessions[index];
            final preview = widget.appState.terminalPreviewFor(s.id);
            return _SessionTile(
              label: _displaySessionLabel(s, index),
              cwdBasename: _basename(s.cwd),
              previewText: preview.text,
              timestamp: _formatRelativeTimestamp(
                preview.lastDataAt ?? s.createdAt,
                now,
              ),
              detached: s.detached,
              onTap: () => _openDetail(s, index),
              onLongPress: () => _showSessionActions(s),
            );
          },
        );
      },
    );
  }

  Widget _buildHub(BuildContext context, TerminalHub hub) {
    final groups = hub.groups;
    if (groups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Text('No backend connections configured.'),
        ),
      );
    }
    final hasSessions = groups.any((g) => g.sessions.isNotEmpty);
    return ListenableBuilder(
      listenable: hub.previewVersion,
      builder: (context, _) {
        final now = DateTime.now();
        return ListView.separated(
          itemCount: _hubItemCount(groups, _collapsedBackendIds),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, rawIndex) {
            var index = rawIndex;
            for (final group in groups) {
              final collapsed = _collapsedBackendIds.contains(group.backend.id);
              if (index == 0) {
                return _BackendGroupHeader(
                  group: group,
                  collapsed: collapsed,
                  onToggle: () => _toggleBackendCollapsed(group.backend.id),
                  onNew: group.isConnected
                      ? () => _openCreateTerminalSheet(group)
                      : null,
                  onDiscover: group.isConnected
                      ? () => _openHubDiscoverSheet(group)
                      : null,
                );
              }
              index--;
              if (collapsed) continue;
              if (group.sessions.isEmpty) {
                if (index == 0) {
                  return _BackendEmptyRow(
                    connected: group.isConnected,
                    showGlobalHint: !hasSessions,
                  );
                }
                index--;
                continue;
              }
              if (index < group.sessions.length) {
                final session = group.sessions[index];
                final preview = hub.previewFor(group.backend.id, session.id);
                final ref = BackendTerminalSession(
                  backend: group.backend,
                  session: session,
                );
                return _SessionTile(
                  label: _displaySessionLabel(session, index),
                  cwdBasename: _basename(session.cwd),
                  previewText: preview.text,
                  timestamp: _formatRelativeTimestamp(
                    preview.lastDataAt ?? session.createdAt,
                    now,
                  ),
                  detached: session.detached,
                  nested: true,
                  onTap: () => _openHubDetail(ref, index),
                  onLongPress: () => _showHubSessionActions(ref),
                );
              }
              index -= group.sessions.length;
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}

int _hubItemCount(
  List<BackendTerminalGroup> groups,
  Set<String> collapsedBackendIds,
) {
  var total = 0;
  for (final group in groups) {
    total += 1; // backend header
    if (collapsedBackendIds.contains(group.backend.id)) continue;
    total += group.sessions.isEmpty ? 1 : group.sessions.length;
  }
  return total;
}

const String _renameCancelled = '__openvsmobile_rename_cancelled__';

/// Auto-generated session label, "sh · N" — the brief's example shape.
/// Sessions don't carry their shell binary on the wire today; once the
/// backend reports it we can drop the literal "sh".
String _sessionLabel(int index) => 'sh · ${index + 1}';

String _displaySessionLabel(TerminalSession session, int index) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return _sessionLabel(index);
}

/// Last non-empty path segment. The cwd is always absolute (PTY spawned
/// against the workspace root), so this is a cheap basename.
String _basename(String path) {
  if (path.isEmpty) return path;
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  if (slash < 0) return trimmed;
  if (slash == trimmed.length - 1) return trimmed; // "/" itself
  return trimmed.substring(slash + 1);
}

/// Bucketed relative timestamp: <1m "now", <1h "Nm", <24h "Nh", else "Nd".
/// Matches the brief's spirit ("`12:34` / `5m` / `2h`, relative") without
/// trying to render HH:mm — terminal recency is what the row signals,
/// not wall-clock identity.
String _formatRelativeTimestamp(int ms, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = now.difference(t);
  if (diff.isNegative) return 'now';
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 30) return '${diff.inDays}d';
  // Older than a month — fall back to MM/DD so the row still says
  // something concrete.
  return '${t.month}/${t.day}';
}

class _SessionTile extends StatelessWidget {
  final String label;
  final String cwdBasename;
  final String? previewText;
  final String timestamp;
  final bool detached;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool nested;
  const _SessionTile({
    required this.label,
    required this.cwdBasename,
    required this.previewText,
    required this.timestamp,
    required this.onTap,
    required this.onLongPress,
    this.detached = false,
    this.nested = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    final leftPad = nested ? AppSpacing.xl : AppSpacing.lg;
    final iconSize = AppIconSize.sm;
    final preview = previewText ?? '(no output yet)';
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          leftPad,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.terminal_outlined, color: dim, size: iconSize),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          // Session labels like `sh · 1` are code-flavoured
                          // identifiers — render them in the project mono
                          // font so they read as terminal artefacts, not
                          // chat-room titles.
                          style: AppText.mono(
                            fontSize: theme.textTheme.bodyMedium?.fontSize,
                            fontWeight: FontWeight.w500,
                            fontStyle: detached
                                ? FontStyle.italic
                                : FontStyle.normal,
                            color: detached ? dim : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        timestamp,
                        style: theme.textTheme.labelSmall?.copyWith(color: dim),
                      ),
                      if (detached)
                        Padding(
                          padding: const EdgeInsets.only(left: AppSpacing.sm),
                          child: Text(
                            '(detached)',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: dim,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (cwdBasename.isNotEmpty) ...[
                        Icon(Icons.folder_outlined, size: 14, color: dim),
                        const SizedBox(width: AppSpacing.xs),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 96),
                          child: Text(
                            cwdBasename,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: dim,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xs,
                          ),
                          child: Text(
                            '·',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: dim,
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            fontSize: theme.textTheme.bodySmall?.fontSize,
                            color: dim,
                            fontStyle: previewText == null
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
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
    );
  }
}

class _DiscoverSessionsTile extends StatelessWidget {
  final VoidCallback onTap;
  const _DiscoverSessionsTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: dim),
            const SizedBox(width: AppSpacing.md),
            Text(
              'Discover external sessions',
              style: theme.textTheme.bodyMedium?.copyWith(color: dim),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewSessionTile extends StatelessWidget {
  final VoidCallback onTap;
  const _NewSessionTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      // Long-press is intentionally not wired — "+ New" has no per-session
      // identity to act on; tapping is the only meaningful interaction.
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(Icons.add, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Text(
              'New terminal',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendGroupHeader extends StatelessWidget {
  final BackendTerminalGroup group;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onNew;
  final VoidCallback? onDiscover;

  const _BackendGroupHeader({
    required this.group,
    required this.collapsed,
    required this.onToggle,
    required this.onNew,
    required this.onDiscover,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = theme.colorScheme.onSurfaceVariant;
    final connected = group.isConnected;
    final count = group.sessions.length;
    final countText = count == 1 ? '1 session' : '$count sessions';
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 52,
            color: connected ? scheme.primary : dim,
          ),
          Expanded(
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      collapsed
                          ? Icons.keyboard_arrow_right
                          : Icons.keyboard_arrow_down,
                      color: dim,
                      size: AppIconSize.md,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.dns_outlined,
                        color: connected ? scheme.primary : dim,
                        size: AppIconSize.sm,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.backend.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              _StatusPill(group: group),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${group.backend.host}:${group.backend.port} · '
                            '$countText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.mono(
                              fontSize: theme.textTheme.labelSmall?.fontSize,
                              color: dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'New terminal',
            onPressed: onNew,
            icon: const Icon(Icons.add),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          ),
          IconButton(
            tooltip: 'Discover external sessions',
            onPressed: onDiscover,
            icon: const Icon(Icons.search),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final BackendTerminalGroup group;

  const _StatusPill({required this.group});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connected = group.isConnected;
    final color = connected ? scheme.primary : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          _connectionLabel(group),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _BackendEmptyRow extends StatelessWidget {
  final bool connected;
  final bool showGlobalHint;

  const _BackendEmptyRow({
    required this.connected,
    required this.showGlobalHint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Text(
        connected
            ? (showGlobalHint
                  ? 'No terminal sessions yet. Use + on a backend to start one.'
                  : 'No terminal sessions.')
            : 'Not connected.',
        style: theme.textTheme.bodySmall?.copyWith(color: dim),
      ),
    );
  }
}

class _CreateTerminalSheet extends StatefulWidget {
  final TerminalHub hub;
  final BackendTerminalGroup group;
  final Future<void> Function(String? workspaceRoot) onCreate;

  const _CreateTerminalSheet({
    required this.hub,
    required this.group,
    required this.onCreate,
  });

  @override
  State<_CreateTerminalSheet> createState() => _CreateTerminalSheetState();
}

class _CreateTerminalSheetState extends State<_CreateTerminalSheet> {
  late Future<List<BackendWorkspaceChoice>> _future;
  bool _mutatingRecents = false;

  @override
  void initState() {
    super.initState();
    _future = widget.hub.listWorkspaceChoices(widget.group.backend.id);
  }

  void _refresh() {
    setState(() {
      _future = widget.hub.listWorkspaceChoices(widget.group.backend.id);
    });
  }

  Future<void> _choose(String? root) async {
    await widget.onCreate(root);
  }

  Future<void> _browse() async {
    final root = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _BackendWorkspacePickerScreen(
          hub: widget.hub,
          backend: widget.group.backend,
          startPath: widget.hub.pickerStartPath(widget.group.backend.id),
        ),
      ),
    );
    if (!mounted || root == null) return;
    await _choose(root);
  }

  Future<void> _forgetRecent(String root) async {
    if (_mutatingRecents) return;
    setState(() => _mutatingRecents = true);
    await widget.hub.forgetRecentWorkspace(
      backendId: widget.group.backend.id,
      root: root,
    );
    if (!mounted) return;
    setState(() => _mutatingRecents = false);
    _refresh();
  }

  Future<void> _clearRecents() async {
    if (_mutatingRecents) return;
    setState(() => _mutatingRecents = true);
    await widget.hub.clearRecentWorkspaces(widget.group.backend.id);
    if (!mounted) return;
    setState(() => _mutatingRecents = false);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Icon(Icons.dns_outlined, color: dim),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.group.backend.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          '${widget.group.backend.host}:'
                          '${widget.group.backend.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            fontSize: theme.textTheme.labelSmall?.fontSize,
                            color: dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              leading: const Icon(Icons.terminal_outlined),
              title: const Text('Unbound terminal'),
              subtitle: const Text('No workspace link'),
              onTap: () => _choose(null),
            ),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('Browse folder'),
              subtitle: const Text('Pick any directory on this backend'),
              onTap: _browse,
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: FutureBuilder<List<BackendWorkspaceChoice>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Could not load workspaces: ${snap.error}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  final choices = snap.data ?? const <BackendWorkspaceChoice>[];
                  final open = choices.where((c) => c.isOpen).toList();
                  final recent = choices.where((c) => !c.isOpen).toList();
                  if (choices.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'No open or recent workspaces on this backend.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: dim),
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      if (open.isNotEmpty)
                        const _WorkspaceSectionHeader(label: 'Open workspaces'),
                      for (final choice in open)
                        ListTile(
                          leading: const Icon(Icons.folder_open),
                          title: Text(
                            choice.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            choice.root,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.mono(
                              fontSize: theme.textTheme.labelSmall?.fontSize,
                              color: dim,
                            ),
                          ),
                          trailing: Text(
                            'open',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: dim,
                            ),
                          ),
                          onTap: () => _choose(choice.root),
                        ),
                      _WorkspaceSectionHeader(
                        label: 'Recent',
                        trailing: recent.isEmpty
                            ? null
                            : TextButton.icon(
                                onPressed: _mutatingRecents
                                    ? null
                                    : _clearRecents,
                                icon: const Icon(Icons.clear_all),
                                label: const Text('Clear'),
                              ),
                      ),
                      if (recent.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.xs,
                            AppSpacing.lg,
                            AppSpacing.md,
                          ),
                          child: Text(
                            'No recent workspaces.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: dim,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      for (final choice in recent)
                        ListTile(
                          leading: const Icon(Icons.history),
                          title: Text(
                            choice.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            choice.root,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.mono(
                              fontSize: theme.textTheme.labelSmall?.fontSize,
                              color: dim,
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove recent',
                            icon: const Icon(Icons.close),
                            onPressed: _mutatingRecents
                                ? null
                                : () => _forgetRecent(choice.root),
                          ),
                          onTap: () => _choose(choice.root),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendWorkspacePickerScreen extends StatefulWidget {
  final TerminalHub hub;
  final BackendTarget backend;
  final String startPath;

  const _BackendWorkspacePickerScreen({
    required this.hub,
    required this.backend,
    required this.startPath,
  });

  @override
  State<_BackendWorkspacePickerScreen> createState() =>
      _BackendWorkspacePickerScreenState();
}

class _BackendWorkspacePickerScreenState
    extends State<_BackendWorkspacePickerScreen> {
  late String _path;
  List<DirEntry>? _entries;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _path = widget.startPath.isNotEmpty ? widget.startPath : '/';
    unawaited(_navigate(_path));
  }

  String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  String _join(String dir, String name) {
    if (dir.endsWith('/')) return '$dir$name';
    return '$dir/$name';
  }

  Future<void> _navigate(String path) async {
    final generation = ++_loadGeneration;
    setState(() {
      _path = path;
      _entries = null;
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.hub.listPickerDir(
        backendId: widget.backend.id,
        path: path,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _entries = const [];
        _loading = false;
      });
    }
  }

  void _select() {
    Navigator.of(context).pop(_path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    final dirs = entries?.where((e) => e.isDir).toList() ?? const <DirEntry>[];
    return Scaffold(
      appBar: AppBar(
        title: Text('Choose folder · ${widget.backend.name}'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _navigate(_path),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Parent',
                  onPressed: _path == '/'
                      ? null
                      : () => _navigate(_parent(_path)),
                ),
                Expanded(
                  child: Text(
                    _path,
                    style: AppText.mono(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: entries == null
                ? const SizedBox.shrink()
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final enabled = entry.isDir;
                      return ListTile(
                        leading: Icon(
                          entry.isDir
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: enabled ? null : theme.disabledColor,
                        ),
                        title: Text(
                          entry.name,
                          style: TextStyle(
                            color: enabled ? null : theme.disabledColor,
                          ),
                        ),
                        onTap: enabled
                            ? () => _navigate(_join(_path, entry.name))
                            : null,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text('Select this directory (${dirs.length} subdirs)'),
                  onPressed: _loading ? null : _select,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceSectionHeader extends StatelessWidget {
  final String label;
  final Widget? trailing;

  const _WorkspaceSectionHeader({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

String _connectionLabel(BackendTerminalGroup group) {
  final err = group.lastError;
  if (err != null && err.isNotEmpty) return err;
  return switch (group.connectionState.name) {
    'connected' => 'connected',
    'connecting' => 'connecting',
    'reconnecting' => 'reconnecting',
    'waitingForNetwork' => 'waiting for network',
    'failed' => 'failed',
    _ => 'disconnected',
  };
}

class _DiscoverSessionsSheet extends StatefulWidget {
  final AppState appState;
  final String? workspaceId;
  final void Function(TerminalSession session) onAdopted;
  const _DiscoverSessionsSheet({
    required this.appState,
    required this.workspaceId,
    required this.onAdopted,
  });

  @override
  State<_DiscoverSessionsSheet> createState() => _DiscoverSessionsSheetState();
}

class _HubDiscoverSessionsSheet extends StatefulWidget {
  final TerminalHub hub;
  final BackendTarget backend;
  final String? workspaceId;
  final void Function(TerminalSession session) onAdopted;

  const _HubDiscoverSessionsSheet({
    required this.hub,
    required this.backend,
    required this.workspaceId,
    required this.onAdopted,
  });

  @override
  State<_HubDiscoverSessionsSheet> createState() =>
      _HubDiscoverSessionsSheetState();
}

class _HubDiscoverSessionsSheetState extends State<_HubDiscoverSessionsSheet> {
  late Future<List<ExternalTerminalSession>> _future;
  bool _adopting = false;

  @override
  void initState() {
    super.initState();
    _future = widget.hub.listExternalSessions(widget.backend.id);
  }

  void _refresh() {
    setState(() {
      _future = widget.hub.listExternalSessions(widget.backend.id);
    });
  }

  Future<void> _onTap(ExternalTerminalSession s) async {
    if (s.adopted || _adopting) return;
    setState(() => _adopting = true);
    final session = await widget.hub.adoptExternalSession(
      backendId: widget.backend.id,
      workspaceId: widget.workspaceId,
      sessionName: s.name,
      cols: 80,
      rows: 24,
    );
    if (!mounted) return;
    setState(() => _adopting = false);
    if (session != null) widget.onAdopted(session);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'External zellij sessions · ${widget.backend.name}',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: FutureBuilder<List<ExternalTerminalSession>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Could not list sessions: ${snap.error}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  final list = snap.data ?? const <ExternalTerminalSession>[];
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'No zellij sessions found on this backend host.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  final active = list.where((s) => s.isActive).toList();
                  final exited = list.where((s) => !s.isActive).toList();
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      if (active.isNotEmpty) _DiscoverSectionHeader('Active'),
                      for (final s in active)
                        _DiscoverSessionRow(
                          session: s,
                          enabled: !s.adopted && !_adopting,
                          onTap: () => _onTap(s),
                        ),
                      if (exited.isNotEmpty) _DiscoverSectionHeader('Exited'),
                      for (final s in exited)
                        _DiscoverSessionRow(
                          session: s,
                          enabled: !s.adopted && !_adopting,
                          onTap: () => _onTap(s),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverSessionsSheetState extends State<_DiscoverSessionsSheet> {
  late Future<List<ExternalTerminalSession>> _future;
  bool _adopting = false;

  @override
  void initState() {
    super.initState();
    _future = widget.appState.listExternalSessions();
  }

  void _refresh() {
    setState(() {
      _future = widget.appState.listExternalSessions();
    });
  }

  Future<void> _onTap(ExternalTerminalSession s) async {
    if (s.adopted || _adopting) return;
    setState(() => _adopting = true);
    final session = await widget.appState.adoptExternalSession(
      workspaceId: widget.workspaceId,
      sessionName: s.name,
      cols: 80,
      rows: 24,
    );
    if (!mounted) return;
    setState(() => _adopting = false);
    if (session != null) widget.onAdopted(session);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'External zellij sessions',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: FutureBuilder<List<ExternalTerminalSession>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'Could not list sessions: ${snap.error}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  final list = snap.data ?? const <ExternalTerminalSession>[];
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        'No zellij sessions found on the backend host.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  // Active first, exited below.
                  final active = list.where((s) => s.isActive).toList();
                  final exited = list.where((s) => !s.isActive).toList();
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      if (active.isNotEmpty) _DiscoverSectionHeader('Active'),
                      for (final s in active)
                        _DiscoverSessionRow(
                          session: s,
                          enabled: !s.adopted && !_adopting,
                          onTap: () => _onTap(s),
                        ),
                      if (exited.isNotEmpty) _DiscoverSectionHeader('Exited'),
                      for (final s in exited)
                        _DiscoverSessionRow(
                          session: s,
                          enabled: !s.adopted && !_adopting,
                          onTap: () => _onTap(s),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverSectionHeader extends StatelessWidget {
  final String label;
  const _DiscoverSectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DiscoverSessionRow extends StatelessWidget {
  final ExternalTerminalSession session;
  final bool enabled;
  final VoidCallback onTap;
  const _DiscoverSessionRow({
    required this.session,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    final subtitle = session.adopted
        ? 'Already adopted'
        : (session.isActive ? 'Active' : 'Exited (tap to revive)');
    return ListTile(
      enabled: enabled,
      title: Text(
        session.name,
        style: AppText.mono(fontSize: theme.textTheme.bodyMedium?.fontSize),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.labelSmall?.copyWith(color: dim),
      ),
      onTap: enabled ? onTap : null,
    );
  }
}
