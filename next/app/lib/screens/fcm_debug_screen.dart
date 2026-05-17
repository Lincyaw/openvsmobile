// FCM diagnostics screen — surfaced from the More tab. Lets a user
// without adb access read what the FCM transport is doing on their
// device. The screen is a thin view over `FcmDiagnostics.instance`;
// all state mutation happens inside `services/fcm_service.dart`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/fcm_diagnostics.dart';
import '../services/fcm_service.dart';

class FcmDebugScreen extends StatefulWidget {
  final FcmController controller;
  const FcmDebugScreen({super.key, required this.controller});

  @override
  State<FcmDebugScreen> createState() => _FcmDebugScreenState();
}

class _FcmDebugScreenState extends State<FcmDebugScreen> {
  @override
  void initState() {
    super.initState();
    FcmDiagnostics.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    FcmDiagnostics.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final d = FcmDiagnostics.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FCM diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Re-register token now',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await widget.controller.registerWithBackend();
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Re-register requested')),
              );
            },
          ),
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final text = d.log.join('\n');
              await Clipboard.setData(ClipboardData(text: text));
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Section('State', [
            _kv('Firebase.initializeApp',
                _ynOrNull(d.firebaseInitOk), error: d.firebaseInitError),
            _kv('FcmController.init',
                _ynOrNull(d.controllerInitOk), error: d.controllerInitError),
            _kv('Permission', d.permissionStatus ?? '—'),
            _kv('Last token',
                d.lastTokenPrefix ?? (d.lastTokenError ?? '—'),
                error: d.lastTokenError),
            _kv('Last token at', _fmtTime(d.lastTokenAt)),
            _kv('Last register', d.lastRegisterStatus ?? '—'),
            _kv('Last register at', _fmtTime(d.lastRegisterAt)),
          ]),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (d.log.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No FCM activity recorded yet. Reopen the app after a '
                'fresh install, or tap the refresh icon above.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SelectableText(
                d.log.reversed.join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _ynOrNull(bool? v) => v == null ? '—' : (v ? 'ok' : 'FAILED');
  String _fmtTime(DateTime? t) =>
      t == null ? '—' : t.toLocal().toIso8601String().substring(11, 19);

  Widget _kv(String label, String value, {String? error}) {
    final isError = error != null && error.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isError ? Colors.red : null,
                fontFamily: value.contains(':') ? null : 'monospace',
              ),
            ),
          ),
        ],
      ),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(title,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        ...children,
      ],
    );
  }
}
