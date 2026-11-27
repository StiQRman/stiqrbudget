import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pb_provider.dart';
import 'auth_provider.dart';
import 'categories_provider.dart';
import 'budgets_provider.dart';
import '../models/transaction_model.dart';
import '../models/category.dart';
import '../models/undo_action.dart';
import '../services/pocketbase_service.dart';

class TransactionsNotifier extends StateNotifier<List<TransactionModel>> {
  final Ref _ref;
  final PocketBaseService _pbService;
  StreamSubscription? _subscription;
  UndoAction? _lastUndoAction;

  UndoAction? get lastUndoAction => _lastUndoAction;

  TransactionsNotifier(this._ref)
      : _pbService = _ref.read(pbServiceProvider),
        super(_getInitialTransactions(_ref)) {
    loadUndoAction();
    _pbService.addMetadataListener(_onRemoteMetadataUpdated);

    // Listen to authentication changes
    _ref.listen(authProvider, (previous, next) {
      if (next.isAuthenticated) {
        loadTransactions();
      } else {
        _cleanup();
      }
    });

    // Listen to active budget changes
    _ref.listen(activeBudgetIdProvider, (previous, next) {
      if (_ref.read(authProvider).isAuthenticated) {
        loadTransactions();
      }
    });

    // Listen to categories changes so transactions re-filter when categories finish loading
    _ref.listen(categoriesProvider, (previous, next) {
      if (_ref.read(authProvider).isAuthenticated &&
          (previous == null || previous.length != next.length)) {
        loadTransactions();
      }
    });

    if (_ref.read(authProvider).isAuthenticated) {
      loadTransactions();
    }
  }

  static List<TransactionModel> _getInitialTransactions(Ref ref) {
    try {
      final pbService = ref.read(pbServiceProvider);
      final activeCategories = ref.read(categoriesProvider);
      final activeCategoryIds = activeCategories.map((c) => c.id).toSet();
      return pbService.transactions.where((tx) {
        if (tx.type == TransactionType.transfer) {
          return activeCategoryIds.contains(tx.sourceCategory) ||
              activeCategoryIds.contains(tx.destinationCategory);
        }
        if (tx.category != null) {
          return activeCategoryIds.contains(tx.category);
        }
        return true;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  void _onRemoteMetadataUpdated() {
    if (_ref.read(authProvider).isAuthenticated) {
      loadTransactions();
    }
  }

  Future<void> loadUndoAction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('last_undo_action');
      if (jsonStr != null) {
        _lastUndoAction = UndoAction.fromJson(jsonDecode(jsonStr));
      }
    } catch (e) {
      print("Error loading undo action: $e");
    }
  }

  Future<void> _setUndoAction(UndoAction action) async {
    _lastUndoAction = action;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_undo_action', jsonEncode(action.toJson()));
    } catch (e) {
      print("Error saving undo action: $e");
    }
  }

  Future<void> _clearUndoAction() async {
    _lastUndoAction = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_undo_action');
    } catch (e) {
      print("Error clearing undo action: $e");
    }
  }

  Future<void> loadTransactions() async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      
      // Make sure categories are loaded first or load them if empty
      var activeCategories = _ref.read(categoriesProvider);
      if (activeCategories.isEmpty) {
        await _ref.read(categoriesProvider.notifier).loadCategories();
        activeCategories = _ref.read(categoriesProvider);
      }
      final activeCategoryIds = activeCategories.map((c) => c.id).toSet();

      final list = await pbService.fetchTransactions();
      final filteredList = list.where((tx) {
        if (tx.type == TransactionType.transfer) {
          return activeCategoryIds.contains(tx.sourceCategory) ||
              activeCategoryIds.contains(tx.destinationCategory);
        }
        if (tx.category != null) {
          return activeCategoryIds.contains(tx.category);
        }
        return true; // Inbox/pending
      }).toList();

      state = filteredList;

