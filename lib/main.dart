import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/auth_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/pb_provider.dart';
import 'providers/shared_prefs_provider.dart';
import 'services/pocketbase_service.dart';
import 'utils/app_theme.dart';
import 'views/landing_view.dart';
import 'views/dashboard_view.dart';
import 'views/biometric_lock_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final prefs = await SharedPreferences.getInstance();
  final pbService = PocketBaseService();
  await pbService.restoreSession();

  runApp(
    ProviderScope(
      overrides: [
        pbServiceProvider.overrideWithValue(pbService),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final settingsState = ref.watch(settingsProvider);

    Widget homeWidget;
    if (!authState.isAuthenticated) {
      homeWidget = const LandingView();
    } else if (settingsState.useBiometrics && !settingsState.isBiometricUnlocked) {
      homeWidget = const BiometricLockView();
    } else {
      homeWidget = const DashboardView();
    }

    return MaterialApp(
      title: 'StiqrBudget',
      debugShowCheckedModeBanner: false,
      themeMode: settingsState.themeMode,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: homeWidget,
    );
  }
}
