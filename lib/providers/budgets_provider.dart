import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pb_provider.dart';
import 'auth_provider.dart';
import 'shared_prefs_provider.dart';

class Budget {
  final String id;
  final String name;

  Budget({required this.id, required this.name});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class ActiveBudgetIdNotifier extends StateNotifier<String> {
  final Ref? _ref;
  final SharedPreferences? _prefs;

  ActiveBudgetIdNotifier([this._ref, this._prefs])
      : super('budget_1') {
    if (_ref != null) {
      _ref.listen(authProvider, (previous, next) {
        if (next.isAuthenticated) {
          _load();
        } else {
          state = 'budget_1';
        }
      });
    }
    _load();
  }

  String _getPrefKey() {
    final pub = _ref?.read(pbServiceProvider).currentUserPubAddress;
    if (pub != null && pub.isNotEmpty) {
      return 'active_budget_id_$pub';
    }
    return 'active_budget_id_guest';
  }

  Future<void> _load() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final key = _getPrefKey();
    final saved = prefs.getString(key);
    if (saved != null && saved.isNotEmpty) {
      state = saved;
    } else {
      // Check legacy migration if authenticated
      final legacy = prefs.getString('active_budget_id');
      if (legacy != null && legacy.isNotEmpty) {
        state = legacy;
        await prefs.setString(key, legacy);
        await prefs.remove('active_budget_id');
      } else {
        state = 'budget_1';
      }
    }
  }

  Future<void> setActiveBudget(String budgetId) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final key = _getPrefKey();
    await prefs.setString(key, budgetId);
    state = budgetId;
  }
}

final activeBudgetIdProvider = StateNotifierProvider<ActiveBudgetIdNotifier, String>((ref) {
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return ActiveBudgetIdNotifier(ref, prefs);
});

class BudgetsListNotifier extends StateNotifier<List<Budget>> {
  final Ref _ref;
  final SharedPreferences? _prefs;

  BudgetsListNotifier(this._ref, [this._prefs]) : super([Budget(id: 'budget_1', name: 'My Budget')]) {
    final pbService = _ref.read(pbServiceProvider);
    pbService.addMetadataListener(_load);
    _ref.listen(authProvider, (previous, next) {
      if (next.isAuthenticated) {
        _load();
      } else {
        // Reset to default isolated state on logout
        state = [Budget(id: 'budget_1', name: 'My Budget')];
      }
    });
    _load();
  }

  String _getPrefKey() {
    final pub = _ref.read(pbServiceProvider).currentUserPubAddress;
    if (pub != null && pub.isNotEmpty) {
      return 'budgets_list_$pub';
    }
    return 'budgets_list_guest';
  }

  Future<void> _load() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final key = _getPrefKey();
    final savedJson = prefs.getString(key);
    if (savedJson != null && savedJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(savedJson);
        final budgets = decoded
            .map((item) => Budget.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        if (budgets.isNotEmpty) {
          state = budgets;
          return;
        }
      } catch (e) {
        print("Error loading budgets list: $e");
      }
    }

    // Fallback: If user is authenticated and pbService has descriptors in memory
    final pbService = _ref.read(pbServiceProvider);
    if (pbService.isAuthenticated && pbService.availableBudgets.isNotEmpty) {
      state = pbService.availableBudgets
          .map((d) => Budget(
                id: d.localBudgetId,
                name: d.isShared
                    ? (d.isReadOnly ? '${d.name} (View-Only)' : '${d.name} (Shared)')
                    : d.name,
              ))
          .toList();
      await _save();
      return;
    }

    // Otherwise, default clean single budget
    state = [Budget(id: 'budget_1', name: 'My Budget')];
  }

  Future<void> _save({bool syncCloud = true}) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final key = _getPrefKey();
    final jsonStr = jsonEncode(state.map((b) => b.toJson()).toList());
    await prefs.setString(key, jsonStr);
    if (syncCloud) {
      final pbService = _ref.read(pbServiceProvider);
      if (pbService.isAuthenticated) {
        unawaited(pbService.syncVaultToCloud().catchError((_) {}));
      }
    }
  }

  bool canAddBudget(bool isSubscribed) {
    if (isSubscribed) return true;
    // Free tier includes 1 budget
    return state.isEmpty;
  }

  Future<Budget> addBudget(String name) async {
    final newId = 'budget_${DateTime.now().millisecondsSinceEpoch}';
    final newBudget = Budget(id: newId, name: name);
    state = [...state, newBudget];
    await _save(syncCloud: false);
    unawaited(
      _ref
          .read(pbServiceProvider)
          .registerOrRenameLocalBudget(newId, name)
          .catchError((_) {}),
    );
    return newBudget;
  }

  Future<Budget> addBudgetWithId(String id, String name) async {
    if (state.any((b) => b.id == id)) {
      return state.firstWhere((b) => b.id == id);
    }
    final newBudget = Budget(id: id, name: name);
    state = [...state, newBudget];
    await _save();
    return newBudget;
  }

  Future<void> renameBudget(String id, String newName) async {
    state = [
      for (final budget in state)
        if (budget.id == id) Budget(id: id, name: newName) else budget
    ];
    await _save(syncCloud: false);
    unawaited(
      _ref
          .read(pbServiceProvider)
          .registerOrRenameLocalBudget(id, newName)
          .catchError((_) {}),
    );
  }

  Future<bool> deleteBudget(String id) async {
    if (state.length <= 1) {
      return false; // Cannot delete only budget
    }
    final remaining = state.where((b) => b.id != id).toList();
    state = remaining;

    final activeId = _ref.read(activeBudgetIdProvider);
    if (activeId == id && remaining.isNotEmpty) {
      await _ref.read(activeBudgetIdProvider.notifier).setActiveBudget(remaining.first.id);
    }

    await _save(syncCloud: false);
    unawaited(
      _ref.read(pbServiceProvider).deleteBudget(id).catchError((_) {}),
    );
    return true;
  }
}

final budgetsListProvider = StateNotifierProvider<BudgetsListNotifier, List<Budget>>((ref) {
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return BudgetsListNotifier(ref, prefs);
});
