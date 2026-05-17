// Notification preferences — section of Settings dedicated to the §4.5
// notification surface. Kept separate from the connection-settings screen
// because it touches a different concern (foreground service behavior +
// per-source mute list) and the save model is per-toggle rather than
// the host/port/token "save and reconnect" flow.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../settings_store.dart';

class NotificationSettingsScreen extends StatefulWidget {
  final AppState appState;
  final SettingsStore settingsStore;

  /// Notify main.dart that something changed so it can (re)start or stop
  /// the foreground service. Called after every successful save.
  final Future<void> Function() onChanged;

  const NotificationSettingsScreen({
    super.key,
    required this.appState,
    required this.settingsStore,
    required this.onChanged,
  });

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> with WidgetsBindingObserver {
  static const String _kBackgroundOnboardedKey = 'background-onboarded';

  NotificationPrefs? _prefs;
  bool _saving = false;
  PermissionStatus _permission = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user returns from system settings (where they may have
    // granted POST_NOTIFICATIONS), re-check the permission so the toggle
    // reflects current OS state.
    if (state == AppLifecycleState.resumed) {
      _refreshPermission();
    }
  }

  Future<void> _load() async {
    final p = await widget.settingsStore.loadNotificationPrefs();
    final perm = await Permission.notification.status;
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _permission = perm;
    });
  }

  Future<void> _refreshPermission() async {
    final perm = await Permission.notification.status;
    if (!mounted) return;
    if (perm != _permission) {
      setState(() => _permission = perm);
    }
  }

  Future<bool> _ensurePermission() async {
    var perm = await Permission.notification.status;
    if (perm.isPermanentlyDenied) {
      if (!mounted) return false;
      setState(() => _permission = perm);
      return false;
    }
    if (!perm.isGranted) {
      perm = await Permission.notification.request();
    }
    if (!mounted) return false;
    setState(() => _permission = perm);
    return perm.isGranted;
  }

  Future<void> _save(NotificationPrefs next) async {
    setState(() {
      _prefs = next;
      _saving = true;
    });
    await widget.settingsStore.saveNotificationPrefs(next);
    await widget.onChanged();
    if (!mounted) return;
    setState(() => _saving = false);
  }

  Future<void> _onToggleBackground(bool desired) async {
    final cur = _prefs!;
    // Capture the messenger up front so we don't reach for BuildContext
    // after the permission-prompt await — conventions §2 "Cancellation
    // discipline".
    final scaffold = ScaffoldMessenger.maybeOf(context);
    if (!desired) {
      await _save(cur.copyWith(backgroundEnabled: false));
      return;
    }
    final granted = await _ensurePermission();
    if (!granted) {
      // Toggle stays off; tell the user where to fix it.
      scaffold?.showSnackBar(
        SnackBar(
          content: const Text(
            'Notification permission denied. Enable it in system settings '
            'to turn on background notifications.',
          ),
          action: SnackBarAction(
            label: 'Open',
            onPressed: openAppSettings,
          ),
        ),
      );
      // Persist the off state so future loads see truth.
      await _save(cur.copyWith(backgroundEnabled: false));
      return;
    }
    await _save(cur.copyWith(backgroundEnabled: true));
    // First-successful-start OEM hint.
    final shouldHint =
        !(await widget.settingsStore.getBool(_kBackgroundOnboardedKey) ??
            false);
    if (shouldHint) {
      await widget.settingsStore.setBool(_kBackgroundOnboardedKey, true);
      if (!mounted) return;
      // Re-use the messenger captured at the top of the function.
      scaffold?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: const Text(
            'On Xiaomi/Oppo/Huawei phones, add MobileCode to the '
            'battery whitelist so notifications keep flowing while the '
            'screen is off.',
          ),
          action: SnackBarAction(
            label: 'How',
            onPressed: () async {
              // Opens the GitHub blob — the page is human-curated per OEM
              // (links to each vendor's own guide rather than fragile
              // copy-paste). When this repo ships its own docs site, the
              // URL just moves.
              final uri = Uri.parse(
                'https://github.com/lincyaw/openvsmobile/blob/main/'
                'docs/notifications-android.md',
              );
              try {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } on PlatformException {
                // No browser configured — drop silently rather than nest
                // another SnackBar.
              }
            },
          ),
        ),
      );
    }
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
    final permGranted = _permission.isGranted;
    final permPermanentlyDenied = _permission.isPermanentlyDenied;
    final toggleEnabled = !_saving && (permGranted || !p.backgroundEnabled
        // Allow turning ON when not granted — the toggle handler runs the
        // permission request flow and reflects the result. We only disable
        // the toggle when permanently denied AND currently off, because
        // there's no path to make it work without leaving the app.
        || !permPermanentlyDenied);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.cell_tower_outlined),
            title: const Text('Background notifications'),
            subtitle: Text(
              permPermanentlyDenied
                  ? 'Notification permission permanently denied. Enable '
                      'it in system settings before turning this on.'
                  : 'Keep an always-on connection so notifications reach '
                      'the system tray when the app is closed. Requires a '
                      'small persistent indicator in the status bar.',
              style: permPermanentlyDenied
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
            value: p.backgroundEnabled && permGranted,
            onChanged: toggleEnabled ? _onToggleBackground : null,
          ),
          if (permPermanentlyDenied)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                onPressed: openAppSettings,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open system settings'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
            child: Text(
              'On Xiaomi / Oppo / Huawei phones, also add MobileCode '
              'to the battery whitelist — same trade-off as Telegram and '
              'K-9 Mail. See docs/notifications-android.md.',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
              ),
            ),
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

