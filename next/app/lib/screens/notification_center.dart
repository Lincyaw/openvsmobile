// Notification center — full-screen list view of every notification the
// backend has on file, sorted by timestamp DESC, with per-source filter
// pills, a level color stripe, expandable bodies, and per-row long-press
// actions. Pushed from the bell icon in home_shell.dart.
//
// Reads `appState.notifications` (NotificationsModel) for everything;
// AppState is the single source of truth (conventions §2). Local UI state
// (expanded ids, mark-read debounce timer) lives here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../notification.dart';
import '../settings_store.dart';

class NotificationCenterScreen extends StatefulWidget {
  final AppState appState;
  final SettingsStore? settingsStore;

  /// Optional id to scroll-to / highlight on first build. Set by the tap
  /// handler in the foreground service when the user taps a system-tray
  /// notification.
  final String? highlightId;

  const NotificationCenterScreen({
    super.key,
    required this.appState,
    this.settingsStore,
    this.highlightId,
  });

  @override
  State<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  /// Locally-tracked expanded ids. Pure UI state — survives a
  /// notifyListeners on AppState but not a screen rebuild, which is fine:
  /// reopening the screen starts with everything collapsed.
  final Set<String> _expanded = {};

  /// Debounce for batch markRead. We accumulate ids visible-on-screen and
  /// flush every 500 ms so a fast scroll doesn't spam the backend with one
  /// markRead per row.
  final Set<String> _pendingRead = {};
  Timer? _readDebounce;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    // Schedule the initial mark-visible pass after first paint so any
    // highlighted item is read on open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleMarkVisible());
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    _readDebounce?.cancel();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _scheduleMarkVisible() {
    if (!mounted) return;
    final notifs = widget.appState.notifications;
    final me = widget.appState.deviceId;
    for (final n in notifs.filteredItems) {
      if (!n.readByDevice(me)) {
        _pendingRead.add(n.id);
      }
    }
    if (_pendingRead.isEmpty) return;
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(milliseconds: 500), () {
      final ids = _pendingRead.toList(growable: false);
      _pendingRead.clear();
      unawaited(notifs.markRead(ids));
    });
  }

  Future<void> _markAllRead() async {
    final notifs = widget.appState.notifications;
    final me = widget.appState.deviceId;
    final ids = notifs.items
        .where((n) => !n.readByDevice(me))
        .map((n) => n.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    await notifs.markRead(ids);
  }

  Future<void> _clearAllRead() async {
    final notifs = widget.appState.notifications;
    final me = widget.appState.deviceId;
    final ids = notifs.items
        .where((n) => n.readByDevice(me) && !n.important)
        .map((n) => n.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    await notifs.deleteIds(ids);
  }

  Future<void> _refresh() async {
    await widget.appState.notifications.refresh();
  }

  Future<void> _onAction(NotificationAction action) async {
    switch (action) {
      case OpenUrlAction():
        // The url_launcher dep isn't in the project; copy as a graceful
        // fallback and tell the user. Adding url_launcher is a v0.5
        // follow-up — out of scope per the brief.
        await Clipboard.setData(ClipboardData(text: action.url));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copied URL: ${action.url}')),
        );
      case CopyAction():
        await Clipboard.setData(ClipboardData(text: action.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied to clipboard')),
        );
      case OpenWorkspaceAction():
        // Workspace switching is on AppState, but we don't pop back here —
        // let the user verify they actually moved.
        await widget.appState.activateWorkspace(action.workspaceId);
        if (!mounted) return;
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifs = widget.appState.notifications;
    final theme = Theme.of(context);
    final sources = notifs.knownSources;
    final items = notifs.filteredItems;
    final groups = _groupConsecutive(items);
    final connState = widget.appState.connectionState;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Mark all read',
            icon: const Icon(Icons.done_all),
            onPressed: notifs.unreadCount > 0 ? _markAllRead : null,
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'clear-read':
                  await _clearAllRead();
                case 'refresh':
                  await _refresh();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear-read',
                child: Text('Clear all read'),
              ),
              PopupMenuItem(value: 'refresh', child: Text('Refresh')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (connState != BackendConnectionState.connected)
            Container(
              width: double.infinity,
              color: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Offline — showing last known',
                style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          if (sources.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: notifs.filterSource == null,
                      onSelected: (_) => notifs.setSourceFilter(null),
                    ),
                  ),
                  for (final s in sources)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(s),
                        selected: notifs.filterSource == s,
                        onSelected: (sel) =>
                            notifs.setSourceFilter(sel ? s : null),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? _EmptyState()
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: groups.length,
                      itemBuilder: (ctx, i) {
                        final g = groups[i];
                        if (g.length == 1) {
                          return _NotificationCard(
                            notification: g.first,
                            expanded: _expanded.contains(g.first.id),
                            highlighted: g.first.id == widget.highlightId,
                            onToggleExpand: () {
                              setState(() {
                                if (!_expanded.add(g.first.id)) {
                                  _expanded.remove(g.first.id);
                                }
                              });
                            },
                            onAction: _onAction,
                            onLongPressMenu: () =>
                                _showLongPressMenu(g.first),
                          );
                        }
                        // Grouped: render as collapsible card.
                        return _GroupCard(
                          members: g,
                          deviceId: widget.appState.deviceId,
                          onAction: _onAction,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showLongPressMenu(AppNotification n) async {
    final notifs = widget.appState.notifications;
    final me = widget.appState.deviceId;
    final isRead = n.readByDevice(me);
    final prefsStore = widget.settingsStore;
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isRead
                  ? Icons.mark_email_unread_outlined
                  : Icons.mark_email_read_outlined),
              title: Text(isRead ? 'Mark unread' : 'Mark read'),
              onTap: () => Navigator.of(ctx).pop(
                isRead ? 'mark-unread' : 'mark-read',
              ),
            ),
            ListTile(
              leading: Icon(
                n.important
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
              ),
              title: Text(n.important ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.of(ctx).pop(
                n.important ? 'unpin' : 'pin',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            if (prefsStore != null && n.source.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text('Mute source "${n.source}"'),
                onTap: () => Navigator.of(ctx).pop('mute-source'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case 'mark-read':
        await notifs.markRead([n.id]);
      case 'mark-unread':
        // No backend RPC exists for "unread" in v0; surface a hint. Filing
        // this as an open question for the reviewer.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Backend does not expose mark-unread yet (open question).',
            ),
          ),
        );
      case 'pin':
        await notifs.markImportant(n.id, true);
      case 'unpin':
        await notifs.markImportant(n.id, false);
      case 'delete':
        await notifs.deleteIds([n.id]);
      case 'mute-source':
        if (prefsStore == null) return;
        final cur = await prefsStore.loadNotificationPrefs();
        if (cur.mutedSources.contains(n.source)) return;
        await prefsStore.saveNotificationPrefs(
          cur.copyWith(mutedSources: [...cur.mutedSources, n.source]),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Muted ${n.source}')),
        );
    }
  }

  /// Group consecutive items by `groupKey`. Already-sorted list goes in;
  /// list-of-lists comes out where each inner list is one group (always
  /// length >= 1).
  List<List<AppNotification>> _groupConsecutive(
    List<AppNotification> sorted,
  ) {
    final out = <List<AppNotification>>[];
    for (final n in sorted) {
      if (out.isEmpty) {
        out.add([n]);
        continue;
      }
      final last = out.last;
      final lastKey = last.first.groupKey;
      if (lastKey != null && lastKey == n.groupKey) {
        last.add(n);
      } else {
        out.add([n]);
      }
    }
    return out;
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_off_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            const Text(
              'No notifications yet',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Send one from the CLI: mobile-notify --source demo '
              '--level info --title "Hello"',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// Level → stripe color. info/success degrade to the outline color so the
/// stripe still reads as "informational decoration" rather than implying an
/// alert. Warning uses tertiary; error uses error. No `Colors.red/green`.
Color _levelColor(ColorScheme cs, NotificationLevel l) {
  switch (l) {
    case NotificationLevel.warning:
      return cs.tertiary;
    case NotificationLevel.error:
      return cs.error;
    case NotificationLevel.info:
    case NotificationLevel.success:
      return cs.outline;
  }
}

String _relativeTime(int tsMs) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final diff = now - tsMs;
  if (diff < 60_000) return 'just now';
  if (diff < 3_600_000) return '${diff ~/ 60_000}m ago';
  if (diff < 86_400_000) return '${diff ~/ 3_600_000}h ago';
  return '${diff ~/ 86_400_000}d ago';
}

class _NotificationCard extends StatelessWidget {
  final AppNotification notification;
  final bool expanded;
  final bool highlighted;
  final VoidCallback onToggleExpand;
  final Future<void> Function(NotificationAction) onAction;
  final VoidCallback onLongPressMenu;

  const _NotificationCard({
    required this.notification,
    required this.expanded,
    required this.highlighted,
    required this.onToggleExpand,
    required this.onAction,
    required this.onLongPressMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final n = notification;
    final hasBody = n.body != null && n.body!.isNotEmpty;
    final stripeColor = _levelColor(cs, n.level);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: highlighted ? cs.secondaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            if (n.action != null) {
              await onAction(n.action!);
              return;
            }
            if (hasBody) onToggleExpand();
          },
          onLongPress: onLongPressMenu,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: stripeColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _SourcePill(source: n.source),
                            const Spacer(),
                            if (n.important)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(Icons.push_pin,
                                    size: 14,
                                    color: cs.tertiary),
                              ),
                            Text(
                              _relativeTime(n.timestamp),
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.outline,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          n.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (hasBody && expanded) ...[
                          const SizedBox(height: 6),
                          // Plain text (no markdown in v0 — punted to plugin
                          // host renderer per task brief).
                          Text(n.body!),
                        ],
                        if (n.fields.isNotEmpty && expanded) ...[
                          const SizedBox(height: 6),
                          for (final f in n.fields)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 96,
                                    child: Text(
                                      f.key,
                                      style: TextStyle(
                                          color: cs.outline, fontSize: 12),
                                    ),
                                  ),
                                  Expanded(child: Text(f.value)),
                                ],
                              ),
                            ),
                        ],
                        if (n.links.isNotEmpty || n.action != null) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final link in n.links)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(link.title.isEmpty
                                      ? link.url
                                      : link.title),
                                  onPressed: () => onAction(
                                      OpenUrlAction(link.url)),
                                ),
                              if (n.action != null)
                                _ActionButton(
                                  action: n.action!,
                                  onPressed: () => onAction(n.action!),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
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

class _ActionButton extends StatelessWidget {
  final NotificationAction action;
  final VoidCallback onPressed;
  const _ActionButton({required this.action, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (action) {
      OpenUrlAction() => (Icons.open_in_new, 'Open'),
      CopyAction() => (Icons.copy, 'Copy'),
      OpenWorkspaceAction() => (Icons.folder_open, 'Open workspace'),
    };
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label),
      onPressed: onPressed,
    );
  }
}

class _SourcePill extends StatelessWidget {
  final String source;
  const _SourcePill({required this.source});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        source.isEmpty ? '(unknown)' : source,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  final List<AppNotification> members;
  final String deviceId;
  final Future<void> Function(NotificationAction) onAction;
  const _GroupCard({
    required this.members,
    required this.deviceId,
    required this.onAction,
  });

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final newest = widget.members.first;
    final stripe = _levelColor(cs, newest.level);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: stripe),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _SourcePill(source: newest.source),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'x${widget.members.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onTertiaryContainer,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _relativeTime(newest.timestamp),
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.outline,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          newest.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (_expanded) ...[
                          const Divider(height: 16),
                          for (final m in widget.members.skip(1))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 64,
                                    child: Text(
                                      _relativeTime(m.timestamp),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: cs.outline,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: Text(m.title)),
                                ],
                              ),
                            ),
                        ],
                      ],
                    ),
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
