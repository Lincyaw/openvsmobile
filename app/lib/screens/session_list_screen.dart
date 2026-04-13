import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/session.dart';
import '../providers/chat_provider.dart';
import 'session_detail_screen.dart';

/// Screen showing past AI chat sessions with search, project grouping,
/// and timeline view with date section headers.
class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().loadSessions();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    setState(() => _searchQuery = query);
    context.read<ChatProvider>().loadSessions(query: query);
  }

  /// Group sessions by project name, then sort each group by date descending.
  Map<String, List<SessionMeta>> _groupByProject(List<SessionMeta> sessions) {
    final map = <String, List<SessionMeta>>{};
    for (final s in sessions) {
      final name = s.projectName;
      map.putIfAbsent(name, () => []).add(s);
    }
    // Sort each group by date descending.
    for (final list in map.values) {
      list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    }
    return map;
  }

  /// Build a flat list of widgets: date headers + session tiles, sorted by date.
  List<Widget> _buildTimelineList(List<SessionMeta> sessions) {
    // Sort all sessions by date descending.
    final sorted = List<SessionMeta>.from(sessions)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    final widgets = <Widget>[];
    String? lastDateLabel;

    for (final session in sorted) {
      final dateLabel = _dateGroupLabel(session.startedAt);
      if (dateLabel != lastDateLabel) {
        lastDateLabel = dateLabel;
        widgets.add(_DateHeader(label: dateLabel));
      }
      widgets.add(_SessionTile(session: session));
    }

    return widgets;
  }

  String _dateGroupLabel(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (date == today) return 'Today';
    if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
    if (now.difference(date).inDays < 7) {
      return DateFormat.EEEE().format(dateTime); // e.g. "Monday"
    }
    if (dateTime.year == now.year) {
      return DateFormat.MMMd().format(dateTime); // e.g. "Apr 10"
    }
    return DateFormat.yMMMd().format(dateTime); // e.g. "Apr 10, 2025"
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Session History'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(100),
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search sessions...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('');
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      isDense: true,
                    ),
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Timeline'),
                    Tab(text: 'By Project'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: Consumer<ChatProvider>(
          builder: (context, provider, _) {
            if (provider.isLoadingSessions) {
              return const Center(child: CircularProgressIndicator());
            }

            if (provider.error != null && provider.sessions.isEmpty) {
              return _buildErrorState(context, provider);
            }

            if (provider.sessions.isEmpty) {
              return _buildEmptyState(context);
            }

            return TabBarView(
              children: [
                _buildTimelineTab(provider.sessions),
                _buildProjectTab(provider.sessions),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTimelineTab(List<SessionMeta> sessions) {
    final widgets = _buildTimelineList(sessions);
    return RefreshIndicator(
      onRefresh: () => context
          .read<ChatProvider>()
          .loadSessions(query: _searchQuery.isEmpty ? null : _searchQuery),
      child: ListView(children: widgets),
    );
  }

  Widget _buildProjectTab(List<SessionMeta> sessions) {
    final grouped = _groupByProject(sessions);
    final projectNames = grouped.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: () => context
          .read<ChatProvider>()
          .loadSessions(query: _searchQuery.isEmpty ? null : _searchQuery),
      child: ListView.builder(
        itemCount: projectNames.length,
        itemBuilder: (context, index) {
          final projectName = projectNames[index];
          final projectSessions = grouped[projectName]!;
          return _ProjectGroup(
            projectName: projectName,
            sessions: projectSessions,
          );
        },
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, ChatProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Failed to load sessions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              provider.error!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => provider.loadSessions(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isNotEmpty ? 'No matching sessions' : 'No sessions yet',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  final String label;

  const _DateHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _ProjectGroup extends StatelessWidget {
  final String projectName;
  final List<SessionMeta> sessions;

  const _ProjectGroup({
    required this.projectName,
    required this.sessions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                projectName,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${sessions.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...sessions.map((s) => _SessionTile(session: s)),
        const Divider(),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionMeta session;

  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        child: Icon(
          Icons.chat_outlined,
          color: colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        session.projectName,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            _formatTimeAgo(session.startedAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (session.entrypoint.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                session.entrypoint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onTertiaryContainer,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SessionDetailScreen(session: session),
          ),
        );
      },
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return DateFormat.MMMd().format(dateTime);
  }
}
