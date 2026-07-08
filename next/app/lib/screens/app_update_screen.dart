// App update screen: check for new releases on GitHub, download the APK,
// and trigger the system package installer. Reachable from the System
// section of Settings.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update.dart';
import '../ui/app_tokens.dart';
import '../version.dart';

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

enum _Phase { idle, checking, available, downloading, downloaded, error }

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  final _service = AppUpdateService();

  _Phase _phase = _Phase.idle;
  String _error = '';

  // Release metadata (populated when update is available).
  String _tagName = '';
  String _releaseName = '';
  String _releaseBody = '';
  String _downloadUrl = '';
  int _assetSize = 0;

  // Download progress.
  int _received = 0;
  int _total = 0;

  // Path to the downloaded APK.
  String _apkPath = '';

  StreamSubscription<UpdateEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _checkForUpdates() {
    _sub?.cancel();
    setState(() {
      _phase = _Phase.checking;
      _error = '';
    });
    _sub = _service.checkAndDownload().listen(_onEvent, onDone: _onDone);
  }

  void _startDownload() {
    _sub?.cancel();
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = _assetSize;
      _error = '';
    });
    _sub = _service
        .download(_downloadUrl, _assetSize)
        .listen(_onEvent, onDone: _onDone);
  }

  void _onEvent(UpdateEvent event) {
    if (!mounted) return;
    switch (event) {
      case UpdateChecking():
        setState(() => _phase = _Phase.checking);
      case UpdateNotAvailable():
        setState(() => _phase = _Phase.idle);
        _showSnackBar('You are on the latest version.');
      case UpdateAvailable(
        :final tagName,
        :final releaseName,
        :final body,
        :final downloadUrl,
        :final assetSize,
      ):
        setState(() {
          _phase = _Phase.available;
          _tagName = tagName;
          _releaseName = releaseName;
          _releaseBody = body;
          _downloadUrl = downloadUrl;
          _assetSize = assetSize;
        });
      case UpdateDownloadProgress(:final received, :final total):
        setState(() {
          _received = received;
          _total = total;
        });
      case UpdateDownloadComplete(:final filePath):
        setState(() {
          _phase = _Phase.downloaded;
          _apkPath = filePath;
        });
      case UpdateError(:final message):
        setState(() {
          _phase = _Phase.error;
          _error = message;
        });
    }
  }

  void _onDone() {
    // Stream ended normally — if we're still in checking phase and no
    // events arrived that changed it, treat as no-update-found.
  }

  Future<void> _install() async {
    try {
      await _service.installApk(_apkPath);
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Install failed: $e. Opening release page instead.');
      _openReleasePage();
    }
  }

  void _openReleasePage() {
    final url =
        'https://github.com/Lincyaw/openvsmobile/releases/tag/$_tagName';
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _showSnackBar(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('App update')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _versionHeader(theme),
          const SizedBox(height: AppSpacing.xl),
          _actionArea(theme),
        ],
      ),
    );
  }

  Widget _versionHeader(ThemeData theme) {
    return Column(
      children: [
        Icon(
          Icons.system_update_outlined,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: AppSpacing.md),
        Text('MobileCode', style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Current version: $kBackendVersion',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _actionArea(ThemeData theme) {
    return switch (_phase) {
      _Phase.idle => _idleContent(),
      _Phase.checking => _checkingContent(),
      _Phase.available => _availableContent(theme),
      _Phase.downloading => _downloadingContent(theme),
      _Phase.downloaded => _downloadedContent(theme),
      _Phase.error => _errorContent(theme),
    };
  }

  Widget _idleContent() {
    return Center(
      child: FilledButton.icon(
        onPressed: _checkForUpdates,
        icon: const Icon(Icons.refresh),
        label: const Text('Check for updates'),
      ),
    );
  }

  Widget _checkingContent() {
    return const Center(
      child: Column(
        children: [
          SizedBox(
            width: kSpinnerSm,
            height: kSpinnerSm,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(height: AppSpacing.md),
          Text('Checking for updates...'),
        ],
      ),
    );
  }

  Widget _availableContent(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.new_releases_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(_releaseName, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _tagName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_releaseBody.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _releaseBody,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Size: ${_formatBytes(_assetSize)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadingContent(ThemeData theme) {
    final progress = _total > 0 ? _received / _total : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Downloading $_tagName...',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${_formatBytes(_received)} / ${_formatBytes(_total)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.end,
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadedContent(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Download complete', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '$_tagName is ready to install.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _install,
              icon: const Icon(Icons.install_mobile),
              label: const Text('Install'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: _openReleasePage,
              child: const Text('Open release page'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorContent(ThemeData theme) {
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Update failed', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            SelectableText(_error, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _checkForUpdates,
                  child: const Text('Retry'),
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(
                      'https://github.com/Lincyaw/openvsmobile/releases/latest',
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Open release page'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
