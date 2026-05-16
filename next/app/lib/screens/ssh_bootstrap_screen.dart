// SSH-bootstrap UI: collect credentials, stream install.sh, surface stderr
// live, hand the parsed {host, port, token} off to the settings store.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ssh_bootstrap.dart';
import '../settings_store.dart';

enum _AuthMode { password, key }

class SshBootstrapScreen extends StatefulWidget {
  final Future<void> Function(Settings) onSettingsSaved;
  const SshBootstrapScreen({super.key, required this.onSettingsSaved});

  @override
  State<SshBootstrapScreen> createState() => _SshBootstrapScreenState();
}

class _SshBootstrapScreenState extends State<SshBootstrapScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  final _tarballCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  _AuthMode _authMode = _AuthMode.password;
  bool _showAdvanced = false;
  bool _running = false;
  String _status = '';
  final List<String> _log = [];
  BootstrapSuccess? _success;
  BootstrapFailure? _failure;
  StreamSubscription<BootstrapEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    _tarballCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _running = true;
      _log.clear();
      _status = 'Starting…';
      _success = null;
      _failure = null;
    });

    final auth = _authMode == _AuthMode.password
        ? SshPasswordAuth(_passwordCtrl.text)
        : SshKeyAuth(
            privateKeyPem: _keyCtrl.text,
            passphrase:
                _passphraseCtrl.text.isEmpty ? null : _passphraseCtrl.text,
          );

    final stream = SshBootstrapService().run(
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text.trim(),
      auth: auth,
      tarballPath: _tarballCtrl.text.trim().isEmpty
          ? null
          : _tarballCtrl.text.trim(),
    );

    _sub = stream.listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case BootstrapStatus(:final message):
            _status = message;
          case BootstrapLog(:final line):
            _log.add(line);
          case BootstrapSuccess():
            _success = event;
            _status = 'Success';
            _running = false;
          case BootstrapFailure():
            _failure = event;
            _status = 'Failed';
            _running = false;
        }
      });
      _autoScroll();
    }, onDone: () {
      if (!mounted) return;
      setState(() => _running = false);
    });
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _saveAndSwitch() async {
    final s = _success!;
    final settings = Settings(
      host: _hostCtrl.text.trim(),
      port: s.port,
      token: s.token,
    );
    await widget.onSettingsSaved(settings);
    if (!mounted) return;
    Navigator.of(context).pop(settings);
  }

  void _copyLog() {
    final lines = [
      'Status: $_status',
      if (_failure != null) 'Exit code: ${_failure!.exitCode}',
      if (_failure != null) 'Reason: ${_failure!.reason}',
      '',
      ..._log,
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Install backend via SSH')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _credentialFields(),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.cloud_download),
                label: Text(_running ? 'Working…' : 'Install and connect'),
              ),
              const SizedBox(height: 16),
              if (_status.isNotEmpty || _log.isNotEmpty) _progressBlock(),
              if (_success != null) ...[
                const SizedBox(height: 16),
                _successCard(),
              ],
              if (_failure != null) ...[
                const SizedBox(height: 16),
                _failureCard(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _credentialFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _hostCtrl,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: 'Host',
            hintText: 'e.g. 192.168.1.10',
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'required' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _portCtrl,
          enabled: !_running,
          decoration: const InputDecoration(labelText: 'Port'),
          keyboardType: TextInputType.number,
          validator: (v) {
            final n = int.tryParse((v ?? '').trim());
            if (n == null || n < 1 || n > 65535) return 'must be 1–65535';
            return null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _userCtrl,
          enabled: !_running,
          decoration: const InputDecoration(labelText: 'Username'),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'required' : null,
        ),
        const SizedBox(height: 12),
        SegmentedButton<_AuthMode>(
          segments: const [
            ButtonSegment(value: _AuthMode.password, label: Text('Password')),
            ButtonSegment(value: _AuthMode.key, label: Text('Private key')),
          ],
          selected: {_authMode},
          onSelectionChanged: _running
              ? null
              : (s) => setState(() => _authMode = s.first),
        ),
        const SizedBox(height: 12),
        if (_authMode == _AuthMode.password)
          TextFormField(
            controller: _passwordCtrl,
            enabled: !_running,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            validator: (v) {
              if (_authMode == _AuthMode.password &&
                  (v == null || v.isEmpty)) {
                return 'required';
              }
              return null;
            },
          )
        else ...[
          TextFormField(
            controller: _keyCtrl,
            enabled: !_running,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Private key (OpenSSH PEM)',
              hintText:
                  '-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----',
              alignLabelWithHint: true,
            ),
            validator: (v) {
              if (_authMode == _AuthMode.key &&
                  (v == null || v.trim().isEmpty)) {
                return 'required';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passphraseCtrl,
            enabled: !_running,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passphrase (optional)',
            ),
          ),
        ],
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced'),
          initiallyExpanded: _showAdvanced,
          onExpansionChanged: (v) => setState(() => _showAdvanced = v),
          children: [
            TextFormField(
              controller: _tarballCtrl,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: 'Tarball path on remote (optional)',
                hintText:
                    '/home/you/openvsmobile-backend-linux-x64.tar.gz',
                helperText:
                    'If set, install.sh skips the GitHub download and uses this local file.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _progressBlock() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_running) const SizedBox(width: 8),
                Expanded(
                  child: Text(_status,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  child: SelectableText(
                    _log.isEmpty ? '(no output yet)' : _log.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _successCard() {
    final s = _success!;
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Backend ${s.version} is running on port ${s.port}.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (!s.linger)
              const Text(
                'Note: user lingering is disabled — the service stops when '
                'the user logs out. Enable with `loginctl enable-linger`.',
                style: TextStyle(fontSize: 12),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              onPressed: _saveAndSwitch,
              label: const Text('Save and switch'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failureCard() {
    final f = _failure!;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              f.exitCode == null
                  ? 'Bootstrap failed'
                  : 'Bootstrap failed (exit ${f.exitCode})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(f.reason),
            if (f.lastStderr.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Last stderr:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  f.lastStderr.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _running ? null : _start,
                  child: const Text('Try again'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _copyLog,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy log'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
