import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../models/app_release.dart';
import 'pb_provider.dart';

// Provides the currently running client's installed version
final currentAppVersionProvider = FutureProvider<String>((ref) async {
  if (kIsWeb) {
    return AppConfig.appVersion;
  }
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version.isNotEmpty
        ? packageInfo.version
        : AppConfig.appVersion;
  } catch (e) {
    return AppConfig.appVersion;
  }
});

class ReleasesState {
  final List<AppRelease> releases;
  final bool isLoading;
  final String? error;

  const ReleasesState({
    this.releases = const [],
    this.isLoading = false,
    this.error,
  });

  ReleasesState copyWith({
    List<AppRelease>? releases,
    bool? isLoading,
    String? error,
  }) {
    return ReleasesState(
      releases: releases ?? this.releases,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class ReleasesNotifier extends StateNotifier<ReleasesState> {
  final Ref ref;

  ReleasesNotifier(this.ref) : super(const ReleasesState(isLoading: false)) {
    if (!AppConfig.isPlayStore) {
      state = state.copyWith(isLoading: true);
      loadReleases();
      _subscribeToPB();
    }
  }

  Future<void> loadReleases() async {
    if (AppConfig.isPlayStore) {
      state = state.copyWith(isLoading: false, releases: const []);
      return;
    }
    state = state.copyWith(isLoading: true, error: null);
    try {
      final pbService = ref.read(pbServiceProvider);
      final releases = await pbService.fetchReleases();
      state = state.copyWith(
        releases: releases,
        isLoading: false,
        error: null,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void _subscribeToPB() {
    try {
      final pbService = ref.read(pbServiceProvider);
      pbService.subscribeReleases((event) {
        // Reload releases whenever an event is received
        loadReleases();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      final pbService = ref.read(pbServiceProvider);
      pbService.unsubscribeReleases();
    } catch (_) {}
    super.dispose();
  }
}

final releasesProvider = StateNotifierProvider<ReleasesNotifier, ReleasesState>((ref) {
  return ReleasesNotifier(ref);
});

// Returns the latest release (or null if none found)
final latestReleaseProvider = Provider<AppRelease?>((ref) {
  if (AppConfig.isPlayStore) return null;
  final state = ref.watch(releasesProvider);
  if (state.releases.isEmpty) return null;
  
  // Look for release explicitly marked isLatest, or default to first release
  return state.releases.firstWhere(
    (r) => r.isLatest,
    orElse: () => state.releases.first,
  );
});

// Returns true if a newer version exists compared to the installed client
final hasUpdateProvider = Provider<bool>((ref) {
  if (AppConfig.isPlayStore) return false;
  final latest = ref.watch(latestReleaseProvider);
  final currentVersionAsync = ref.watch(currentAppVersionProvider);

  if (latest == null || latest.isFallback) return false;
  final currentVersion = currentVersionAsync.value ?? AppConfig.appVersion;

  return _isVersionNewer(latest.version, currentVersion);
});

// Helper to compare semver strings e.g. "v1.1.0" vs "1.0.0"
bool _isVersionNewer(String latest, String current) {
  try {
    String cleanLatest = latest.toLowerCase().replaceAll('v', '').trim();
    String cleanCurrent = current.toLowerCase().replaceAll('v', '').trim();

    final latestParts = cleanLatest.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final currentParts = cleanCurrent.split('.').map((p) => int.tryParse(p) ?? 0).toList();

    for (int i = 0; i < 3; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  } catch (_) {
    return false;
  }
}

// Download action helper: triggers immediate file download from PocketBase
Future<bool> launchApkDownload(AppRelease release) async {
  if (release.apkUrl.isEmpty) {
    return false;
  }

  try {
    final uri = Uri.parse(release.apkUrl);
    // On web and native, LaunchMode.externalApplication triggers direct file download stream
    final success = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
    return success;
  } catch (e) {
    if (kDebugMode) {
      print("Failed to launch APK download: $e");
    }
    return false;
  }
}
