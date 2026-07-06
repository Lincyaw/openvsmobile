// Transport-specific backend editor. A BackendTarget has exactly one
// transport; the add flow chooses WebSocket or Iroh before this screen opens.
// Includes a "Test connection" button that attempts a handshake and prints
// diagnostic logs so users can debug network/auth issues.
//
// The actual app-wide Settings tab lives in `settings_tab.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../backend_client.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';
import '../version.dart';

class _LogEntry {
  final DateTime time;
  final String text;
  final bool isError;
  const _LogEntry({
    required this.time,
    required this.text,
    this.isError = false,
  });
}

class BackendEditorScreen extends StatefulWidget {
  final BackendTarget initial;
  final Future<void> Function(BackendTarget) onSave;
  final bool isFirstRun;

  const BackendEditorScreen({
    super.key,
    required this.initial,
    required this.onSave,
    this.isFirstRun = false,
  });

  @override
  State<BackendEditorScreen> createState() => _BackendEditorScreenState();
}

class _BackendEditorScreenState extends State<BackendEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _irohTicketCtrl;
  late final TextEditingController _irohEndpointIdCtrl;
  late final TextEditingController _irohAlpnCtrl;
  late final BackendTransport _transport;
  bool _saving = false;

  bool _testing = false;
  final List<_LogEntry> _testLogs = [];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initial.name);
    _hostCtrl = TextEditingController(text: widget.initial.host);
    _portCtrl = TextEditingController(
      text: widget.initial.port == 0
          ? '$kDefaultBackendPort'
          : widget.initial.port.toString(),
    );
    _tokenCtrl = TextEditingController(text: widget.initial.token);
    _irohTicketCtrl = TextEditingController(
      text: widget.initial.irohTicket ?? '',
    );
    _irohEndpointIdCtrl = TextEditingController(
      text: widget.initial.irohEndpointId ?? '',
    );
    _irohAlpnCtrl = TextEditingController(
      text: widget.initial.irohAlpn ?? 'openvsmobile.rpc.v1',
    );
    _transport = widget.initial.transport;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _tokenCtrl.dispose();
    _irohTicketCtrl.dispose();
    _irohEndpointIdCtrl.dispose();
    _irohAlpnCtrl.dispose();
    super.dispose();
  }

  void _log(String text, {bool isError = false}) {
    setState(() {
      _testLogs.add(
        _LogEntry(time: DateTime.now(), text: text, isError: isError),
      );
    });
  }

  Future<void> _testConnection() async {
    if (_transport == BackendTransport.iroh) {
      await _testIrohConnection();
      return;
    }
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
      await ch.ready.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('TCP connect timed out after 5s');
        },
      );
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
                _RpcError(
                  (err['code'] as num).toInt(),
                  err['message'] as String,
                ),
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

      ch.sink.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'auth.handshake',
          'params': {
            'token': token,
            'protocolVersion': '1.0',
            'client': {'name': 'openvsmobile-flutter-test', 'version': '0.1.0'},
          },
        }),
      );

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
      _log(
        '   Hint: check that host/port are correct and the backend is running.',
        isError: true,
      );
    } on _RpcError catch (e) {
      _log('   Auth failed: [${e.code}] ${e.message}', isError: true);
      if (e.code == -32002) {
        _log(
          '   Hint: token is wrong. Check backend stdout for the correct token.',
          isError: true,
        );
      }
    } on WebSocketChannelException catch (e) {
      _log('   WebSocket error: ${e.message}', isError: true);
      _log(
        '   Hint: backend may not be running, or a firewall is blocking port $port.',
        isError: true,
      );
    } catch (e) {
      _log('   Error: $e', isError: true);
    } finally {
      try {
        await ch?.sink.close();
      } catch (_) {}
      setState(() => _testing = false);
    }
  }

  Future<void> _testIrohConnection() async {
    final ticket = _irohTicketCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    final alpn = _irohAlpnCtrl.text.trim().isEmpty
        ? 'openvsmobile.rpc.v1'
        : _irohAlpnCtrl.text.trim();

    if (ticket.isEmpty || token.isEmpty) {
      _log('Please fill in Iroh ticket and bearer token first.', isError: true);
      return;
    }
    if (token.startsWith('endpoint')) {
      _log(
        'Bearer token looks like an Iroh ticket. Use the backend token here.',
        isError: true,
      );
      return;
    }

    setState(() {
      _testing = true;
      _testLogs.clear();
    });

    final client = BackendClient(
      timing: const BackendClientTiming(
        heartbeatInterval: Duration(seconds: 60),
        heartbeatGrace: Duration(seconds: 5),
        queueBudget: Duration(seconds: 5),
        backoff: [Duration(seconds: 1)],
      ),
    );
    try {
      _log('1. Opening Iroh stream...');
      client.configure(
        host: '',
        port: 0,
        token: token,
        transport: BackendTransport.iroh,
        irohTicket: ticket,
        irohAlpn: alpn,
      );
      await client.start();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (client.state.value == BackendConnectionState.connected) {
          _log('   Iroh + auth OK.');
          _log('   defaultCwd: ${client.defaultCwd}');
          _log('--- CONNECTED ---');
          return;
        }
        final err = client.lastError.value;
        if (err != null && err.isNotEmpty) {
          _log('   $err', isError: true);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      _log(
        '   TIMEOUT: Iroh connect/auth did not complete in 10s',
        isError: true,
      );
    } catch (e) {
      _log('   Error: $e', isError: true);
    } finally {
      await client.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final name = _nameCtrl.text.trim();
    final host = _transport == BackendTransport.websocket
        ? _hostCtrl.text.trim()
        : '';
    final irohEndpointId = _irohEndpointIdCtrl.text.trim();
    final defaultName = _transport == BackendTransport.websocket
        ? host
        : (irohEndpointId.isEmpty
              ? 'iroh backend'
              : 'iroh-${irohEndpointId.substring(0, irohEndpointId.length < 8 ? irohEndpointId.length : 8)}');
    final updated = widget.initial.copyWith(
      name: name.isEmpty ? defaultName : name,
      host: host,
      port: _transport == BackendTransport.websocket
          ? int.parse(_portCtrl.text.trim())
          : 0,
      token: _tokenCtrl.text.trim(),
      transport: _transport,
      irohTicket: _transport == BackendTransport.iroh
          ? _irohTicketCtrl.text.trim()
          : null,
      irohEndpointId:
          _transport == BackendTransport.iroh && irohEndpointId.isNotEmpty
          ? irohEndpointId
          : null,
      irohAlpn: _transport == BackendTransport.iroh
          ? (_irohAlpnCtrl.text.trim().isEmpty
                ? 'openvsmobile.rpc.v1'
                : _irohAlpnCtrl.text.trim())
          : null,
      clearIroh: _transport == BackendTransport.websocket,
    );
    await widget.onSave(updated);
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: Text(_screenTitle())),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg + bottomInset,
            ),
            children: [
              _TransportHeader(transport: _transport),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: _transport == BackendTransport.iroh
                      ? 'e.g. home-iroh'
                      : 'e.g. home-server',
                ),
              ),
              const SizedBox(height: 12),
              if (_transport == BackendTransport.websocket)
                ..._buildWebSocketFields()
              else
                ..._buildIrohFields(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tokenCtrl,
                decoration: InputDecoration(
                  labelText: _transport == BackendTransport.iroh
                      ? 'Bearer token (not ticket)'
                      : 'Bearer token',
                  hintText: _transport == BackendTransport.iroh
                      ? 'e.g. openvsmobile-dev'
                      : 'printed by the backend on first start',
                ),
                obscureText: true,
                validator: (v) {
                  final text = (v ?? '').trim();
                  if (text.isEmpty) return 'required';
                  if (text.startsWith('endpoint')) {
                    return 'this is an Iroh ticket; paste the bearer token';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _ActionButtons(
                testing: _testing,
                saving: _saving,
                onTest: _testConnection,
                onSave: _submit,
              ),
              if (_testLogs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Connection test log',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(height: 220, child: _TestLogPanel(logs: _testLogs)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _screenTitle() {
    final transportName = switch (_transport) {
      BackendTransport.websocket => 'WebSocket',
      BackendTransport.iroh => 'Iroh',
    };
    return widget.isFirstRun
        ? 'New $transportName backend'
        : 'Edit $transportName backend';
  }

  List<Widget> _buildWebSocketFields() => [
    TextFormField(
      controller: _hostCtrl,
      decoration: const InputDecoration(
        labelText: 'Host',
        hintText: 'e.g. 192.168.1.10 or 10.0.2.2',
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? 'required' : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _portCtrl,
      decoration: const InputDecoration(labelText: 'Port'),
      keyboardType: TextInputType.number,
      validator: (v) {
        final n = int.tryParse((v ?? '').trim());
        if (n == null || n < 1 || n > 65535) {
          return 'must be 1-65535';
        }
        return null;
      },
    ),
  ];

  List<Widget> _buildIrohFields() => [
    TextFormField(
      controller: _irohTicketCtrl,
      decoration: const InputDecoration(
        labelText: 'Iroh ticket',
        hintText: 'endpoint...',
      ),
      minLines: 2,
      maxLines: 5,
      validator: (v) => (v == null || v.trim().isEmpty) ? 'required' : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _irohEndpointIdCtrl,
      decoration: const InputDecoration(
        labelText: 'Endpoint ID',
        hintText: 'optional',
      ),
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _irohAlpnCtrl,
      decoration: const InputDecoration(labelText: 'ALPN'),
      validator: (v) => (v == null || v.trim().isEmpty) ? 'required' : null,
    ),
  ];
}

class _TransportHeader extends StatelessWidget {
  final BackendTransport transport;

  const _TransportHeader({required this.transport});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = switch (transport) {
      BackendTransport.websocket => (Icons.dns_outlined, 'WebSocket'),
      BackendTransport.iroh => (Icons.hub_outlined, 'Iroh ticket'),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transport',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(label, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final bool testing;
  final bool saving;
  final VoidCallback onTest;
  final VoidCallback onSave;

  const _ActionButtons({
    required this.testing,
    required this.saving,
    required this.onTest,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final testButton = OutlinedButton.icon(
      onPressed: testing ? null : onTest,
      icon: testing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.network_ping, size: 18),
      label: Text(testing ? 'Testing...' : 'Test connection'),
    );
    final saveButton = FilledButton(
      onPressed: saving ? null : onSave,
      child: Text(saving ? 'Saving...' : 'Save'),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [testButton, const SizedBox(height: 8), saveButton],
          );
        }
        return Row(
          children: [
            Expanded(child: testButton),
            const SizedBox(width: 12),
            Expanded(child: saveButton),
          ],
        );
      },
    );
  }
}

class _TestLogPanel extends StatelessWidget {
  final List<_LogEntry> logs;

  const _TestLogPanel({required this.logs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: ListView.builder(
        itemCount: logs.length,
        itemBuilder: (ctx, i) {
          final log = logs[i];
          return SelectableText(
            '[${log.time.hour.toString().padLeft(2, '0')}:'
            '${log.time.minute.toString().padLeft(2, '0')}:'
            '${log.time.second.toString().padLeft(2, '0')}] ${log.text}',
            style: AppText.monoCaption(context).copyWith(
              color: log.isError ? Theme.of(context).colorScheme.error : null,
            ),
          );
        },
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
