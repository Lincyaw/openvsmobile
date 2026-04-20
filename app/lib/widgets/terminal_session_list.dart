import 'package:flutter/material.dart';

import '../providers/terminal_provider.dart';

class TerminalSessionList extends StatelessWidget {
  const TerminalSessionList({
    super.key,
    required this.sessions,
    required this.activeSessionId,
    required this.secondarySessionId,
    required this.allowSecondarySelection,
    required this.onSelect,
    required this.onRename,
    required this.onClose,
  });

  final List<TerminalSessionView> sessions;
  final String? activeSessionId;
  final String? secondarySessionId;
  final bool allowSecondarySelection;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Text('No terminal sessions yet.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final view = sessions[index];
        final isActive = view.session.id == activeSessionId;
        final isSecondary =
            allowSecondarySelection &&
            view.session.id == secondarySessionId &&
            view.session.id != activeSessionId;

        return Card(
          clipBehavior: Clip.antiAlias,
          color: isActive
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: InkWell(
            onTap: () => onSelect(view.session.id),
            child: Padding(
              padding: const EdgeInsets.all(12),
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
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (isActive)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Chip(label: Text('Primary')),
                        ),
                      if (isSecondary)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Chip(label: Text('Split')),
                        ),
                      PopupMenuButton<String>(
                        tooltip: 'Session actions',
                        onSelected: (value) {
                          if (value == 'rename') {
                            onRename(view.session.id);
                          } else if (value == 'close') {
                            onClose(view.session.id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          PopupMenuItem<String>(
                            value: 'close',
                            child: Text('Close'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    view.statusLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (view.session.exitCode != null)
                    Text(
                      'Exit code ${view.session.exitCode}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  Text(
                    view.session.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
