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
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../ui/app_tokens.dart';
import '../backend_client.dart';
import '../notification.dart';
import '../settings_store.dart';
import 'agent_hooks_screen.dart';

class NotificationCenterScreen extends StatefulWidget {
  final AppState appState;
  final SettingsStore? settingsStore;
  final Future<void> Function(OpenTerminalAction action)? onOpenTerminal;

  /// Optional id to scroll-to / highlight on first build. Set by the tap
  /// handler in the foreground service when the user taps a system-tray
  /// notification.
  final String? highlightId;

  const NotificationCenterScreen({
    super.key,
    required this.appState,
    this.settingsStore,
    this.onOpenTerminal,
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
  final Set<String> _expandedGroups = {};

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _visibilityKeys = {};
  final Map<String, List<String>> _entryIdsByKey = {};
  bool _visibilityPassScheduled = false;

  /// Debounce for batch markRead. We accumulate ids whose rendered cards
  /// intersect the viewport and flush every 500 ms so a fast scroll doesn't
  /// spam the backend with one markRead per row.
  final Set<String> _pendingRead = {};
  Timer? _readDebounce;
  bool _highlightActionHandled = false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _scrollController.addListener(_scheduleMarkVisible);
    // Schedule the initial mark-visible pass after first paint. This only
    // marks cards that actually rendered into the viewport; it deliberately
    // does not clear the whole filtered feed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleMarkVisible();
      unawaited(_runHighlightedActionIfAny());
    });
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    _scrollController.removeListener(_scheduleMarkVisible);
    _scrollController.dispose();
    _readDebounce?.cancel();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleMarkVisible();
  }

  void _scheduleMarkVisible() {
    if (!mounted) return;
    if (_visibilityPassScheduled) return;
    _visibilityPassScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityPassScheduled = false;
      if (!mounted) return;
      _markRenderedVisibleItemsRead();
    });
  }

  void _markRenderedVisibleItemsRead() {
    final rootObject = context.findRenderObject();
    if (rootObject is! RenderBox || !rootObject.hasSize) return;
    final viewport = Offset.zero & rootObject.size;
    final notifs = widget.appState.notifications;
    final me = widget.appState.deviceId;
    for (final entry in _entryIdsByKey.entries) {
      final itemContext = _visibilityKeys[entry.key]?.currentContext;
      if (itemContext == null) continue;
      final itemObject = itemContext.findRenderObject();
      if (itemObject is! RenderBox || !itemObject.hasSize) continue;
      final topLeft = rootObject.globalToLocal(
        itemObject.localToGlobal(Offset.zero),
      );
      final itemRect = topLeft & itemObject.size;
      if (!itemRect.overlaps(viewport)) continue;
      for (final id in entry.value) {
        final n = notifs.byId(id);
        if (n != null && !n.readByDevice(me)) {
          _pendingRead.add(id);
        }
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

  String _entryKeyFor(List<AppNotification> group) {
    if (group.length == 1) return 'n:${group.first.id}';
    final keys = _notificationGroupKeys(group.first);
    final key = keys.isEmpty ? group.first.id : keys.first;
    return 'g:$key:${group.first.id}:${group.length}';
  }

  GlobalKey _visibilityKeyFor(String key) =>
      _visibilityKeys.putIfAbsent(key, GlobalKey.new);

  String _memberEntryKey(String groupEntryKey, String id) =>
      '$groupEntryKey/member:$id';

  void _syncVisibilityEntries(List<List<AppNotification>> groups) {
    final live = <String>{};
    for (final group in groups) {
      final key = _entryKeyFor(group);
      live.add(key);
      // A collapsed group renders only its newest row. Seeing the aggregate
      // card should not implicitly mark every hidden member as read. Expanded
      // history rows get their own keys so large groups only mark rows that
      // actually intersect the viewport.
      _entryIdsByKey[key] = [group.first.id];
      _visibilityKeyFor(key);
      if (_expandedGroups.contains(key)) {
        for (final member in group.skip(1)) {
          final memberKey = _memberEntryKey(key, member.id);
          live.add(memberKey);
          _entryIdsByKey[memberKey] = [member.id];
          _visibilityKeyFor(memberKey);
        }
      }
    }
    _expandedGroups.removeWhere((key) => !live.contains(key));
    _visibilityKeys.removeWhere((key, _) => !live.contains(key));
    _entryIdsByKey.removeWhere((key, _) => !live.contains(key));
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

  void _openAgentHooks() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentHooksScreen(appState: widget.appState),
      ),
    );
  }

  Future<void> _runHighlightedActionIfAny() async {
    if (_highlightActionHandled) return;
    final id = widget.highlightId;
    if (id == null) return;
    _highlightActionHandled = true;
    var notification = widget.appState.notifications.byId(id);
    if (notification == null) {
      await widget.appState.notifications.refresh();
      if (!mounted) return;
      notification = widget.appState.notifications.byId(id);
    }
    final action = notification?.action;
    if (action is! OpenTerminalAction) return;
    await _onAction(action);
  }

  Future<void> _onAction(NotificationAction action) async {
    switch (action) {
      case OpenUrlAction():
        // Capture the messenger before the await so we don't reach for
        // BuildContext after suspension — see conventions §2
        // "Cancellation discipline".
        final messenger = ScaffoldMessenger.of(context);
        Uri? uri;
        try {
          uri = Uri.parse(action.url);
        } on FormatException {
          uri = null;
        }
        var launched = false;
        if (uri != null) {
          try {
            launched = await launchUrl(
              uri,
              mode: LaunchMode.externalApplication,
            );
          } on PlatformException catch (e) {
            // No browser, scheme unsupported, etc. — fall through to the
            // clipboard path so the user still has a way to act.
            debugPrint('launchUrl failed: $e');
            launched = false;
          }
        }
        if (!launched) {
          await Clipboard.setData(ClipboardData(text: action.url));
          messenger.showSnackBar(
            SnackBar(
              content: Text('Could not open, URL copied: ${action.url}'),
            ),
          );
        }
      case CopyAction():
        await Clipboard.setData(ClipboardData(text: action.text));
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
      case OpenWorkspaceAction():
        // Workspace switching is on AppState, but we don't pop back here —
        // let the user verify they actually moved.
        await widget.appState.activateWorkspace(action.workspaceId);
        if (!mounted) return;
        Navigator.of(context).pop();
      case OpenTerminalAction():
        final opener = widget.onOpenTerminal;
        if (opener == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Terminal target is unavailable')),
          );
          return;
        }
        Navigator.of(context).pop();
        await Future<void>.delayed(Duration.zero);
        await opener(action);
    }
  }

  Future<void> _replyToNotification(AppNotification n) async {
    final reply = n.reply;
    if (reply == null) return;
    final placeholder = reply.placeholder == null || reply.placeholder!.isEmpty
        ? 'Reply'
        : reply.placeholder!;
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NotificationReplySheet(
        placeholder: placeholder,
        confirmRequired: reply.confirmRequired,
      ),
    );
    if (!mounted || text == null || text.trim().isEmpty) return;
    await widget.appState.notifications.reply(n.id, text);
  }

  @override
  Widget build(BuildContext context) {
    final notifs = widget.appState.notifications;
    final theme = Theme.of(context);
    final sources = notifs.knownSources;
    final items = notifs.filteredItems;
    final agentSessions = _agentSessionSummaries(
      items,
      widget.appState.deviceId,
    );
    final groups = _groupConsecutive(items);
    _syncVisibilityEntries(groups);
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
              PopupMenuItem(value: 'clear-read', child: Text('Clear all read')),
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
          if (agentSessions.isNotEmpty)
            _AgentSessionStrip(summaries: agentSessions, onAction: _onAction),
          Expanded(
            child: items.isEmpty
                ? _EmptyState(onSetUpAgentAlerts: _openAgentHooks)
                // No pull-to-refresh: per first principle #1 the feed is
                // push-driven via `notification.show` / `.readChanged` /
                // `.deleted`. The "Refresh" menu item still pulls a full
                // snapshot for users who explicitly ask.
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: groups.length,
                    itemBuilder: (ctx, i) {
                      final g = groups[i];
                      final entryKey = _entryKeyFor(g);
                      if (g.length == 1) {
                        return KeyedSubtree(
                          key: _visibilityKeyFor(entryKey),
                          child: _NotificationCard(
                            notification: g.first,
                            expanded: _expanded.contains(g.first.id),
                            highlighted: g.first.id == widget.highlightId,
                            onToggleExpand: () {
                              setState(() {
                                if (!_expanded.add(g.first.id)) {
                                  _expanded.remove(g.first.id);
                                }
                              });
                              _scheduleMarkVisible();
                            },
                            onAction: _onAction,
                            onReply: _replyToNotification,
                            onLongPressMenu: () => _showLongPressMenu(g.first),
                          ),
                        );
                      }
                      // Grouped: render as collapsible card.
                      final expanded = _expandedGroups.contains(entryKey);
                      return KeyedSubtree(
                        key: _visibilityKeyFor(entryKey),
                        child: _GroupCard(
                          members: g,
                          deviceId: widget.appState.deviceId,
                          expanded: expanded,
                          onAction: _onAction,
                          onReply: _replyToNotification,
                          visibilityKeyForMember: (member) => _visibilityKeyFor(
                            _memberEntryKey(entryKey, member.id),
                          ),
                          onToggleExpand: () {
                            setState(() {
                              if (!_expandedGroups.add(entryKey)) {
                                _expandedGroups.remove(entryKey);
                              }
                            });
                            _scheduleMarkVisible();
                          },
                        ),
                      );
                    },
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
            // Design §4.5 long-press menu: "mark read / delete / pin /
            // mute source". No mark-unread — backend has no inverse RPC
            // in v0, and the design intentionally omits it.
            if (!isRead)
              ListTile(
                leading: const Icon(Icons.mark_email_read_outlined),
                title: const Text('Mark read'),
                onTap: () => Navigator.of(ctx).pop('mark-read'),
              ),
            ListTile(
              leading: Icon(
                n.important ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(n.important ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.of(ctx).pop(n.important ? 'unpin' : 'pin'),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Muted ${n.source}')));
    }
  }

  /// Group consecutive items by their rendered workflow key. Agent terminal
  /// actions use the terminal target so repeated Claude/Codex runs in one
  /// zellij/session collapse even when the agent emits a new session id per
  /// run; other senders keep the protocol-level `groupKey` behavior.
  List<List<AppNotification>> _groupConsecutive(List<AppNotification> sorted) {
    final out = <List<AppNotification>>[];
    for (final n in sorted) {
      if (out.isEmpty) {
        out.add([n]);
        continue;
      }
      final last = out.last;
      if (_shareNotificationGroupKey(last.first, n)) {
        last.add(n);
      } else {
        out.add([n]);
      }
    }
    return out;
  }

  List<_AgentSessionSummary> _agentSessionSummaries(
    List<AppNotification> sorted,
    String deviceId,
  ) {
    final byKey = <String, _AgentSessionSummary>{};
    for (final n in sorted) {
      final action = n.action;
      if (action is! OpenTerminalAction) continue;
      final key = _terminalActionKey(action);
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = _AgentSessionSummary(
          key: key,
          latest: n,
          action: action,
          totalCount: 1,
          unreadCount: n.readByDevice(deviceId) ? 0 : 1,
        );
        continue;
      }
      byKey[key] = existing.add(n, deviceId);
    }
    final summaries = byKey.values.toList(growable: false)
      ..sort((a, b) => b.latest.timestamp.compareTo(a.latest.timestamp));
    return summaries.take(6).toList(growable: false);
  }
}

bool _shareNotificationGroupKey(AppNotification a, AppNotification b) {
  final aKeys = _notificationGroupKeys(a);
  if (aKeys.isEmpty) return false;
  final bKeys = _notificationGroupKeys(b);
  if (bKeys.isEmpty) return false;
  for (final key in aKeys) {
    if (bKeys.contains(key)) return true;
  }
  return false;
}

List<String> _notificationGroupKeys(AppNotification n) {
  final keys = <String>[];
  final action = n.action;
  if (action is OpenTerminalAction) {
    keys.add('terminal:${_terminalActionKey(action)}');
  }
  final groupKey = n.groupKey;
  if (groupKey != null && groupKey.isNotEmpty) {
    keys.add('group:$groupKey');
  }
  return keys;
}

String _terminalActionKey(OpenTerminalAction action) {
  final backend = action.backendId ?? '';
  final session = action.sessionId ?? '';
  final external = action.externalSessionId ?? '';
  return '$backend|$session|$external';
}

@immutable
class _AgentSessionSummary {
  final String key;
  final AppNotification latest;
  final OpenTerminalAction action;
  final int totalCount;
  final int unreadCount;

  const _AgentSessionSummary({
    required this.key,
    required this.latest,
    required this.action,
    required this.totalCount,
    required this.unreadCount,
  });

  _AgentSessionSummary add(AppNotification n, String deviceId) {
    final nextLatest = n.timestamp > latest.timestamp ? n : latest;
    return _AgentSessionSummary(
      key: key,
      latest: nextLatest,
      action: action,
      totalCount: totalCount + 1,
      unreadCount: unreadCount + (n.readByDevice(deviceId) ? 0 : 1),
    );
  }
}

class _AgentSessionStrip extends StatelessWidget {
  final List<_AgentSessionSummary> summaries;
  final Future<void> Function(NotificationAction) onAction;

  const _AgentSessionStrip({required this.summaries, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    size: AppIconSize.sm,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Agent sessions', style: theme.textTheme.labelLarge),
                ],
              ),
            ),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: summaries.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, index) => _AgentSessionCard(
                  summary: summaries[index],
                  onTap: () => onAction(summaries[index].action),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentSessionCard extends StatelessWidget {
  final _AgentSessionSummary summary;
  final VoidCallback onTap;

  const _AgentSessionCard({required this.summary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final n = summary.latest;
    final target = _agentTargetLabel(summary.action);
    final unread = summary.unreadCount;
    return SizedBox(
      key: ValueKey<String>('agent-session:${summary.key}'),
      width: 246,
      child: Material(
        color: unread > 0
            ? cs.primaryContainer.withValues(alpha: 0.34)
            : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: unread > 0 ? cs.primary : cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SourcePill(source: n.source),
                    const Spacer(),
                    if (unread > 0)
                      Badge.count(
                        count: unread,
                        backgroundColor: cs.primary,
                        textColor: cs.onPrimary,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      n.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.monoCaption(
                          context,
                        ).copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(
                      Icons.arrow_forward,
                      size: AppIconSize.sm,
                      color: cs.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _agentTargetLabel(OpenTerminalAction action) {
  final external = action.externalSessionId;
  if (external != null && external.isNotEmpty) return external;
  final sessionId = action.sessionId;
  if (sessionId == null || sessionId.isEmpty) return 'terminal';
  return sessionId.length <= 12 ? sessionId : sessionId.substring(0, 12);
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onSetUpAgentAlerts;

  const _EmptyState({required this.onSetUpAgentAlerts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 48, color: cs.primary),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'No agent alerts yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Install Claude/Codex hooks so terminal-launched agents can '
              'notify this phone when they stop or need attention.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              key: const ValueKey<String>('notifications-empty-agent-hooks'),
              onPressed: onSetUpAgentAlerts,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Set up agent alerts'),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'For scripts and CI: mobile-notify --source demo '
              '--level info --title "Hello"',
              textAlign: TextAlign.center,
              style: AppText.monoCaption(
                context,
              ).copyWith(color: cs.onSurfaceVariant),
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
  final Future<void> Function(AppNotification) onReply;
  final VoidCallback onLongPressMenu;

  const _NotificationCard({
    required this.notification,
    required this.expanded,
    required this.highlighted,
    required this.onToggleExpand,
    required this.onAction,
    required this.onReply,
    required this.onLongPressMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final n = notification;
    final hasBody = n.body != null && n.body!.isNotEmpty;
    final hasExpandableDetails = hasBody || n.fields.isNotEmpty;
    final hasActions =
        n.links.isNotEmpty || n.action != null || n.reply != null;
    final stripeColor = _levelColor(cs, n.level);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: highlighted ? cs.secondaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            if (hasExpandableDetails) {
              onToggleExpand();
              return;
            }
            if (n.action != null) await onAction(n.action!);
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
                      horizontal: 12,
                      vertical: 10,
                    ),
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
                                child: Icon(
                                  Icons.push_pin,
                                  size: 14,
                                  color: cs.tertiary,
                                ),
                              ),
                            if (hasExpandableDetails)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  expanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 18,
                                  color: cs.outline,
                                ),
                              ),
                            Text(
                              _relativeTime(n.timestamp),
                              style: TextStyle(fontSize: 12, color: cs.outline),
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
                        if (hasActions) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final link in n.links)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(
                                    link.title.isEmpty ? link.url : link.title,
                                  ),
                                  onPressed: () =>
                                      onAction(OpenUrlAction(link.url)),
                                ),
                              if (n.action != null)
                                _ActionButton(
                                  action: n.action!,
                                  onPressed: () => onAction(n.action!),
                                ),
                              if (n.reply != null)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.reply, size: 16),
                                  label: const Text('Reply'),
                                  onPressed: () => onReply(n),
                                ),
                            ],
                          ),
                        ],
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
                                        color: cs.outline,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: Text(f.value)),
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

class _NotificationReplySheet extends StatefulWidget {
  final String placeholder;
  final bool confirmRequired;

  const _NotificationReplySheet({
    required this.placeholder,
    required this.confirmRequired,
  });

  @override
  State<_NotificationReplySheet> createState() =>
      _NotificationReplySheetState();
}

class _NotificationReplySheetState extends State<_NotificationReplySheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    if (value.trim().isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                labelText: widget.placeholder,
                prefixIcon: const Icon(Icons.reply),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
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
      OpenTerminalAction() => (Icons.terminal, 'Open terminal'),
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
        style: AppText.mono(fontSize: 11),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final List<AppNotification> members;
  final String deviceId;
  final bool expanded;
  final Future<void> Function(NotificationAction) onAction;
  final Future<void> Function(AppNotification) onReply;
  final GlobalKey Function(AppNotification member) visibilityKeyForMember;
  final VoidCallback onToggleExpand;
  const _GroupCard({
    required this.members,
    required this.deviceId,
    required this.expanded,
    required this.onAction,
    required this.onReply,
    required this.visibilityKeyForMember,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final newest = members.first;
    final stripe = _levelColor(cs, newest.level);
    final hasLatestActions =
        newest.links.isNotEmpty ||
        newest.action != null ||
        newest.reply != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onToggleExpand,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: stripe),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _SourcePill(source: newest.source),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'x${members.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onTertiaryContainer,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _relativeTime(newest.timestamp),
                              style: TextStyle(fontSize: 12, color: cs.outline),
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
                        if (hasLatestActions) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final link in newest.links)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: Text(
                                    link.title.isEmpty ? link.url : link.title,
                                  ),
                                  onPressed: () =>
                                      onAction(OpenUrlAction(link.url)),
                                ),
                              if (newest.action != null)
                                _ActionButton(
                                  action: newest.action!,
                                  onPressed: () => onAction(newest.action!),
                                ),
                              if (newest.reply != null)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.reply, size: 16),
                                  label: const Text('Reply'),
                                  onPressed: () => onReply(newest),
                                ),
                            ],
                          ),
                        ],
                        if (expanded) ...[
                          const Divider(height: 16),
                          for (final m in members.skip(1))
                            SizedBox(
                              key: visibilityKeyForMember(m),
                              width: double.infinity,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
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