      _setupRealtimeSubscription();
    } catch (e) {
      print("Error loading transactions: $e");
    }
  }

  void _setupRealtimeSubscription() async {
    await _subscription?.cancel();
    final pbService = _ref.read(pbServiceProvider);
    await pbService.unsubscribeTransactions();

    await pbService.subscribeTransactions((event) {
      final record = event.record;
      if (record == null) return;

      final json = record.toJson();
      final updatedTx = TransactionModel.fromJson(json);

      // Filter: does it belong to the active budget?
      final activeCategories = _ref.read(categoriesProvider);
      final activeCategoryIds = activeCategories.map((c) => c.id).toSet();

      final belongsToActiveBudget = () {
        if (updatedTx.type == TransactionType.transfer) {
          return activeCategoryIds.contains(updatedTx.sourceCategory) ||
              activeCategoryIds.contains(updatedTx.destinationCategory);
        }
        if (updatedTx.category != null) {
          return activeCategoryIds.contains(updatedTx.category);
        }
        return true; // Inbox/pending
      }();

      if (!belongsToActiveBudget) return;

      if (event.action == 'create') {
        if (!state.any((tx) => tx.id == updatedTx.id)) {
          state = [updatedTx, ...state]..sort((a, b) => b.date.compareTo(a.date));
        }
      } else if (event.action == 'update') {
        state = [
          for (final tx in state)
            if (tx.id == updatedTx.id) updatedTx else tx
        ]..sort((a, b) => b.date.compareTo(a.date));
      } else if (event.action == 'delete') {
        state = state.where((tx) => tx.id != updatedTx.id).toList();
      }
    });
  }

  void addOptimisticTransaction(TransactionModel tx) {
    state = [tx, ...state.where((t) => t.id != tx.id)]
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  // Record a basic income/expense that doesn't need deficit coverage
  Future<bool> addSimpleTransaction({
    required String description,
    required double amount,
    required TransactionType type,
    required Category category,
    DateTime? date,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final txDate = date ?? DateTime.now();

      final freshCategory = pbService.categories
              .where((c) => c.id == category.id)
              .firstOrNull ??
          _ref.read(categoriesProvider)
              .where((c) => c.id == category.id)
              .firstOrNull ??
          category;

      // Hard rule: no envelope may ever go negative
      final catCents = (freshCategory.balance * 100).round();
      final deltaCents = (amount * 100).round();
      if (catCents + deltaCents < 0) {
        return false;
      }

      // Generate the canonical record ID once so optimistic state, UndoAction,
      // PocketBaseService, and cloud sync all share the exact same ID (no duplicates).
      final txId = pbService.generateRecordId();
      final tx = TransactionModel(
        id: txId,
        description: description,
        amount: amount,
        type: type,
        category: freshCategory.id,
        date: txDate,
        user: currentUserId,
      );

      // Persist locally in memory first (zero network latency)
      final created = await pbService.logExpense(
        tx,
        freshCategory,
        syncImmediately: false,
      );

      // Ensure Riverpod states reflect the exact persisted record & balance idempotently
      addOptimisticTransaction(created);
      final updatedCat = pbService.categories
              .where((c) => c.id == freshCategory.id)
              .firstOrNull ??
          freshCategory.copyWith(balance: (catCents + deltaCents) / 100.0);
      _ref.read(categoriesProvider.notifier).updateOptimisticCategory(updatedCat);

      // categoryBalanceChanges stores the applied delta (negative for expense, positive for income),
      // which undoLastAction reverses via (currentBalance - delta).
      await _setUndoAction(UndoAction(
        description: 'Log expense to ${freshCategory.name}',
        createdTransactionIds: [created.id],
        updatedTransactions: [],
        categoryBalanceChanges: {freshCategory.id: amount},
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in addSimpleTransaction: $e");
      }));

      return true;
    } catch (e) {
      print("Error adding simple transaction: $e");
      return false;
    }
  }

  // Record a multi-category split expense, drawing specified amounts from multiple envelopes
  Future<bool> addSplitExpense({
    required String description,
    required double totalAmount,
    required List<Map<String, dynamic>> splits, // List of { 'category': Category, 'amount': double }
    DateTime? date,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final txDate = date ?? DateTime.now();

      final Map<String, Category> freshById = {
        for (final c in _ref.read(categoriesProvider)) c.id: c,
        for (final c in pbService.categories) c.id: c,
      };

      // Pre-validate aggregated draw per envelope so no envelope can ever go negative
      final Map<String, int> totalDrawCentsByCat = {};
      for (final split in splits) {
        final cat = split['category'] as Category;
        final amt = (split['amount'] as num).toDouble();
        final amtCents = (amt * 100).round();
        if (amtCents <= 0) continue;
        totalDrawCentsByCat[cat.id] = (totalDrawCentsByCat[cat.id] ?? 0) + amtCents;
      }
      if (totalDrawCentsByCat.isEmpty) return false;

      for (final entry in totalDrawCentsByCat.entries) {
        final freshCat = freshById[entry.key];
        if (freshCat == null) return false;
        final availCents = (freshCat.balance * 100).round();
        if (availCents < entry.value) {
          return false;
        }
      }

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};
      final catNotifier = _ref.read(categoriesProvider.notifier);

      for (final split in splits) {
        final rawCat = split['category'] as Category;
        final amt = (split['amount'] as num).toDouble();
        final amtCents = (amt * 100).round();
        if (amtCents <= 0) continue;
        final normalizedAmt = amtCents / 100.0;

        final freshCat = freshById[rawCat.id] ?? rawCat;
        final desc = splits.length > 1
            ? (description.isNotEmpty ? '$description (${freshCat.name})' : freshCat.name)
            : (description.isNotEmpty ? description : 'Expense');

        final txId = pbService.generateRecordId();
        final tx = TransactionModel(
          id: txId,
          description: desc,
          amount: -normalizedAmt,
          type: TransactionType.expense,
          category: freshCat.id,
          date: txDate,
          user: currentUserId,
        );

        final created = await pbService.createTransaction(tx, syncImmediately: false);
        createdTxIds.add(created.id);
        addOptimisticTransaction(created);

        final newCents = (freshCat.balance * 100).round() - amtCents;
        final updatedCat = freshCat.copyWith(
          balance: newCents < 0 ? 0.0 : newCents / 100.0,
        );
        await pbService.updateCategory(updatedCat, syncImmediately: false);
        freshById[freshCat.id] = updatedCat;
        catNotifier.updateOptimisticCategory(updatedCat);

        balanceChanges[freshCat.id] =
            (((balanceChanges[freshCat.id] ?? 0.0) * 100).round() - amtCents) / 100.0;
      }

      await _setUndoAction(UndoAction(
        description: 'Log split expense: $description',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in addSplitExpense: $e");
      }));

      return true;
    } catch (e) {
      print("Error logging split expense: $e");
      return false;
    }
  }

  // Record an expense and cover its deficit by transferring from other categories first
  Future<bool> addExpenseWithCoverage({
    required String description,
    required double amount, // positive value, e.g. 120.0
    required Category category,
    required Map<Category, double> coverages, // e.g. { VacationCategory: 20.0 }
    DateTime? date,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final txDate = date ?? DateTime.now();

      final Map<String, Category> localCategories = {
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
        for (final cat in pbService.categories) cat.id: cat,
      };

      // Pre-validate that every covering source envelope and the destination envelope stay >= 0.0
      final expenseCents = (amount * 100).round();
      if (expenseCents <= 0) return false;

      final Map<String, int> sourceDrawCents = {};
      int totalCoverageCents = 0;
      for (final entry in coverages.entries) {
        final tCents = (entry.value * 100).round();
        if (tCents <= 0) continue;
        sourceDrawCents[entry.key.id] = (sourceDrawCents[entry.key.id] ?? 0) + tCents;
        totalCoverageCents += tCents;
      }
      for (final entry in sourceDrawCents.entries) {
        final src = localCategories[entry.key];
        if (src == null || (src.balance * 100).round() < entry.value) {
          return false;
        }
      }
      final destCat = localCategories[category.id] ?? category;
      if ((destCat.balance * 100).round() + totalCoverageCents < expenseCents) {
        return false;
      }

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};
      final catNotifier = _ref.read(categoriesProvider.notifier);

      for (final entry in coverages.entries) {
        final sourceCat = entry.key;
        final transferCents = (entry.value * 100).round();
        if (transferCents <= 0) continue;
        final transferAmount = transferCents / 100.0;

        final freshSource = localCategories[sourceCat.id] ?? sourceCat;
        final freshDest = localCategories[category.id] ?? category;

        final transferTx = TransactionModel(
          id: pbService.generateRecordId(),
          description: 'Cover deficit for ${freshDest.name}',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: freshSource.id,
          destinationCategory: freshDest.id,
          date: txDate,
          user: currentUserId,
        );

        final createdTransfer = await pbService.logTransfer(
          transferTx,
          freshSource,
          freshDest,
          syncImmediately: false,
        );
        createdTxIds.add(createdTransfer.id);
        addOptimisticTransaction(createdTransfer);

        final updatedSource = freshSource.copyWith(
          balance: ((freshSource.balance * 100).round() - transferCents) / 100.0,
        );
        final updatedDest = freshDest.copyWith(
          balance: ((freshDest.balance * 100).round() + transferCents) / 100.0,
        );
        localCategories[freshSource.id] = updatedSource;
        localCategories[freshDest.id] = updatedDest;
        catNotifier.updateOptimisticCategory(updatedSource);
        catNotifier.updateOptimisticCategory(updatedDest);

        balanceChanges[freshSource.id] =
            (((balanceChanges[freshSource.id] ?? 0.0) * 100).round() - transferCents) / 100.0;
        balanceChanges[freshDest.id] =
            (((balanceChanges[freshDest.id] ?? 0.0) * 100).round() + transferCents) / 100.0;
      }

      final freshDestCategory = localCategories[category.id] ?? category;
      final expenseTx = TransactionModel(
        id: pbService.generateRecordId(),
        description: description,
        amount: -(expenseCents / 100.0),
        type: TransactionType.expense,
        category: freshDestCategory.id,
        date: txDate,
        user: currentUserId,
      );
      final createdExpense = await pbService.logExpense(
        expenseTx,
        freshDestCategory,
        syncImmediately: false,
      );
      createdTxIds.add(createdExpense.id);
      addOptimisticTransaction(createdExpense);

      final finalDest = pbService.categories
              .where((c) => c.id == freshDestCategory.id)
              .firstOrNull ??
          freshDestCategory.copyWith(
            balance: ((freshDestCategory.balance * 100).round() - expenseCents) / 100.0,
          );
      catNotifier.updateOptimisticCategory(finalDest);

      balanceChanges[freshDestCategory.id] =
          (((balanceChanges[freshDestCategory.id] ?? 0.0) * 100).round() - expenseCents) / 100.0;

      await _setUndoAction(UndoAction(
        description: 'Log expense to ${freshDestCategory.name} (with coverage)',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in addExpenseWithCoverage: $e");
      }));

      return true;
    } catch (e) {
      print("Error logging expense with coverage: $e");
      return false;
    }
  }

  // Record income and distribute it to envelopes
  Future<bool> addIncomeWithDistributions({
    required String description,
    required double amount,
    required List<Map<String, dynamic>> distributions, // List of { 'category': Category, 'amount': double }
    DateTime? date,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final Map<String, Category> freshById = {
        for (final c in _ref.read(categoriesProvider)) c.id: c,
        for (final c in pbService.categories) c.id: c,
      };
      final txDate = date ?? DateTime.now();
      final currentUserId = pbService.currentUserId ?? '';

      Category? unallocated =
          freshById.values.where((cat) => cat.isUnallocated).firstOrNull;
      if (unallocated == null) {
        final allCats = await pbService.fetchCategories();
        unallocated = allCats.where((c) => c.isUnallocated).firstOrNull;
      }
      if (unallocated == null) {
        final activeBudgetId = _ref.read(activeBudgetIdProvider);
        final newUnallocated = Category(
          id: '',
          name: 'Unallocated',
          balance: 0.0,
          colorHex: '#64748B',
          iconName: 'inbox',
          allocationType: AllocationType.manual,
          allocationValue: 0.0,
          user: currentUserId,
          budgetId: activeBudgetId,
        );
        unallocated = await pbService.createCategory(
          newUnallocated,
          syncImmediately: false,
        );
      }

      // Pre-validate that distributions never leave unallocated negative
      final amountCents = (amount * 100).round();
      int totalAllocatedCents = 0;
      final List<Map<String, dynamic>> preparedDistributions = [];
      final Map<String, double> balanceChanges = {};

      for (final dist in distributions) {
        final rawCat = dist['category'] as Category;
        final freshCat = freshById[rawCat.id] ?? rawCat;
        final amt = (dist['amount'] as num).toDouble();
        final amtCents = (amt * 100).round();
        if (amtCents <= 0 || freshCat.isUnallocated) continue;

        totalAllocatedCents += amtCents;
        balanceChanges[freshCat.id] =
            (((balanceChanges[freshCat.id] ?? 0.0) * 100).round() + amtCents) / 100.0;
        preparedDistributions.add({
          'id': pbService.generateRecordId(),
          'category': freshCat,
          'amount': amtCents / 100.0,
        });
      }

      if ((unallocated.balance * 100).round() + amountCents < totalAllocatedCents) {
        return false;
      }
      balanceChanges[unallocated.id] = (amountCents - totalAllocatedCents) / 100.0;

      final incomeTx = TransactionModel(
        id: pbService.generateRecordId(),
        description: description,
        amount: amountCents / 100.0,
        type: TransactionType.income,
        category: unallocated.id,
        date: txDate,
        user: currentUserId,
      );

      final createdTxs = await pbService.logIncomeAndDistribute(
        incomeTx,
        unallocated,
        preparedDistributions,
        syncImmediately: false,
      );

      final catNotifier = _ref.read(categoriesProvider.notifier);
      for (final tx in createdTxs) {
        addOptimisticTransaction(tx);
      }
      for (final catId in balanceChanges.keys) {
        final updated = pbService.categories.where((c) => c.id == catId).firstOrNull;
        if (updated != null) {
          catNotifier.updateOptimisticCategory(updated);
        }
      }

      await _setUndoAction(UndoAction(
        description: 'Deposit Paycheck',
        createdTransactionIds: createdTxs.map((t) => t.id).toList(),
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in addIncomeWithDistributions: $e");
      }));

      return true;
    } catch (e) {
      print("Error logging income and distributing: $e");
      return false;
    }
  }

  // Create a direct transfer between two categories
  Future<bool> addTransfer({
    required String description,
    required double amount,
    required Category source,
    required Category destination,
    DateTime? date,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final txDate = date ?? DateTime.now();

      final freshSource = pbService.categories
              .where((c) => c.id == source.id)
              .firstOrNull ??
          _ref.read(categoriesProvider)
              .where((c) => c.id == source.id)
              .firstOrNull ??
          source;
      final freshDest = pbService.categories
              .where((c) => c.id == destination.id)
              .firstOrNull ??
          _ref.read(categoriesProvider)
              .where((c) => c.id == destination.id)
              .firstOrNull ??
          destination;

      final amountCents = (amount * 100).round();
      if (amountCents <= 0) return false;
      if ((freshSource.balance * 100).round() < amountCents) {
        return false;
      }

      final transferTx = TransactionModel(
        id: pbService.generateRecordId(),
        description: description,
        amount: amountCents / 100.0,
        type: TransactionType.transfer,
        sourceCategory: freshSource.id,
        destinationCategory: freshDest.id,
        date: txDate,
        user: currentUserId,
      );

      final created = await pbService.logTransfer(
        transferTx,
        freshSource,
        freshDest,
        syncImmediately: false,
      );

      addOptimisticTransaction(created);
      final catNotifier = _ref.read(categoriesProvider.notifier);
      final updatedSource = pbService.categories
              .where((c) => c.id == freshSource.id)
              .firstOrNull ??
          freshSource.copyWith(
            balance: ((freshSource.balance * 100).round() - amountCents) / 100.0,
          );
      final updatedDest = pbService.categories
              .where((c) => c.id == freshDest.id)
              .firstOrNull ??
          freshDest.copyWith(
            balance: ((freshDest.balance * 100).round() + amountCents) / 100.0,
          );
      catNotifier.updateOptimisticCategory(updatedSource);
      catNotifier.updateOptimisticCategory(updatedDest);

      await _setUndoAction(UndoAction(
        description: 'Transfer from ${freshSource.name} to ${freshDest.name}',
        createdTransactionIds: [created.id],
        updatedTransactions: [],
        categoryBalanceChanges: {
          freshSource.id: -(amountCents / 100.0),
          freshDest.id: amountCents / 100.0,
        },
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in addTransfer: $e");
      }));

      return true;
    } catch (e) {
      print("Error creating transfer: $e");
      return false;
    }
  }

  Future<bool> distributeBalanceAndDeleteCategory({
    required Category category,
    required Map<Category, double> distributions,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final now = DateTime.now();

      final Map<String, Category> localCategories = {
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
        for (final cat in pbService.categories) cat.id: cat,
      };
      final freshCat = localCategories[category.id] ?? category;

      // Validate total distributions do not exceed source balance
      int totalDistCents = 0;
      for (final entry in distributions.entries) {
        final tCents = (entry.value * 100).round();
        if (tCents > 0) totalDistCents += tCents;
      }
      if ((freshCat.balance * 100).round() < totalDistCents) {
        return false;
      }

      final catNotifier = _ref.read(categoriesProvider.notifier);

      for (final entry in distributions.entries) {
        final targetCat = entry.key;
        final transferCents = (entry.value * 100).round();
        if (transferCents <= 0) continue;
        final transferAmount = transferCents / 100.0;

        final freshSource = localCategories[freshCat.id] ?? freshCat;
        final freshDest = localCategories[targetCat.id] ?? targetCat;

        final transferTx = TransactionModel(
          id: pbService.generateRecordId(),
          description: 'Empty balance for deleted envelope "${freshCat.name}"',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: freshSource.id,
          destinationCategory: freshDest.id,
          date: now,
          user: currentUserId,
        );

        final created = await pbService.logTransfer(
          transferTx,
          freshSource,
          freshDest,
          syncImmediately: false,
        );
        addOptimisticTransaction(created);

        final updatedSource = freshSource.copyWith(
          balance: ((freshSource.balance * 100).round() - transferCents) / 100.0,
        );
        final updatedDest = freshDest.copyWith(
          balance: ((freshDest.balance * 100).round() + transferCents) / 100.0,
        );
        localCategories[freshSource.id] = updatedSource;
        localCategories[freshDest.id] = updatedDest;
        catNotifier.updateOptimisticCategory(updatedDest);
      }

      await pbService.deleteCategory(freshCat.id, syncImmediately: false);
      catNotifier.state = catNotifier.state.where((c) => c.id != freshCat.id).toList();

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in distributeBalanceAndDeleteCategory: $e");
      }));

      return true;
    } catch (e) {
      print("Error distributing balance and deleting category: $e");
      return false;
    }
  }

  Future<bool> distributeUnallocatedFunds({
    required Category unallocatedCategory,
    required Map<Category, double> distributions,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      final now = DateTime.now();

      final Map<String, Category> localCategories = {
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
        for (final cat in pbService.categories) cat.id: cat,
      };
      final freshUnalloc = localCategories[unallocatedCategory.id] ?? unallocatedCategory;

      int totalDistCents = 0;
      for (final entry in distributions.entries) {
        final tCents = (entry.value * 100).round();
        if (tCents > 0) totalDistCents += tCents;
      }
      if ((freshUnalloc.balance * 100).round() < totalDistCents) {
        return false;
      }

      final Map<String, double> balanceChanges = {};
      final List<String> createdTxIds = [];
      final catNotifier = _ref.read(categoriesProvider.notifier);

      for (final entry in distributions.entries) {
        final targetCat = entry.key;
        final transferCents = (entry.value * 100).round();
        if (transferCents <= 0) continue;
        final transferAmount = transferCents / 100.0;

        final freshSource = localCategories[freshUnalloc.id] ?? freshUnalloc;
        final freshDest = localCategories[targetCat.id] ?? targetCat;

        final transferTx = TransactionModel(
          id: pbService.generateRecordId(),
          description: 'Allocated from Unallocated Funds',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: freshSource.id,
          destinationCategory: freshDest.id,
          date: now,
          user: currentUserId,
        );

        final created = await pbService.logTransfer(
          transferTx,
          freshSource,
          freshDest,
          syncImmediately: false,
        );
        createdTxIds.add(created.id);
        addOptimisticTransaction(created);

        final updatedSource = freshSource.copyWith(
          balance: ((freshSource.balance * 100).round() - transferCents) / 100.0,
        );
        final updatedDest = freshDest.copyWith(
          balance: ((freshDest.balance * 100).round() + transferCents) / 100.0,
        );
        localCategories[freshSource.id] = updatedSource;
        localCategories[freshDest.id] = updatedDest;
        catNotifier.updateOptimisticCategory(updatedSource);
        catNotifier.updateOptimisticCategory(updatedDest);

        balanceChanges[freshSource.id] =
            (((balanceChanges[freshSource.id] ?? 0.0) * 100).round() - transferCents) / 100.0;
        balanceChanges[freshDest.id] =
            (((balanceChanges[freshDest.id] ?? 0.0) * 100).round() + transferCents) / 100.0;
      }

      await _setUndoAction(UndoAction(
        description: 'Allocate Unallocated Funds',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      unawaited(pbService.syncVaultToCloud().catchError((e) {
        print("Background sync error in distributeUnallocatedFunds: $e");
      }));

      return true;
    } catch (e) {
      print("Error distributing unallocated funds: $e");
      return false;
    }
  }

  void _cleanup() {
    _subscription?.cancel();
    _pbService.unsubscribeTransactions();
    state = [];
  }

  @override
  void dispose() {
    _pbService.removeMetadataListener(_onRemoteMetadataUpdated);
    _cleanup();
    super.dispose();
  }

  // Allocate a single uncategorized transaction, processing any needed deficit coverages
  Future<bool> allocateTransaction({
    required TransactionModel transaction,
    required Category category,
    required Map<Category, double> coverages, // Empty if no deficit
    required bool saveRule,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';
      
      final Map<String, Category> localCategories = {
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
        for (final cat in pbService.categories) cat.id: cat,
      };

      // Pre-validate non-negative balances before mutating
      if (transaction.type != TransactionType.income) {
        final expenseCents = (transaction.amount.abs() * 100).round();
        final Map<String, int> srcDraw = {};
        int totalCoverageCents = 0;
        for (final entry in coverages.entries) {
          final tCents = (entry.value * 100).round();
          if (tCents <= 0) continue;
          srcDraw[entry.key.id] = (srcDraw[entry.key.id] ?? 0) + tCents;
          totalCoverageCents += tCents;
        }
        for (final entry in srcDraw.entries) {
          final src = localCategories[entry.key];
          if (src == null || (src.balance * 100).round() < entry.value) {
            return false;
          }
        }
        final dest = localCategories[category.id];
        if (dest == null ||
            (dest.balance * 100).round() + totalCoverageCents < expenseCents) {
          return false;
        }
      }

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};

      // 1. Process all coverages (transfers) first
      for (final entry in coverages.entries) {
        final sourceCat = entry.key;
        final transferAmount = entry.value;
        if (transferAmount <= 0) continue;

        final transferTx = TransactionModel(
          id: '',
          description: 'Cover deficit for ${category.name} (Allocation)',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: sourceCat.id,
          destinationCategory: category.id,
          date: DateTime.now(),
          user: currentUserId,
        );

        final freshSource = localCategories[sourceCat.id]!;
        final freshDest = localCategories[category.id]!;

        final createdTransfer = await pbService.logTransfer(
          transferTx,
          freshSource,
          freshDest,
          syncImmediately: false,
        );
        createdTxIds.add(createdTransfer.id);

        localCategories[sourceCat.id] = freshSource.copyWith(
          balance: freshSource.balance - transferAmount,
        );
        localCategories[category.id] = freshDest.copyWith(
          balance: freshDest.balance + transferAmount,
        );

        balanceChanges[sourceCat.id] = (balanceChanges[sourceCat.id] ?? 0.0) - transferAmount;
        balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) + transferAmount;
      }

      // 2. Update the category balance for the expense (deduct expense amount)
      final freshDestCategory = localCategories[category.id]!;
      final expenseAmount = transaction.amount.abs();
      
      double newBalance;
      double balanceDelta;
      if (transaction.type == TransactionType.income) {
        newBalance = freshDestCategory.balance + expenseAmount;
        balanceDelta = expenseAmount;
      } else {
        newBalance = freshDestCategory.balance - expenseAmount;
        balanceDelta = -expenseAmount;
      }
      
      await pbService.updateCategory(
        freshDestCategory.copyWith(balance: newBalance),
        syncImmediately: false,
      );

      balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) + balanceDelta;

      // 3. Update the transaction record with the category ID
      final updatedTx = transaction.copyWith(category: category.id);
      await pbService.updateTransaction(updatedTx, syncImmediately: false);

      // 4. Save rule if requested
      String? createdRuleId;
      if (saveRule) {
        createdRuleId = await pbService.createRule(
          pattern: transaction.description.trim().toLowerCase(),
          categoryId: category.id,
          syncImmediately: false,
        );
      }

      unawaited(pbService.syncVaultToCloud().catchError((_) {}));

      await _setUndoAction(UndoAction(
        description: 'Allocate transaction to ${category.name}',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [
          UpdatedTransactionInfo(
            transactionId: transaction.id,
            originalCategory: transaction.category,
            originalAmount: transaction.amount,
          )
        ],
        categoryBalanceChanges: balanceChanges,
        createdRuleId: createdRuleId,
      ));

      // Reload categories and transactions to keep UI synced
      await _ref.read(categoriesProvider.notifier).loadCategories();
      await loadTransactions();
      return true;
    } catch (e) {
      print("Error allocating transaction: $e");
      return false;
    }
  }

  // Allocate an uncategorized transaction across multiple categories
  Future<bool> allocateTransactionSplit({
    required TransactionModel transaction,
    required List<Map<String, dynamic>> splits, // List of { 'category': Category, 'amount': double, 'coverages': Map<Category, double> }
    required bool saveRule,
  }) async {
    try {
      final pbService = _ref.read(pbServiceProvider);
      final currentUserId = pbService.currentUserId ?? '';

      final Map<String, Category> localCategories = {
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
        for (final cat in pbService.categories) cat.id: cat,
      };

      // Pre-validate non-negative balances across all splits & coverages before mutating
      if (transaction.type != TransactionType.income) {
        final Map<String, int> simCents = {
          for (final entry in localCategories.entries)
            entry.key: (entry.value.balance * 100).round(),
        };
        for (final split in splits) {
          final category = split['category'] as Category;
          final coverages = split['coverages'] as Map<Category, double>;
          for (final entry in coverages.entries) {
            final tCents = (entry.value * 100).round();
            if (tCents <= 0) continue;
            simCents[entry.key.id] = (simCents[entry.key.id] ?? 0) - tCents;
            simCents[category.id] = (simCents[category.id] ?? 0) + tCents;
          }
        }
        for (final split in splits) {
          final category = split['category'] as Category;
          final amtCents = ((split['amount'] as num).toDouble() * 100).round();
          simCents[category.id] = (simCents[category.id] ?? 0) - amtCents;
        }
        if (simCents.values.any((c) => c < 0)) {
          return false;
        }
      }

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};

      // 1. Process all coverages (transfers) for all splits first
      for (final split in splits) {
        final category = split['category'] as Category;
        final coverages = split['coverages'] as Map<Category, double>;

        for (final entry in coverages.entries) {
          final sourceCat = entry.key;
          final transferAmount = entry.value;
          if (transferAmount <= 0) continue;

          final transferTx = TransactionModel(
            id: '',
            description: 'Cover deficit for ${category.name} (Split Allocation)',
            amount: transferAmount,
            type: TransactionType.transfer,
            sourceCategory: sourceCat.id,
            destinationCategory: category.id,
            date: DateTime.now(),
            user: currentUserId,
          );

          final freshSource = localCategories[sourceCat.id]!;
          final freshDest = localCategories[category.id]!;

          final createdTransfer = await pbService.logTransfer(
            transferTx,
            freshSource,
            freshDest,
            syncImmediately: false,
          );
          createdTxIds.add(createdTransfer.id);

          localCategories[sourceCat.id] = freshSource.copyWith(
            balance: freshSource.balance - transferAmount,
          );
          localCategories[category.id] = freshDest.copyWith(
            balance: freshDest.balance + transferAmount,
          );

          balanceChanges[sourceCat.id] = (balanceChanges[sourceCat.id] ?? 0.0) - transferAmount;
          balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) + transferAmount;
        }
      }

      // 2. Deduct/add amounts from target categories
      for (final split in splits) {
        final category = split['category'] as Category;
        final amount = split['amount'] as double;
        final freshCat = localCategories[category.id]!;
        
        double newBalance;
        double balanceDelta;
        if (transaction.type == TransactionType.income) {
          newBalance = freshCat.balance + amount;
          balanceDelta = amount;
        } else {
          newBalance = freshCat.balance - amount;
          balanceDelta = -amount;
        }

        await pbService.updateCategory(
          freshCat.copyWith(balance: newBalance),
          syncImmediately: false,
        );

        localCategories[category.id] = freshCat.copyWith(balance: newBalance);
        balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) + balanceDelta;
      }

      // 3. Update the original transaction with the first split's category and amount
      final firstSplit = splits.first;
      final firstCategory = firstSplit['category'] as Category;
      final firstAmount = firstSplit['amount'] as double;

      final updatedTx = transaction.copyWith(
        category: firstCategory.id,
        amount: transaction.type == TransactionType.income ? firstAmount : -firstAmount,
      );
      await pbService.updateTransaction(updatedTx, syncImmediately: false);

      // 4. Create new transactions for the subsequent splits
      for (int i = 1; i < splits.length; i++) {
        final split = splits[i];
        final cat = split['category'] as Category;
        final amt = split['amount'] as double;

        final newTx = TransactionModel(
          id: '',
          description: '${transaction.description} (Split)',
          amount: transaction.type == TransactionType.income ? amt : -amt,
          type: transaction.type,
          category: cat.id,
          date: transaction.date,
          user: currentUserId,
        );

        final createdTx = await pbService.createTransaction(
          newTx,
          syncImmediately: false,
        );
        createdTxIds.add(createdTx.id);
      }

      // 5. Save rule if requested (rule points to the first category chosen as default)
      String? createdRuleId;
      if (saveRule) {
        createdRuleId = await pbService.createRule(
          pattern: transaction.description.trim().toLowerCase(),
          categoryId: firstCategory.id,
          syncImmediately: false,
        );
      }

      unawaited(pbService.syncVaultToCloud().catchError((_) {}));

      await _setUndoAction(UndoAction(
        description: 'Allocate transaction split',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [
          UpdatedTransactionInfo(
            transactionId: transaction.id,
            originalCategory: transaction.category,
            originalAmount: transaction.amount,
          )
        ],
        categoryBalanceChanges: balanceChanges,
        createdRuleId: createdRuleId,
      ));

      // Reload categories and transactions
      await _ref.read(categoriesProvider.notifier).loadCategories();
      await loadTransactions();
      return true;
    } catch (e) {
      print("Error allocating transaction split: $e");
      return false;
    }
  }

  Future<bool> undoLastAction() async {
    if (_lastUndoAction == null) return false;

    final action = _lastUndoAction!;
    final pbService = _ref.read(pbServiceProvider);
    final catNotifier = _ref.read(categoriesProvider.notifier);

    try {
      // 1. Delete all transactions created in this action
      final deletedSet = action.createdTransactionIds.toSet();
      for (final txId in action.createdTransactionIds) {
        try {
          await pbService.deleteTransaction(txId, syncImmediately: false);
        } catch (e) {
          print("Error deleting transaction $txId during undo: $e");
        }
      }
      if (deletedSet.isNotEmpty) {
        state = state.where((tx) => !deletedSet.contains(tx.id)).toList();
      }

      // 2. Revert any updated transactions to their original state
      for (final info in action.updatedTransactions) {
        try {
          final tx = pbService.getTransactionById(info.transactionId);
          if (tx != null) {
            final revertedTx = tx.copyWith(
              category: info.originalCategory,
              amount: info.originalAmount,
            );
            final updated = await pbService.updateTransaction(
              revertedTx,
              clearCategory: info.originalCategory == null,
              syncImmediately: false,
            );
            addOptimisticTransaction(updated);
          }
        } catch (e) {
          print("Error reverting transaction ${info.transactionId} during undo: $e");
        }
      }

      // 3. Revert category balances (subtract the applied delta, clamped >= 0.0)
      if (action.categoryBalanceChanges.isNotEmpty) {
        final Map<String, Category> categoriesMap = {
          for (final cat in _ref.read(categoriesProvider)) cat.id: cat,
          for (final cat in pbService.categories) cat.id: cat,
        };

        for (final entry in action.categoryBalanceChanges.entries) {
          final categoryId = entry.key;
          final balanceChange = entry.value;

          final category = categoriesMap[categoryId];
          if (category != null) {
            final currentCents = (category.balance * 100).round();
            final deltaCents = (balanceChange * 100).round();
            final revertedCents = currentCents - deltaCents;
            final revertedBalance =
                revertedCents < 0 ? 0.0 : revertedCents / 100.0;
            final revertedCategory = category.copyWith(
              balance: revertedBalance,
            );
            await pbService.updateCategory(
              revertedCategory,
              syncImmediately: false,
            );
            catNotifier.updateOptimisticCategory(revertedCategory);
          }
        }
      }

      // 4. Delete the created auto-categorization rule if one was created
      if (action.createdRuleId != null) {
        try {
          await pbService.deleteRule(
            action.createdRuleId!,
            syncImmediately: false,
          );
        } catch (e) {
          print("Error deleting rule ${action.createdRuleId} during undo: $e");
        }
      }

      // 5. Clear the action state
      await _clearUndoAction();

      // 6. Sync to cloud in the background without blocking UI
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));

      return true;
    } catch (e) {
      print("Error executing undo action: $e");
      return false;
    }
  }
}

final transactionsProvider = StateNotifierProvider<TransactionsNotifier, List<TransactionModel>>((ref) {
  return TransactionsNotifier(ref);
});
