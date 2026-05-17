// Connection settings: host, port, bearer token. Two-field form, no QR.
// Includes a "Test connection" button that attempts a WebSocket handshake
// and prints diagnostic logs so users can debug network issues.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../settings_store.dart';

class _LogEntry {
  final DateTime time;
  final String text;
  final bool isError;
  const _LogEntry({required this.time, required this.text, this.isError = false});
}

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

  bool _testing = false;
  final List<_LogEntry> _testLogs = [];

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

  void _log(String text, {bool isError = false}) {
    setState(() {
      _testLogs.add(_LogEntry(time: DateTime.now(), text: text, isError: isError));
    });
  }

  Future<void> _testConnection() async {
    final host = _hostCtrl.text.trim();
    final portText = _portCtrl.text.trim();
    final token = _tokenCtrl.text.trim();

    if (host.isEmpty || portText.isEmpty || token.isEmpty) {
      _log('Please fill in host, port and token first.', isError: true);
      return;
    }

    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      _log('Invalid port: $portText', isError: true);
      return;
    }

    setState(() {
      _testing = true;
      _testLogs.clear();
    });

    WebSocketChannel? ch;
    try {
      _log('1. Resolving host "$host"...');
      final addresses = await InternetAddress.lookup(host);
      if (addresses.isEmpty) {
        _log('   DNS lookup returned no addresses.', isError: true);
        setState(() => _testing = false);
        return;
      }
      _log('   Resolved to: ${addresses.map((a) => a.address).join(', ')}');

      final uri = Uri.parse('ws://$host:$port/rpc');
      _log('2. Opening WebSocket to $uri ...');
      ch = WebSocketChannel.connect(uri);
      await ch.ready.timeout(const Duration(seconds: 5), onTimeout: () {
        throw TimeoutException('TCP connect timed out after 5s');
      });
      _log('   TCP + WS handshake OK.');

      _log('3. Sending auth.handshake...');
      final completer = Completer<Map<String, dynamic>>();
      late final StreamSubscription sub;
      sub = ch.stream.listen(
        (raw) {
          final text = raw is String ? raw : utf8.decode(raw as List<int>);
          final decoded = jsonDecode(text) as Map<String, dynamic>;
          if (decoded.containsKey('id')) {
            sub.cancel();
            if (decoded.containsKey('error')) {
              final err = decoded['error'] as Map<String, dynamic>;
              completer.completeError(
                _RpcError((err['code'] as num).toInt(), err['message'] as String),
              );
            } else {
              completer.complete(decoded['result'] as Map<String, dynamic>);
            }
          }
        },
        onError: (Object e) {
          sub.cancel();
          completer.completeError(e);
        },
        cancelOnError: true,
      );

      ch.sink.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'auth.handshake',
        'params': {
          'token': token,
          'protocolVersion': '1.0',
          'client': {'name': 'openvsmobile-flutter-test', 'version': '0.1.0'},
        },
      }));

      final result = await completer.future.timeout(const Duration(seconds: 5));
      if (result['ok'] == true) {
        _log('   Auth OK! Server version: ${result['serverVersion']}');
        _log('   defaultCwd: ${result['defaultCwd']}');
        _log('--- CONNECTED ---');
      } else {
        _log('   Auth rejected (ok != true)', isError: true);
      }
    } on TimeoutException catch (e) {
      _log('   TIMEOUT: $e', isError: true);
      _log('   Hint: check that host/port are correct and the backend is running.', isError: true);
    } on _RpcError catch (e) {
      _log('   Auth failed: [${e.code}] ${e.message}', isError: true);
      if (e.code == -32002) {
        _log('   Hint: token is wrong. Check backend stdout for the correct token.', isError: true);
      }
    } on WebSocketChannelException catch (e) {
      _log('   WebSocket error: ${e.message}', isError: true);
      _log('   Hint: backend may not be running, or a firewall is blocking port $port.', isError: true);
    } catch (e) {
      _log('   Error: $e', isError: true);
    } finally {
      try {
        await ch?.sink.close();
      } catch (_) {}
      setState(() => _testing = false);
    }
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
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _testConnection,
                      icon: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_ping, size: 18),
                      label: Text(_testing ? 'Testing…' : 'Test connection'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _submit,
                      child: Text(_saving ? 'Saving…' : 'Save'),
                    ),
                  ),
                ],
              ),
              if (_testLogs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Text('Connection test log',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: _testLogs.length,
                      itemBuilder: (ctx, i) {
                        final log = _testLogs[i];
                        return SelectableText(
                          '[${log.time.hour.toString().padLeft(2, '0')}:''${log.time.minute.toString().padLeft(2, '0')}:''${log.time.second.toString().padLeft(2, '0')}] ${log.text}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: log.isError
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RpcError implements Exception {
  final int code;
  final String message;
  _RpcError(this.code, this.message);
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => 'TimeoutException: $message';
}
