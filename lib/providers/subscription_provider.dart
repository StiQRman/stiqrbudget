import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'shared_prefs_provider.dart';

enum SubscriptionTier {
  free,
  multiBudgetAddon, // $1/mo or $10/yr
  allAccessBundle,  // $2.49/mo or $19.99/yr
}

class SubscriptionState {
  final SubscriptionTier tier;

  const SubscriptionState({
    this.tier = SubscriptionTier.free,
  });

  bool get isMultiBudgetUnlocked =>
      AppConfig.isPlayStore ||
      tier == SubscriptionTier.multiBudgetAddon ||
      tier == SubscriptionTier.allAccessBundle;

  bool get isAllAccess => tier == SubscriptionTier.allAccessBundle;

  SubscriptionState copyWith({
    SubscriptionTier? tier,
  }) {
    return SubscriptionState(
      tier: tier ?? this.tier,
    );
  }
}

class SubscriptionNotifier extends StateNotifier<SubscriptionState> {
  static const String _tierPrefKey = 'user_subscription_tier';
  final SharedPreferences? _prefs;

  SubscriptionNotifier([this._prefs]) : super(_initialState(_prefs)) {
    if (_prefs == null) {
      _load();
    }
  }

  static SubscriptionState _initialState(SharedPreferences? prefs) {
    if (prefs != null) {
      final savedTierStr = prefs.getString(_tierPrefKey);
      if (savedTierStr != null) {
        final tier = SubscriptionTier.values.firstWhere(
          (t) => t.name == savedTierStr,
          orElse: () => SubscriptionTier.free,
        );
        return SubscriptionState(tier: tier);
      }
    }
    return const SubscriptionState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTierStr = prefs.getString(_tierPrefKey);
    if (savedTierStr != null) {
      final tier = SubscriptionTier.values.firstWhere(
        (t) => t.name == savedTierStr,
        orElse: () => SubscriptionTier.free,
      );
      state = state.copyWith(tier: tier);
    }
  }

  Future<void> upgradeTo(SubscriptionTier tier) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_tierPrefKey, tier.name);
    state = state.copyWith(tier: tier);
  }

  Future<void> resetToFree() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_tierPrefKey);
    state = const SubscriptionState(tier: SubscriptionTier.free);
  }
}

final subscriptionProvider =
    StateNotifierProvider<SubscriptionNotifier, SubscriptionState>((ref) {
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return SubscriptionNotifier(prefs);
});
