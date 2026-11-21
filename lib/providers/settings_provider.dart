import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'shared_prefs_provider.dart';

class SettingsState {
  final bool useBiometrics;
  final bool isBiometricsSupported;
  final bool isBiometricUnlocked;
  final ThemeMode themeMode;

  SettingsState({
    this.useBiometrics = false,
    this.isBiometricsSupported = false,
    this.isBiometricUnlocked = false,
    this.themeMode = ThemeMode.dark,
  });

  SettingsState copyWith({
    bool? useBiometrics,
    bool? isBiometricsSupported,
    bool? isBiometricUnlocked,
    ThemeMode? themeMode,
  }) {
    return SettingsState(
      useBiometrics: useBiometrics ?? this.useBiometrics,
      isBiometricsSupported: isBiometricsSupported ?? this.isBiometricsSupported,
      isBiometricUnlocked: isBiometricUnlocked ?? this.isBiometricUnlocked,
      themeMode: themeMode ?? this.themeMode,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref? _ref;
  final SharedPreferences? _initialPrefs;
  final LocalAuthentication _auth = LocalAuthentication();
  static const String _biometricsKey = 'use_biometrics';
  static const String _themeModeKey = 'theme_mode';

  SettingsNotifier([this._ref, this._initialPrefs])
      : super(_buildInitialState(_initialPrefs)) {
    _init();
  }

  static SettingsState _buildInitialState(SharedPreferences? prefs) {
    if (prefs == null) {
      return SettingsState();
    }
    final useBio = prefs.getBool(_biometricsKey) ?? false;
    final themeStr = prefs.getString(_themeModeKey);
    ThemeMode mode = ThemeMode.dark;
    if (themeStr == 'light') {
      mode = ThemeMode.light;
    } else if (themeStr == 'system') {
      mode = ThemeMode.system;
    }

    return SettingsState(
      useBiometrics: useBio,
      isBiometricsSupported: false,
      isBiometricUnlocked: !useBio,
      themeMode: mode,
    );
  }

  Future<SharedPreferences> _getPrefs() async {
    final initPrefs = _initialPrefs;
    if (initPrefs != null) return initPrefs;
    final r = _ref;
    if (r != null) {
      try {
        return r.read(sharedPreferencesProvider);
      } catch (_) {}
    }
    return await SharedPreferences.getInstance();
  }

  Future<void> _init() async {
    final prefs = await _getPrefs();
    final useBio = prefs.getBool(_biometricsKey) ?? false;
    final themeStr = prefs.getString(_themeModeKey);
    ThemeMode mode = ThemeMode.dark;
    if (themeStr == 'light') {
      mode = ThemeMode.light;
    } else if (themeStr == 'system') {
      mode = ThemeMode.system;
    }

    // Check device capability (local_auth is not supported on Flutter Web)
    bool isSupported = false;
    if (!kIsWeb) {
      try {
        final canCheck = await _auth.canCheckBiometrics;
        final isDeviceSupported = await _auth.isDeviceSupported();
        isSupported = canCheck || isDeviceSupported;
      } catch (e) {
        print("Error checking biometrics: $e");
      }
    }

    state = state.copyWith(
      useBiometrics: useBio,
      isBiometricsSupported: isSupported,
      isBiometricUnlocked: !useBio,
      themeMode: mode,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await _getPrefs();
    String val = 'dark';
    if (mode == ThemeMode.light) {
      val = 'light';
    } else if (mode == ThemeMode.system) {
      val = 'system';
    }
    await prefs.setString(_themeModeKey, val);
    state = state.copyWith(themeMode: mode);
  }

  Future<bool> toggleBiometrics(bool value) async {
    if (value) {
      final success = await authenticate('Confirm biometric enrollment');
      if (!success) return false;
    }

    final prefs = await _getPrefs();
    await prefs.setBool(_biometricsKey, value);

    state = state.copyWith(
      useBiometrics: value,
      isBiometricUnlocked: !value || state.isBiometricUnlocked,
    );
    return true;
  }

  Future<bool> authenticate([String reason = 'Authenticate to unlock StiqrBudget']) async {
    if (kIsWeb) return false;
    try {
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (didAuth) {
        state = state.copyWith(isBiometricUnlocked: true);
      }
      return didAuth;
    } catch (e) {
      print("Biometric auth error: $e");
      return false;
    }
  }

  void lock() {
    if (state.useBiometrics) {
      state = state.copyWith(isBiometricUnlocked: false);
    }
  }

  void forceUnlock() {
    state = state.copyWith(isBiometricUnlocked: true);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return SettingsNotifier(ref, prefs);
});
