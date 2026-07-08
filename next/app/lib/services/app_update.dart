// In-app self-update service: checks GitHub Releases for a newer version,
// downloads the matching APK, and triggers install via a platform channel.
//
// Follows the same sealed-class event stream pattern as ssh_bootstrap.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../version.dart';

// ---------------------------------------------------------------------------
// Event hierarchy
// ---------------------------------------------------------------------------

sealed class UpdateEvent {
  const UpdateEvent();
}

class UpdateChecking extends UpdateEvent {
  const UpdateChecking();
}

class UpdateNotAvailable extends UpdateEvent {
  const UpdateNotAvailable();
}

class UpdateAvailable extends UpdateEvent {
  final String tagName;
  final String releaseName;
  final String body;
  final String downloadUrl;
  final int assetSize;
  const UpdateAvailable({
    required this.tagName,
    required this.releaseName,
    required this.body,
    required this.downloadUrl,
    required this.assetSize,
  });
}

class UpdateDownloadProgress extends UpdateEvent {
  final int received;
  final int total;
  const UpdateDownloadProgress({required this.received, required this.total});
}

class UpdateDownloadComplete extends UpdateEvent {
  final String filePath;
  const UpdateDownloadComplete({required this.filePath});
}

class UpdateError extends UpdateEvent {
  final String message;
  const UpdateError(this.message);
}

// ---------------------------------------------------------------------------
// Release info (parsed from GitHub API)
// ---------------------------------------------------------------------------

class ReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

class ReleaseInfo {
  final String tagName;
  final String name;
  final String body;
  final List<ReleaseAsset> assets;
  const ReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.assets,
  });
}

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------

/// Strip any pre-release suffix (e.g. "0.4.0-rc.1" → "0.4.0").
String _stripPreRelease(String version) {
  final idx = version.indexOf('-');
  return idx < 0 ? version : version.substring(0, idx);
}

/// Returns true when [remote] is strictly newer than [local].
/// Pre-release suffixes are stripped before comparison.
bool isNewerVersion(String remote, String local) {
  final rParts = _stripPreRelease(remote).split('.').map(int.tryParse).toList();
  final lParts = _stripPreRelease(local).split('.').map(int.tryParse).toList();
  for (var i = 0; i < 3; i++) {
    final r = (i < rParts.length ? rParts[i] : null) ?? 0;
    final l = (i < lParts.length ? lParts[i] : null) ?? 0;
    if (r > l) return true;
    if (r < l) return false;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class AppUpdateService {
  static const _channel = MethodChannel('dev.lincyaw.mobilecode/updater');
  static const _apiUrl =
      'https://api.github.com/repos/Lincyaw/openvsmobile/releases/latest';

  /// Ask the native side for the device's primary ABI string.
  Future<String> getDeviceAbi() async {
    final abi = await _channel.invokeMethod<String>('getDeviceAbi');
    return abi ?? 'universal';
  }

  /// Trigger the system package installer for the APK at [path].
  Future<void> installApk(String path) async {
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }

  /// Get the app's private cache directory (matches FileProvider's cache-path).
  Future<String> _getCacheDir() async {
    final dir = await _channel.invokeMethod<String>('getCacheDir');
    return dir ?? Directory.systemTemp.path;
  }

  /// Fetch the latest release metadata from GitHub.
  Future<ReleaseInfo> fetchLatestRelease() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_apiUrl));
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('GitHub API returned ${response.statusCode}: $body');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final assets = (json['assets'] as List<dynamic>)
          .map(
            (a) => ReleaseAsset(
              name: a['name'] as String,
              downloadUrl: a['browser_download_url'] as String,
              size: (a['size'] as num).toInt(),
            ),
          )
          .toList();
      return ReleaseInfo(
        tagName: json['tag_name'] as String,
        name: (json['name'] as String?) ?? json['tag_name'] as String,
        body: (json['body'] as String?) ?? '',
        assets: assets,
      );
    } finally {
      client.close();
    }
  }

  /// Pick the best APK asset for the current device. Falls back to
  /// `universal` if no ABI-specific asset is found.
  ReleaseAsset? pickAsset(ReleaseInfo release, String abi) {
    // Asset names follow: openvsmobile-app-v<ver>-<abi>.apk
    ReleaseAsset? abiMatch;
    ReleaseAsset? universalMatch;
    for (final a in release.assets) {
      if (!a.name.endsWith('.apk')) continue;
      if (a.name.contains(abi)) {
        abiMatch = a;
      } else if (a.name.contains('universal')) {
        universalMatch = a;
      }
    }
    return abiMatch ?? universalMatch;
  }

  /// Stream that checks for updates, downloads the APK, and reports
  /// progress. The caller drives the UI from these events.
  Stream<UpdateEvent> checkAndDownload() async* {
    yield const UpdateChecking();

    late final ReleaseInfo release;
    try {
      release = await fetchLatestRelease();
    } catch (e) {
      yield UpdateError('Failed to check for updates: $e');
      return;
    }

    final remoteVersion = release.tagName.replaceFirst(RegExp(r'^v'), '');
    if (!isNewerVersion(remoteVersion, kBackendVersion)) {
      yield const UpdateNotAvailable();
      return;
    }

    late final String abi;
    try {
      abi = await getDeviceAbi();
    } catch (e) {
      abi = 'universal';
    }

    final asset = pickAsset(release, abi);
    if (asset == null) {
      yield UpdateError(
        'No APK asset found for ABI "$abi" in release ${release.tagName}.',
      );
      return;
    }

    yield UpdateAvailable(
      tagName: release.tagName,
      releaseName: release.name,
      body: release.body,
      downloadUrl: asset.downloadUrl,
      assetSize: asset.size,
    );
  }

  /// Delete stale `mobilecode-update-*.apk` files from [dir].
  Future<void> _cleanOldApks(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    await for (final entity in dir.list()) {
      if (entity is File &&
          entity.path.contains('mobilecode-update-') &&
          entity.path.endsWith('.apk')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  /// Download the APK from [url] to the app's cache dir, yielding progress
  /// events. Returns the file path on success (via [UpdateDownloadComplete]).
  Stream<UpdateEvent> download(String url, int totalSize) async* {
    final client = HttpClient();
    try {
      final cachePath = await _getCacheDir();
      await _cleanOldApks(cachePath);

      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        yield UpdateError(
          'Download failed with status ${response.statusCode}.',
        );
        return;
      }

      final fileName =
          'mobilecode-update-${DateTime.now().millisecondsSinceEpoch}.apk';
      final file = File('$cachePath/$fileName');
      final sink = file.openWrite();

      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          yield UpdateDownloadProgress(received: received, total: totalSize);
        }
      } finally {
        await sink.close();
      }

      yield UpdateDownloadComplete(filePath: file.path);
    } catch (e) {
      yield UpdateError('Download error: $e');
    } finally {
      client.close();
    }
  }
}
