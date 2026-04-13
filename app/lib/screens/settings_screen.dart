import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _testing = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final settings = context.read<SettingsService>();
      _urlController.text = settings.serverUrl;
      _tokenController.text = settings.authToken;
      _initialized = true;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final settings = context.read<SettingsService>();
    await settings.save(
      _urlController.text.trim(),
      _tokenController.text.trim(),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved.')),
    );
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    final url = _urlController.text.trim();
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final token = _tokenController.text.trim();
    try {
      // Step 1: Hit the unauthenticated health endpoint to verify connectivity.
      final healthResponse = await http
          .get(Uri.parse('$base/api/health'))
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (healthResponse.statusCode != 200) {
        _showTestResult('Server unreachable (HTTP ${healthResponse.statusCode})', Colors.red);
        return;
      }

      // Step 2: Hit an authenticated endpoint to verify the token.
      final authResponse = await http
          .get(
            Uri.parse('$base/api/sessions'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (authResponse.statusCode == 401) {
        _showTestResult('Server reachable, but auth token is invalid (401)', Colors.orange);
        return;
      }
      final ok = authResponse.statusCode >= 200 && authResponse.statusCode < 300;
      _showTestResult(
        ok
            ? 'Connection successful'
            : 'Server responded with HTTP ${authResponse.statusCode}',
        ok ? Colors.green : Colors.orange,
      );
    } catch (e) {
      if (!mounted) return;
      _showTestResult('Connection failed: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _showTestResult(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://10.0.2.2:8080',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Server URL is required';
                }
                final uri = Uri.tryParse(v.trim());
                if (uri == null || !uri.hasScheme) {
                  return 'Enter a valid URL (e.g. http://host:port)';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Auth Token',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
              obscureText: true,
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Auth token is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: const Text('Test Connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
