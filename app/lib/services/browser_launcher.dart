import 'package:flutter/services.dart';

class BrowserLauncher {
  static const MethodChannel _channel = MethodChannel(
    'vscode_mobile/browser_launcher',
  );

  Future<bool> openUrl(String url) async {
    final normalizedUrl = url.trim();
    if (normalizedUrl.isEmpty) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('openUrl', {
        'url': normalizedUrl,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
