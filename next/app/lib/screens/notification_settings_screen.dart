// Notification preferences — section of Settings dedicated to the §4.5
// notification surface. Kept separate from the connection-settings screen
// because it touches a different concern (foreground service behavior +
// per-source mute list) and the save model is per-toggle rather than
// the host/port/token "save and reconnect" flow.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings_store.dart';

class NotificationSettingsScreen extends StatefulWidget {
  final AppState appState;
  final SettingsStore settingsStore;
  const NotificationSettingsScreen({
    super.key,
    required this.appState,
    required this.settingsStore,
  });

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  NotificationPrefs? _prefs;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await widget.settingsStore.loadNotificationPrefs();
    if (!mounted) return;
    setState(() => _prefs = p);
  }

  Future<void> _save(NotificationPrefs next) async {
    setState(() {
      _prefs = next;
      _saving = true;
    });
    await widget.settingsStore.saveNotificationPrefs(next);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final cur = _prefs!;
    final initialMinutes = isStart
        ? (cur.quietHoursStartMinutes ?? 22 * 60)
        : (cur.quietHoursEndMinutes ?? 7 * 60);
    final result = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: initialMinutes ~/ 60,
        minute: initialMinutes % 60,
      ),
    );
    if (result == null) return;
    final mins = result.hour * 60 + result.minute;
    await _save(isStart
        ? cur.copyWith(quietHoursStartMinutes: mins)
        : cur.copyWith(quietHoursEndMinutes: mins));
  }

  String _fmtMinutes(int? m) {
    if (m == null) return 'not set';
    final h = (m ~/ 60).toString().padLeft(2, '0');
    final mm = (m % 60).toString().padLeft(2, '0');
    return '$h:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _prefs;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Loading notification preferences…'),
            ],
          ),
        ),
      );
    }
    final sources = widget.appState.notifications.knownSources;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.cell_tower_outlined),
            title: const Text('Background notifications'),
            subtitle: const Text(
              'Keep an always-on connection so notifications reach the '
              'system tray when the app is closed. Requires a small '
              'persistent indicator in the status bar.',
            ),
            value: p.backgroundEnabled,
            onChanged: _saving
                ? null
                : (v) => _save(p.copyWith(backgroundEnabled: v)),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bedtime_outlined),
            title: const Text('Quiet hours'),
            subtitle: Text(
              p.quietHoursStartMinutes == null &&
                      p.quietHoursEndMinutes == null
                  ? 'Off'
                  : '${_fmtMinutes(p.quietHoursStartMinutes)} → '
                      '${_fmtMinutes(p.quietHoursEndMinutes)}',
            ),
            trailing: p.quietHoursStartMinutes != null ||
                    p.quietHoursEndMinutes != null
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear quiet hours',
                    onPressed: _saving
                        ? null
                        : () => _save(p.copyWith(clearQuietHours: true)),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => _pickTime(isStart: true),
                    child: Text('Start: ${_fmtMinutes(p.quietHoursStartMinutes)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => _pickTime(isStart: false),
                    child: Text('End: ${_fmtMinutes(p.quietHoursEndMinutes)}'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Default TTL'),
            subtitle: Text(
              '${p.defaultTtlDays} day${p.defaultTtlDays == 1 ? '' : 's'}',
            ),
            trailing: SizedBox(
              width: 120,
              child: Slider(
                min: 1,
                max: 30,
                divisions: 29,
                value: p.defaultTtlDays.toDouble(),
                onChanged: _saving
                    ? null
                    : (v) =>
                        _save(p.copyWith(defaultTtlDays: v.round())),
              ),
            ),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Per-source mute',
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (sources.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'No sources seen yet. The mute list grows as notifications '
                'arrive.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          for (final src in sources)
            CheckboxListTile(
              title: Text(src),
              subtitle: const Text(
                'When muted: still appears in the in-app center, '
                'but no system-tray notification.',
              ),
              value: p.mutedSources.contains(src),
              onChanged: _saving
                  ? null
                  : (v) {
                      final next = List<String>.from(p.mutedSources);
                      if (v == true) {
                        if (!next.contains(src)) next.add(src);
                      } else {
                        next.remove(src);
                      }
                      _save(p.copyWith(mutedSources: next));
                    },
            ),
        ],
      ),
    );
  }
}
