import 'package:pocketbase/pocketbase.dart';

class AppRelease {
  final String id;
  final String version;
  final DateTime releaseDate;
  final String apkFileName;
  final String apkUrl;
  final String changelog;
  final String fileSize;
  final bool isLatest;
  final bool isFallback;

  AppRelease({
    required this.id,
    required this.version,
    required this.releaseDate,
    required this.apkFileName,
    required this.apkUrl,
    required this.changelog,
    this.fileSize = '',
    this.isLatest = false,
    this.isFallback = false,
  });

  factory AppRelease.fromRecord(RecordModel record, PocketBase pb) {
    // Determine the apk file field name (supports 'apk_file' or 'apk')
    String apkFile = record.getStringValue('apk_file');
    if (apkFile.isEmpty) {
      apkFile = record.getStringValue('apk');
    }
    if (apkFile.isEmpty) {
      final list = record.getListValue<String>('apk_file');
      if (list.isNotEmpty) apkFile = list.first;
    }

    // Direct download URL with ?download=1 and version query for immediate file download & cache-busting
    String downloadUrl = '';
    if (apkFile.isNotEmpty) {
      final vTag = record.getStringValue('version').trim().replaceAll(' ', '_');
      final updatedTag = record.updated.isNotEmpty ? record.updated.replaceAll(' ', '_') : '1';
      downloadUrl = pb.files.getUrl(record, apkFile, query: {
        'download': '1',
        'v': '${vTag}_$updatedTag',
      }).toString();
    }

    DateTime parsedDate;
    final dateStr = record.getStringValue('release_date');
    if (dateStr.isNotEmpty) {
      parsedDate = DateTime.tryParse(dateStr) ?? DateTime.tryParse(record.created) ?? DateTime.now();
    } else {
      parsedDate = DateTime.tryParse(record.created) ?? DateTime.now();
    }

    String version = record.getStringValue('version').trim();
    if (!version.startsWith('v') && !version.startsWith('V')) {
      version = 'v$version';
    }

    return AppRelease(
      id: record.id,
      version: version,
      releaseDate: parsedDate,
      apkFileName: apkFile,
      apkUrl: downloadUrl,
      changelog: record.getStringValue('changelog'),
      fileSize: record.getStringValue('file_size'),
      isLatest: record.getBoolValue('is_latest', false),
      isFallback: false,
    );
  }

  factory AppRelease.fromStiQRhubJson(
    Map<String, dynamic> json,
    String hubBaseUrl, {
    bool forceLatest = false,
  }) {
    final String artifactFilename = (json['artifact_filename'] ?? '').toString();
    final String artifactPath = (json['artifact_path'] ?? '').toString();
    String downloadUrl = '';
    if (artifactPath.isNotEmpty) {
      downloadUrl = '$hubBaseUrl/releases/$artifactPath';
    } else if (artifactFilename.isNotEmpty) {
      downloadUrl = '$hubBaseUrl/releases/$artifactFilename';
    }

    String version = (json['version'] ?? 'v1.0.0').toString().trim();
    if (!version.startsWith('v') && !version.startsWith('V')) {
      version = 'v$version';
    }

    final createdAtStr = (json['created_at'] ?? '').toString();
    final parsedDate = DateTime.tryParse(createdAtStr) ?? DateTime.now();
    final isLatestFlag = json['is_latest'] == 1 || json['is_latest'] == true || forceLatest;

    return AppRelease(
      id: (json['id'] ?? '').toString(),
      version: version,
      releaseDate: parsedDate,
      apkFileName: artifactFilename,
      apkUrl: downloadUrl,
      changelog: (json['changelog'] ?? json['title'] ?? '').toString(),
      fileSize: (json['artifact_size'] ?? '').toString(),
      isLatest: isLatestFlag,
      isFallback: false,
    );
  }

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    return AppRelease(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? 'v1.0.0',
      releaseDate: json['release_date'] != null
          ? DateTime.tryParse(json['release_date'] as String) ?? DateTime.now()
          : DateTime.now(),
      apkFileName: json['apk_file_name'] as String? ?? '',
      apkUrl: json['apk_url'] as String? ?? '',
      changelog: json['changelog'] as String? ?? '',
      fileSize: json['file_size'] as String? ?? '',
      isLatest: json['is_latest'] as bool? ?? false,
      isFallback: json['is_fallback'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'version': version,
      'release_date': releaseDate.toIso8601String(),
      'apk_file_name': apkFileName,
      'apk_url': apkUrl,
      'changelog': changelog,
      'file_size': fileSize,
      'is_latest': isLatest,
      'is_fallback': isFallback,
    };
  }

  AppRelease copyWith({
    String? id,
    String? version,
    DateTime? releaseDate,
    String? apkFileName,
    String? apkUrl,
    String? changelog,
    String? fileSize,
    bool? isLatest,
    bool? isFallback,
  }) {
    return AppRelease(
      id: id ?? this.id,
      version: version ?? this.version,
      releaseDate: releaseDate ?? this.releaseDate,
      apkFileName: apkFileName ?? this.apkFileName,
      apkUrl: apkUrl ?? this.apkUrl,
      changelog: changelog ?? this.changelog,
      fileSize: fileSize ?? this.fileSize,
      isLatest: isLatest ?? this.isLatest,
      isFallback: isFallback ?? this.isFallback,
    );
  }
}
