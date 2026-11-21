import 'package:flutter_test/flutter_test.dart';
import 'package:budget_app/models/app_release.dart';

void main() {
  group('AppRelease Model Tests', () {
    test('fromJson creates correct model with defaults', () {
      final json = {
        'id': 'rel_123',
        'version': 'v1.2.0',
        'release_date': '2026-09-15T12:00:00.000Z',
        'apk_file_name': 'app-release.apk',
        'apk_url': 'https://api.stiqrnotes.com/api/files/app_releases/rel_123/app-release.apk?download=1',
        'changelog': 'Bug fixes and performance improvements.',
        'file_size': '24.5 MB',
        'is_latest': true,
        'is_fallback': false,
      };

      final release = AppRelease.fromJson(json);

      expect(release.id, 'rel_123');
      expect(release.version, 'v1.2.0');
      expect(release.apkFileName, 'app-release.apk');
      expect(release.apkUrl, contains('?download=1'));
      expect(release.changelog, 'Bug fixes and performance improvements.');
      expect(release.fileSize, '24.5 MB');
      expect(release.isLatest, true);
      expect(release.isFallback, false);
    });

    test('toJson produces expected structure', () {
      final release = AppRelease(
        id: 'rel_001',
        version: 'v1.0.0',
        releaseDate: DateTime.parse('2026-09-01T00:00:00.000Z'),
        apkFileName: 'stiqr_budget.apk',
        apkUrl: 'https://example.com/download.apk',
        changelog: 'Initial release',
        fileSize: '20 MB',
        isLatest: false,
        isFallback: false,
      );

      final json = release.toJson();

      expect(json['id'], 'rel_001');
      expect(json['version'], 'v1.0.0');
      expect(json['apk_file_name'], 'stiqr_budget.apk');
      expect(json['is_latest'], false);
    });

    test('copyWith works correctly', () {
      final release = AppRelease(
        id: 'rel_001',
        version: 'v1.0.0',
        releaseDate: DateTime.now(),
        apkFileName: 'app.apk',
        apkUrl: 'https://example.com/apk',
        changelog: 'Old changelog',
      );

      final updated = release.copyWith(
        version: 'v1.0.1',
        isLatest: true,
      );

      expect(updated.version, 'v1.0.1');
      expect(updated.isLatest, true);
      expect(updated.id, 'rel_001');
      expect(updated.apkFileName, 'app.apk');
    });
  });
}
