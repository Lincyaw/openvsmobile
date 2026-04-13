import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
  final _settings = SettingsService();
  bool _loading = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _settings.load();
    _urlController.text = _settings.serverUrl;
    _tokenController.text = _settings.authToken;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    await _settings.save(
      _urlController.text.trim(),
      _tokenController.text.trim(),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Settings saved. Restart the app for changes to take effect.',
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    final url = _urlController.text.trim();
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer ${_tokenController.text.trim()}',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Connection successful (HTTP ${response.statusCode})'
                : 'Server responded with HTTP ${response.statusCode}',
          ),
          backgroundColor: ok ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
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
