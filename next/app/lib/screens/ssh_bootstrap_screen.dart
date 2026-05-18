// SSH-bootstrap UI: collect credentials, stream install.sh, surface stderr
// live, hand the parsed {host, port, token} off to the settings store.
//
// The final BootstrapSuccess/BootstrapFailure is stored on AppState so it
// survives a screen rebuild — see docs/conventions.md §2 (Single source of
// truth). The streaming status + log lines remain widget-local because they
// are mid-execution UI state attached to one specific install run.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/ssh_bootstrap.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';

enum _AuthMode { password, key }

class SshBootstrapScreen extends StatefulWidget {
  final AppState appState;

  /// Called when the user accepts a successful bootstrap result. The
  /// caller persists the new [BackendTarget] (typically by appending it to
  /// the backends list and making it active).
  final Future<void> Function(BackendTarget) onBackendInstalled;
  const SshBootstrapScreen({
    super.key,
    required this.appState,
    required this.onBackendInstalled,
  });

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
  StreamSubscription<BootstrapEvent>? _sub;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.appState.removeListener(_onAppStateChanged);
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

  void _onAppStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _running = true;
      _log.clear();
      _status = 'Starting…';
    });
    widget.appState.setBootstrapResult();

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
      switch (event) {
        case BootstrapStatus(:final message):
          setState(() => _status = message);
        case BootstrapLog(:final line):
          setState(() => _log.add(line));
        case BootstrapSuccess():
          widget.appState.setBootstrapResult(success: event);
          setState(() {
            _status = 'Success';
            _running = false;
          });
        case BootstrapFailure():
          widget.appState.setBootstrapResult(failure: event);
          setState(() {
            _status = 'Failed';
            _running = false;
          });
      }
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
    final s = widget.appState.lastBootstrapSuccess;
    if (s == null) return;
    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final target = BackendTarget(
      id: generateUuidV4(),
      name: user.isEmpty ? host : '$user@$host',
      host: host,
      port: s.port,
      token: s.token,
      origin: BackendOrigin.sshInstall,
      originRef: user.isEmpty ? host : '$user@$host',
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final navigator = Navigator.of(context);
    await widget.onBackendInstalled(target);
    if (!mounted) return;
    navigator.pop(target);
  }

  void _copyLog() {
    final failure = widget.appState.lastBootstrapFailure;
    final lines = [
      'Status: $_status',
      if (failure != null) 'Exit code: ${failure.exitCode}',
      if (failure != null) 'Reason: ${failure.reason}',
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
    final success = widget.appState.lastBootstrapSuccess;
    final failure = widget.appState.lastBootstrapFailure;
    return Scaffold(
      appBar: AppBar(title: const Text('Install backend via SSH')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _credentialFields(),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.cloud_download),
                label: Text(_running ? 'Working…' : 'Install and connect'),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_status.isNotEmpty || _log.isNotEmpty) _progressBlock(),
              if (success != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _successCard(success),
              ],
              if (failure != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _failureCard(failure),
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
        const SizedBox(height: AppSpacing.md),
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
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _userCtrl,
          enabled: !_running,
          decoration: const InputDecoration(labelText: 'Username'),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'required' : null,
        ),
        const SizedBox(height: AppSpacing.md),
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
        const SizedBox(height: AppSpacing.md),
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
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: _passphraseCtrl,
            enabled: !_running,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passphrase (optional)',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
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
        padding: const EdgeInsets.all(AppSpacing.md),
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
                if (_running) const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(_status,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(AppSpacing.sm),
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

  Widget _successCard(BootstrapSuccess s) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Backend ${s.version} is running on port ${s.port}.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            if (!s.linger)
              const Text(
                'Note: user lingering is disabled — the service stops when '
                'the user logs out. Enable with `loginctl enable-linger`.',
                style: TextStyle(fontSize: 12),
              ),
            const SizedBox(height: AppSpacing.md),
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

  Widget _failureCard(BootstrapFailure f) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              f.exitCode == null
                  ? 'Bootstrap failed'
                  : 'Bootstrap failed (exit ${f.exitCode})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(f.reason),
            if (f.lastStderr.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              const Text('Last stderr:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: AppSpacing.xs),
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: SelectableText(
                  f.lastStderr.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _running ? null : _start,
                  child: const Text('Try again'),
                ),
                const SizedBox(width: AppSpacing.sm),
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
