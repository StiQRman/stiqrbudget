import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pb_provider.dart';
import 'auth_provider.dart';
import 'budgets_provider.dart';
import 'shared_prefs_provider.dart';
import '../models/category.dart';
import '../services/pocketbase_service.dart';

class CategoriesNotifier extends StateNotifier<List<Category>> {
  final Ref _ref;
  final PocketBaseService _pbService;
  StreamSubscription? _subscription;
  List<String> _customOrder = [];

  CategoriesNotifier(this._ref)
      : _pbService = _ref.read(pbServiceProvider),
        super(_getInitialCategories(_ref)) {
    _initOrder();
    _pbService.addMetadataListener(_onRemoteMetadataUpdated);

    // Listen to authentication changes
    _ref.listen(authProvider, (previous, next) {
      if (next.isAuthenticated) {
        loadCategories();
      } else {
        _cleanup();
      }
    });

    // Listen to active budget changes
    _ref.listen(activeBudgetIdProvider, (previous, next) {
      if (_ref.read(authProvider).isAuthenticated) {
        loadCategories();
      }
    });

    // Load initial categories if already authenticated
    if (_ref.read(authProvider).isAuthenticated) {
      loadCategories();
    }
  }

  static List<Category> _getInitialCategories(Ref ref) {
    try {
      final pbService = ref.read(pbServiceProvider);
      final activeBudgetId = ref.read(activeBudgetIdProvider);
      final allCats = pbService.categories;
      final filtered = allCats.where((c) => c.budgetId == activeBudgetId).toList();
      return filtered;
    } catch (_) {
      return [];
    }
  }

  void _initOrder() {
    try {
      final activeBudgetId = _ref.read(activeBudgetIdProvider);
      final prefs = _ref.read(sharedPreferencesProvider);
      final orderKey = 'category_order_$activeBudgetId';
      _customOrder = prefs.getStringList(orderKey) ?? [];
      if (state.isNotEmpty) {
        _applyOrderAndSetState(List.from(state));
      }
    } catch (_) {}
  }

  void _onRemoteMetadataUpdated() {
    if (_ref.read(authProvider).isAuthenticated) {
      loadCategories();
    }
  }

  void _applyOrderAndSetState(List<Category> list) {
    list.sort((a, b) {
      if (a.isUnallocated && b.isUnallocated) return 0;
      if (a.isUnallocated) return -1;
      if (b.isUnallocated) return 1;

      final indexA = _customOrder.indexOf(a.id);
      final indexB = _customOrder.indexOf(b.id);
      if (indexA == -1 && indexB == -1) return a.name.compareTo(b.name);
      if (indexA == -1) return 1;
      if (indexB == -1) return -1;
      return indexA.compareTo(indexB);
    });
    state = list;
  }

  /// Optimistically updates category balances in Riverpod state immediately.
  /// [deltas] maps categoryId -> balance change (positive or negative).
  void updateOptimisticBalances(Map<String, double> deltas) {
    if (deltas.isEmpty) return;
    final updatedList = [
      for (final cat in state)
        if (deltas.containsKey(cat.id))
          cat.copyWith(
            balance: (((cat.balance * 100).round() + (deltas[cat.id]! * 100).round()) / 100.0),
          )
        else
          cat,
    ];
    _applyOrderAndSetState(updatedList);
  }

  /// Optimistically update or replace a category in Riverpod state immediately.
  void updateOptimisticCategory(Category updated) {
    final updatedList = [
      for (final cat in state)
        if (cat.id == updated.id) updated else cat,
    ];
    _applyOrderAndSetState(updatedList);
  }

  Future<void> loadCategories() async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final list = await pbService.fetchCategories();
      
      // Auto-discover budgets from categories fetched from the server
      final budgetsListNotifier = _ref.read(budgetsListProvider.notifier);
      final currentBudgets = _ref.read(budgetsListProvider);
      final currentBudgetIds = currentBudgets.map((b) => b.id).toSet();
      
      for (final cat in list) {
        if (!currentBudgetIds.contains(cat.budgetId)) {
          final descName = pbService.getBudgetDescriptor(cat.budgetId)?.name;
          final displayName = (descName != null && descName.isNotEmpty)
              ? descName
              : (cat.budgetId == 'budget_1' ? 'My Budget' : 'Linked Budget');
          await budgetsListNotifier.addBudgetWithId(cat.budgetId, displayName);
          currentBudgetIds.add(cat.budgetId);
        }
      }
      
      final activeBudgetId = _ref.read(activeBudgetIdProvider);
      SharedPreferences prefs;
      try {
        prefs = _ref.read(sharedPreferencesProvider);
      } catch (_) {
        prefs = await SharedPreferences.getInstance();
      }
      final orderKey = 'category_order_$activeBudgetId';
      _customOrder = prefs.getStringList(orderKey) ?? [];

      final filteredList = list.where((cat) => cat.budgetId == activeBudgetId).toList();
      _applyOrderAndSetState(filteredList);
      
      // Ensure "Unallocated" category exists only after remote state has loaded
      if (pbService.hasLoadedRemoteOnce && !pbService.isSyncing) {
        await _ensureUnallocatedCategoryExists();
      }
      
