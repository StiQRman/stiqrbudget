/// Application build flavor and runtime configuration.
class AppConfig {
  /// Compile-time app version matching `pubspec.yaml` (without build number).
  static const String appVersion = '1.0.25';

  /// Whether the app is built for Google Play Store.
  /// In Google Play builds, direct APK downloads and self-hosted update checkers
  /// are stripped out to comply with Google Play Developer Policies.
  ///
  /// Can be activated via compile-time define:
  /// `--dart-define=PLAY_STORE=true` or `--dart-define=FLAVOR=playStore` (or `playstore`)
  static const String _flavor =
      String.fromEnvironment('FLAVOR', defaultValue: 'proto');

  static const bool isPlayStore =
      bool.fromEnvironment('PLAY_STORE', defaultValue: false) ||
      _flavor == 'playStore' ||
      _flavor == 'playstore';

  /// Prototype / self-hosted mode (default build behavior).
  /// In-app APK downloads and StiQRhub/PocketBase update checkers are active.
  static bool get isPrototype => !isPlayStore;
}
