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
import '../ui/app_tokens.dart';
import 'terminal_detail.dart';

class TerminalTab extends StatefulWidget {
  final AppState appState;
  const TerminalTab({super.key, required this.appState});

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

  Future<void> _confirmDispose(TerminalSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close terminal?'),
        content: Text(
          'Session ${s.id.substring(0, 8)}… will be killed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.appState.disposeTerminal(s.id);
    }
  }

  Future<void> _openDetail(TerminalSession s, int index) async {
    widget.appState.focusTerminal(s.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalDetailScreen(
          appState: widget.appState,
          sessionId: s.id,
          title: _sessionLabel(index),
        ),
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
          itemCount: sessions.length + 1,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == sessions.length) {
              return _NewSessionTile(onTap: _createAndOpen);
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
              onTap: () => _openDetail(s, index),
              onLongPress: () => _confirmDispose(s),
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
  final trimmed =
      path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
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
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _SessionTile({
    required this.label,
    required this.cwdBasename,
    required this.previewText,
    required this.timestamp,
    required this.onTap,
    required this.onLongPress,
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
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.terminal_outlined,
              color: dim,
              size: AppIconSize.md - 2,
            ),
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
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (cwdBasename.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: AppSpacing.sm),
                          child: Text(
                            cwdBasename,
                            style: TextStyle(fontSize: 12, color: dim),
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
                    style: TextStyle(
                      fontSize: 13,
                      color: dim,
                      fontFamily: 'monospace',
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
              style: TextStyle(fontSize: 12, color: dim),
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
            horizontal: AppSpacing.lg, vertical: AppSpacing.md + 2),
        child: Row(
          children: [
            Icon(Icons.add, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Text(
              'New terminal',
              style: TextStyle(
                fontSize: 15,
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