      // Setup subscription for real-time updates
      _setupRealtimeSubscription();
    } catch (e) {
      // Handle loading error if necessary
      print("Error loading categories: $e");
    }
  }

  Future<void> _ensureUnallocatedCategoryExists() async {
    final hasUnallocated = state.any((cat) => cat.isUnallocated);
    if (!hasUnallocated && _ref.read(authProvider).isAuthenticated) {
      final pbService = _ref.read(pbServiceProvider);
      final activeBudgetId = _ref.read(activeBudgetIdProvider);
      if (pbService.isBudgetReadOnly(activeBudgetId)) return;
      final newUnallocated = Category(
        id: '',
        name: 'Unallocated',
        balance: 0.0,
        colorHex: '#64748B', // Slate grey
        iconName: 'inbox',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: pbService.currentUserId ?? '',
        budgetId: activeBudgetId,
      );
      
      final created = await pbService.createCategory(
        newUnallocated,
        syncImmediately: false,
      );
      if (!state.any((cat) => cat.id == created.id)) {
        final newList = [...state, created];
        _applyOrderAndSetState(newList);
      }
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
    }
  }

  void _setupRealtimeSubscription() async {
    await _subscription?.cancel();
    final pbService = _ref.read(pbServiceProvider);
    await pbService.unsubscribeCategories();
    
    await pbService.subscribeCategories((event) {
      final record = event.record;
      if (record == null) return;
      
      final json = record.toJson();
      final updatedCategory = Category.fromJson(json);

      // Verify it belongs to the active budget
      final activeBudgetId = _ref.read(activeBudgetIdProvider);
      if (updatedCategory.budgetId != activeBudgetId) return;

      if (event.action == 'create') {
        // Prevent duplicate entries
        if (!state.any((cat) => cat.id == updatedCategory.id)) {
          final newList = [...state, updatedCategory];
          _applyOrderAndSetState(newList);
        }
      } else if (event.action == 'update') {
        final newList = [
          for (final cat in state)
            if (cat.id == updatedCategory.id) updatedCategory else cat
        ];
        _applyOrderAndSetState(newList);
      } else if (event.action == 'delete') {
        final newList = state.where((cat) => cat.id != updatedCategory.id).toList();
        _applyOrderAndSetState(newList);
      }
    });
  }

  Future<Category?> addCategory({
    required String name,
    required double balance,
    required String colorHex,
    required String iconName,
    required AllocationType allocationType,
    required double allocationValue,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final activeBudgetId = _ref.read(activeBudgetIdProvider);
      final newCat = Category(
        id: '',
        name: name,
        balance: balance,
        colorHex: colorHex,
        iconName: iconName,
        allocationType: allocationType,
        allocationValue: allocationValue,
        user: pbService.currentUserId ?? '',
        budgetId: activeBudgetId,
      );
      
      final created = await pbService.createCategory(
        newCat,
        syncImmediately: false,
      );
      if (!_customOrder.contains(created.id)) {
        _customOrder.add(created.id);
        final orderKey = 'category_order_$activeBudgetId';
        unawaited(
          SharedPreferences.getInstance()
              .then((prefs) => prefs.setStringList(orderKey, _customOrder))
              .catchError((_) => false),
        );
      }
      if (!state.any((cat) => cat.id == created.id)) {
        final newList = [...state, created];
        _applyOrderAndSetState(newList);
      } else {
        _applyOrderAndSetState([...state]);
      }
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
      return created;
    } catch (e) {
      print("Error creating category: $e");
      return null;
    }
  }

  Future<bool> editCategory(Category category) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      // Optimistically update in-memory state immediately
      updateOptimisticCategory(category);
      await pbService.updateCategory(category, syncImmediately: false);
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
      return true;
    } catch (e) {
      print("Error updating category: $e");
      return false;
    }
  }

  Future<bool> removeCategory(String id) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      // Optimistically remove from in-memory state immediately
      final updatedList = state.where((cat) => cat.id != id).toList();
      _applyOrderAndSetState(updatedList);
      await pbService.deleteCategory(id, syncImmediately: false);
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
      return true;
    } catch (e) {
      print("Error deleting category: $e");
      return false;
    }
  }

  Future<void> reorderCategories(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final otherCats = state.where((cat) => !cat.isUnallocated).toList();
    if (oldIndex >= otherCats.length || newIndex >= otherCats.length) return;

    final item = otherCats.removeAt(oldIndex);
    otherCats.insert(newIndex, item);

    // Save order
    _customOrder = otherCats.map((c) => c.id).toList();
    final activeBudgetId = _ref.read(activeBudgetIdProvider);
    final orderKey = 'category_order_$activeBudgetId';

    // Update state immediately maintaining Unallocated at the top
    final unallocated = state.where((cat) => cat.isUnallocated).toList();
    state = [...unallocated, ...otherCats];

    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setStringList(orderKey, _customOrder))
          .catchError((_) => false),
    );
    unawaited(_pbService.syncVaultToCloud().catchError((_) {}));
  }

  void _cleanup() {
    _subscription?.cancel();
    _pbService.unsubscribeCategories();
    state = [];
  }

  @override
  void dispose() {
    _pbService.removeMetadataListener(_onRemoteMetadataUpdated);
    _cleanup();
    super.dispose();
  }
}

final categoriesProvider = StateNotifierProvider<CategoriesNotifier, List<Category>>((ref) {
  return CategoriesNotifier(ref);
});
