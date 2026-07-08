// System-tray diagnostics screen — lets a user without adb access
// self-diagnose why `notification.show` pushes never land in the system tray.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diag_log.dart';
import '../services/system_tray.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';

class SystemTrayDebugScreen extends StatefulWidget {
  final SystemTrayController controller;
  final SettingsStore settingsStore;

  const SystemTrayDebugScreen({
    super.key,
    required this.controller,
    required this.settingsStore,
  });

  @override
  State<SystemTrayDebugScreen> createState() => _SystemTrayDebugScreenState();
}

class _SystemTrayDebugScreenState extends State<SystemTrayDebugScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.lastError.addListener(_onChanged);
    widget.controller.lastShowAt.addListener(_onChanged);
    widget.controller.lastShowResult.addListener(_onChanged);
    widget.controller.logs.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.lastError.removeListener(_onChanged);
    widget.controller.lastShowAt.removeListener(_onChanged);
    widget.controller.lastShowResult.removeListener(_onChanged);
    widget.controller.logs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Re-initialize',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await c.reinit();
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Re-init requested')),
              );
            },
          ),
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(
                ClipboardData(text: c.logs.value.join('\n')),
              );
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Logs copied')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          _Section('State', [
            _kv('Initialized', c.isInitialized ? 'yes' : 'no'),
            _kv(
              'Last error',
              c.lastError.value ?? '—',
              error: c.lastError.value,
            ),
            _kv('Last show at', _fmtTime(c.lastShowAt.value)),
            _kv('Last show result', c.lastShowResult.value ?? '—'),
            _kv('Icon', c.currentIcon),
          ]),
          const Divider(),
          _Section('Actions', const []),
          ListTile(
            leading: const Icon(Icons.send),
            title: const Text('Send test notification'),
            subtitle: const Text('Posts a fake error-level notification'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              await c.testShow();
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Test posted')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Try app-icon fallback'),
            subtitle: const Text(
              'Switch small icon to @mipmap/ic_launcher — '
              'use if MIUI is rejecting the vector drawable',
            ),
            onTap: () {
              c.useFallbackIcon();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Switched to launcher icon — send a test'),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reset to default icon'),
            subtitle: const Text('Back to ic_notification'),
            onTap: () {
              c.resetIcon();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Icon reset')));
            },
          ),
          const Divider(),
          _Section('Trace', [
            _DebugOverlayToggle(settingsStore: widget.settingsStore),
          ]),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (c.logs.value.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text('No activity yet. Send a test notification.'),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.xs,
              ),
              child: SelectableText(
                c.logs.value.reversed.join('\n'),
                style: AppText.monoCaption(context),
              ),
            ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime? t) =>
      t == null ? '—' : t.toLocal().toIso8601String().substring(11, 19);

  Widget _kv(String label, String value, {String? error}) {
    final isError = error != null && error.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isError ? Theme.of(context).colorScheme.error : null,
                fontFamily: value.contains(':') ? null : 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DebugOverlayToggle extends StatefulWidget {
  final SettingsStore settingsStore;

  const _DebugOverlayToggle({required this.settingsStore});

  @override
  State<_DebugOverlayToggle> createState() => _DebugOverlayToggleState();
}

class _DebugOverlayToggleState extends State<_DebugOverlayToggle> {
  Future<void> _set(bool value) async {
    setState(() => DiagLog.instance.enabled = value);
    await widget.settingsStore.setBool(kDiagLogPrefKey, value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: const ValueKey<String>('diagnostics-debug-overlay'),
      secondary: const Icon(Icons.bug_report_outlined),
      title: const Text('Debug overlay'),
      subtitle: const Text('Floating event log for connection debugging'),
      value: DiagLog.instance.enabled,
      onChanged: _set,
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ...children,
      ],
    );
  }
}
