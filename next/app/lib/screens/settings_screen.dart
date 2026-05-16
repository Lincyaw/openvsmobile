// Connection settings: host, port, bearer token. Two-field form, no QR.

import 'package:flutter/material.dart';

import '../settings_store.dart';

class SettingsScreen extends StatefulWidget {
  final Settings initial;
  final Future<void> Function(Settings) onSave;
  final bool isFirstRun;

  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onSave,
    this.isFirstRun = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _tokenCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _hostCtrl = TextEditingController(text: widget.initial.host);
    _portCtrl = TextEditingController(
      text: widget.initial.port == 0 ? '7860' : widget.initial.port.toString(),
    );
    _tokenCtrl = TextEditingController(text: widget.initial.token);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final s = Settings(
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      token: _tokenCtrl.text.trim(),
    );
    await widget.onSave(s);
    if (!mounted) return;
    Navigator.of(context).pop(s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFirstRun ? 'Connect to backend' : 'Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'e.g. 192.168.1.10 or 10.0.2.2',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n < 1 || n > 65535) {
                    return 'must be 1–65535';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tokenCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bearer token',
                  hintText: 'printed by the backend on first start',
                ),
                obscureText: true,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'required' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
