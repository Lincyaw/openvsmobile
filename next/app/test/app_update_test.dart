import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/services/app_update.dart';

void main() {
  group('isNewerVersion', () {
    test('higher major version is newer', () {
      expect(isNewerVersion('2.0.0', '1.0.0'), isTrue);
    });

    test('higher minor version is newer', () {
      expect(isNewerVersion('0.4.0', '0.3.1'), isTrue);
    });

    test('higher patch version is newer', () {
      expect(isNewerVersion('0.3.2', '0.3.1'), isTrue);
    });

    test('same version is not newer', () {
      expect(isNewerVersion('0.3.1', '0.3.1'), isFalse);
    });

    test('lower version is not newer', () {
      expect(isNewerVersion('0.2.9', '0.3.1'), isFalse);
    });

    test('lower major is not newer despite higher minor', () {
      expect(isNewerVersion('0.99.0', '1.0.0'), isFalse);
    });

    test('strips pre-release suffix before comparing', () {
      expect(isNewerVersion('0.4.0-rc.1', '0.3.1'), isTrue);
    });

    test('pre-release of same version is not newer', () {
      expect(isNewerVersion('0.3.1-beta', '0.3.1'), isFalse);
    });

    test('handles two-segment version gracefully', () {
      expect(isNewerVersion('1.0', '0.3.1'), isTrue);
    });

    test('handles non-numeric segments without crashing', () {
      expect(isNewerVersion('abc.def', '0.3.1'), isFalse);
    });
  });

  group('AppUpdateService.pickAsset', () {
    final service = AppUpdateService();

    ReleaseInfo makeRelease(List<String> names) {
      return ReleaseInfo(
        tagName: 'v0.4.0',
        name: 'v0.4.0',
        body: '',
        assets: names
            .map(
              (n) => ReleaseAsset(
                name: n,
                downloadUrl: 'https://example.com/$n',
                size: 1000,
              ),
            )
            .toList(),
      );
    }

    test('selects ABI-specific asset when available', () {
      final release = makeRelease([
        'openvsmobile-app-v0.4.0-arm64-v8a.apk',
        'openvsmobile-app-v0.4.0-universal.apk',
      ]);
      final asset = service.pickAsset(release, 'arm64-v8a');
      expect(asset, isNotNull);
      expect(asset!.name, contains('arm64-v8a'));
    });

    test('falls back to universal when ABI not found', () {
      final release = makeRelease([
        'openvsmobile-app-v0.4.0-arm64-v8a.apk',
        'openvsmobile-app-v0.4.0-universal.apk',
      ]);
      final asset = service.pickAsset(release, 'x86_64');
      expect(asset, isNotNull);
      expect(asset!.name, contains('universal'));
    });

    test('returns null when no APK matches', () {
      final release = makeRelease(['openvsmobile-backend-linux-x64.tar.gz']);
      final asset = service.pickAsset(release, 'arm64-v8a');
      expect(asset, isNull);
    });
  });
}
