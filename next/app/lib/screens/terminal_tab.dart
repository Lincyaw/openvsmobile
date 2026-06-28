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
import '../ui/app_tokens.dart';
import 'terminal_detail.dart';

class TerminalTab extends StatefulWidget {
  final AppState appState;
  final SettingsStore? settingsStore;
  const TerminalTab({super.key, required this.appState, this.settingsStore});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  // Drives the per-second timestamp tick so "5m" / "2h" stay current while
  // the user keeps the list open. The preview-version listenable handles
  // text changes; this clock handles relative-time staleness.
  Timer? _clockTick;
  int _clockEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _clockTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _clockEpoch++);
    });
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    _clockTick?.cancel();
    super.dispose();
  }

  void _onAppStateChanged() {
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
    }
  }

  Future<void> _openDetail(TerminalSession s, int index) async {
    widget.appState.focusTerminal(s.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalDetailScreen(
          appState: widget.appState,
          settingsStore: widget.settingsStore,
          sessionId: s.id,
          title: _sessionLabel(index),
        ),
      ),
    );
  }

  Future<void> _openDiscoverSheet() async {
    final w = widget.appState.currentWorkspace;
    if (w == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _DiscoverSessionsSheet(
        appState: widget.appState,
        workspaceId: w.id,
        onAdopted: (session) {
          Navigator.of(sheetCtx).pop();
          final sessions = widget.appState.currentTerminals;
          final idx = sessions.indexWhere((s) => s.id == session.id);
          _openDetail(session, idx >= 0 ? idx : sessions.length - 1);
        },
      ),
    );
  }

  Future<void> _createAndOpen() async {
    final w = widget.appState.currentWorkspace;
    if (w == null) return;
    final created = await widget.appState.createTerminal(
      workspaceId: w.id,
      cols: 80,
      rows: 24,
    );
    if (!mounted || created == null) return;
    final sessions = widget.appState.currentTerminals;
    final idx = sessions.indexWhere((s) => s.id == created.id);
    await _openDetail(created, idx >= 0 ? idx : sessions.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.appState.currentWorkspace;
    if (w == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'No workspace open.\n'
            'Tap the title bar to choose one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
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
              label: _sessionLabel(index),
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
}

/// Auto-generated session label, "sh · N" — the brief's example shape.
/// Sessions don't carry their shell binary on the wire today; once the
/// backend reports it we can drop the literal "sh".
String _sessionLabel(int index) => 'sh · ${index + 1}';

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
  const _SessionTile({
    required this.label,
    required this.cwdBasename,
    required this.previewText,
    required this.timestamp,
    required this.onTap,
    required this.onLongPress,
    this.detached = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.terminal_outlined, color: dim, size: AppIconSize.md),
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
                      if (cwdBasename.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: AppSpacing.sm),
                          child: Text(
                            cwdBasename,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: dim,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    previewText ?? '(no output yet)',
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
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              timestamp,
              style: theme.textTheme.labelSmall?.copyWith(color: dim),
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

class _DiscoverSessionsSheet extends StatefulWidget {
  final AppState appState;
  final String workspaceId;
  final void Function(TerminalSession session) onAdopted;
  const _DiscoverSessionsSheet({
    required this.appState,
    required this.workspaceId,
    required this.onAdopted,
  });

  @override
  State<_DiscoverSessionsSheet> createState() => _DiscoverSessionsSheetState();
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
