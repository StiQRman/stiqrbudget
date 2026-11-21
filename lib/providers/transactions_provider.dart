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

      // Optimistically update category balance in Riverpod state
      // (amount is negative for expense, positive for income)
      final catNotifier = _ref.read(categoriesProvider.notifier);
      catNotifier.updateOptimisticBalances({category.id: amount});

      final optTx = TransactionModel(
        id: 'opt_${DateTime.now().microsecondsSinceEpoch}',
        description: description,
        amount: amount,
        type: type,
        category: category.id,
        date: txDate,
        user: currentUserId,
      );
      addOptimisticTransaction(optTx);

      _setUndoAction(UndoAction(
        description: 'Log expense to ${category.name}',
        createdTransactionIds: [optTx.id],
        updatedTransactions: [],
        categoryBalanceChanges: {category.id: -amount},
      ));

      // Asynchronously persist locally & trigger cloud sync
      unawaited(() async {
        try {
          final tx = TransactionModel(
            id: '',
            description: description,
            amount: amount,
            type: type,
            category: category.id,
            date: optTx.date,
            user: currentUserId,
          );
          await pbService.logExpense(tx, category, syncImmediately: false);
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in addSimpleTransaction: $e");
        }
      }());

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

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};
      final now = DateTime.now();
      final txDate = date ?? now;

      // 1. Optimistic updates immediately to in-memory state
      for (final split in splits) {
        final cat = split['category'] as Category;
        final amt = (split['amount'] as num).toDouble();
        if (amt <= 0) continue;

        balanceChanges[cat.id] = (balanceChanges[cat.id] ?? 0.0) - amt;

        final desc = splits.length > 1
            ? (description.isNotEmpty ? '$description (${cat.name})' : cat.name)
            : (description.isNotEmpty ? description : 'Expense');

        final optTx = TransactionModel(
          id: 'opt_${now.microsecondsSinceEpoch}_${cat.id}',
          description: desc,
          amount: -amt,
          type: TransactionType.expense,
          category: cat.id,
          date: txDate,
          user: currentUserId,
        );
        createdTxIds.add(optTx.id);
        addOptimisticTransaction(optTx);
      }

      _ref.read(categoriesProvider.notifier).updateOptimisticBalances(balanceChanges);

      _setUndoAction(UndoAction(
        description: 'Log split expense: $description',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      // 2. Background persistence & cloud sync
      unawaited(() async {
        try {
          for (final split in splits) {
            final cat = split['category'] as Category;
            final amt = (split['amount'] as num).toDouble();
            if (amt <= 0) continue;

            final desc = splits.length > 1
                ? (description.isNotEmpty ? '$description (${cat.name})' : cat.name)
                : (description.isNotEmpty ? description : 'Expense');

            final tx = TransactionModel(
              id: '',
              description: desc,
              amount: -amt, // Negative for expense
              type: TransactionType.expense,
              category: cat.id,
              date: txDate,
              user: currentUserId,
            );

            await pbService.createTransaction(tx, syncImmediately: false);

            final freshCat = pbService.categories.firstWhere(
              (c) => c.id == cat.id,
              orElse: () => cat,
            );
            final updatedCat = freshCat.copyWith(
              balance: (((freshCat.balance * 100).round() - (amt * 100).round()) / 100.0),
            );
            await pbService.updateCategory(updatedCat, syncImmediately: false);
          }
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in addSplitExpense: $e");
        }
      }());

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
      final now = DateTime.now();
      final txDate = date ?? now;

      final List<String> createdTxIds = [];
      final Map<String, double> balanceChanges = {};

      // 1. Optimistic updates
      for (final entry in coverages.entries) {
        final sourceCat = entry.key;
        final transferAmount = entry.value;
        if (transferAmount <= 0) continue;

        balanceChanges[sourceCat.id] = (balanceChanges[sourceCat.id] ?? 0.0) - transferAmount;
        balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) + transferAmount;

        final optTransfer = TransactionModel(
          id: 'opt_${now.microsecondsSinceEpoch}_cover_${sourceCat.id}',
          description: 'Cover deficit for ${category.name}',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: sourceCat.id,
          destinationCategory: category.id,
          date: txDate,
          user: currentUserId,
        );
        createdTxIds.add(optTransfer.id);
        addOptimisticTransaction(optTransfer);
      }

      balanceChanges[category.id] = (balanceChanges[category.id] ?? 0.0) - amount;
      final optExpense = TransactionModel(
        id: 'opt_${now.microsecondsSinceEpoch}_exp',
        description: description,
        amount: -amount,
        type: TransactionType.expense,
        category: category.id,
        date: txDate,
        user: currentUserId,
      );
      createdTxIds.add(optExpense.id);
      addOptimisticTransaction(optExpense);

      _ref.read(categoriesProvider.notifier).updateOptimisticBalances(balanceChanges);

      _setUndoAction(UndoAction(
        description: 'Log expense to ${category.name} (with coverage)',
        createdTransactionIds: createdTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      // 2. Background persistence
      unawaited(() async {
        try {
          final Map<String, Category> localCategories = {
            for (final cat in _ref.read(categoriesProvider)) cat.id: cat
          };

          for (final entry in coverages.entries) {
            final sourceCat = entry.key;
            final transferAmount = entry.value;
            if (transferAmount <= 0) continue;

            final transferTx = TransactionModel(
              id: '',
              description: 'Cover deficit for ${category.name}',
              amount: transferAmount,
              type: TransactionType.transfer,
              sourceCategory: sourceCat.id,
              destinationCategory: category.id,
              date: txDate,
              user: currentUserId,
            );

            final freshSource = localCategories[sourceCat.id] ?? sourceCat;
            final freshDest = localCategories[category.id] ?? category;

            await pbService.logTransfer(transferTx, freshSource, freshDest, syncImmediately: false);

            localCategories[sourceCat.id] = freshSource.copyWith(
              balance: freshSource.balance - transferAmount,
            );
            localCategories[category.id] = freshDest.copyWith(
              balance: freshDest.balance + transferAmount,
            );
          }

          final freshDestCategory = localCategories[category.id] ?? category;
          final expenseTx = TransactionModel(
            id: '',
            description: description,
            amount: -amount,
            type: TransactionType.expense,
            category: category.id,
            date: txDate,
            user: currentUserId,
          );
          await pbService.logExpense(expenseTx, freshDestCategory, syncImmediately: false);
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in addExpenseWithCoverage: $e");
        }
      }());

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
      final freshCategories = _ref.read(categoriesProvider);
      final now = DateTime.now();
      final txDate = date ?? now;
      final currentUserId = pbService.currentUserId ?? '';
      
      Category? unallocated = freshCategories.where((cat) => cat.isUnallocated).firstOrNull;
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

      // Calculate balances & apply optimistically
      final Map<String, double> balanceChanges = {};
      double totalAllocated = 0.0;
      final List<String> optTxIds = [];

      final optIncome = TransactionModel(
        id: 'opt_${now.microsecondsSinceEpoch}_inc',
        description: description,
        amount: amount,
        type: TransactionType.income,
        category: unallocated.id,
        date: txDate,
        user: currentUserId,
      );
      optTxIds.add(optIncome.id);
      addOptimisticTransaction(optIncome);

      for (final dist in distributions) {
        final cat = dist['category'] as Category;
        final amt = (dist['amount'] as num).toDouble();
        if (amt > 0) {
          balanceChanges[cat.id] = amt;
          totalAllocated += amt;

          final optDist = TransactionModel(
            id: 'opt_${now.microsecondsSinceEpoch}_dist_${cat.id}',
            description: 'Allocated from: $description',
            amount: amt,
            type: TransactionType.transfer,
            sourceCategory: unallocated.id,
            destinationCategory: cat.id,
            date: txDate,
            user: currentUserId,
          );
          optTxIds.add(optDist.id);
          addOptimisticTransaction(optDist);
        }
      }
      balanceChanges[unallocated.id] = amount - totalAllocated;

      _ref.read(categoriesProvider.notifier).updateOptimisticBalances(balanceChanges);

      _setUndoAction(UndoAction(
        description: 'Deposit Paycheck',
        createdTransactionIds: optTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      // Background sync
      final unallocFinal = unallocated;
      unawaited(() async {
        try {
          final incomeTx = TransactionModel(
            id: '',
            description: description,
            amount: amount,
            type: TransactionType.income,
            category: unallocFinal.id,
            date: txDate,
            user: currentUserId,
          );

          final freshDistributions = distributions.map((dist) {
            final cat = dist['category'] as Category;
            final freshCat = freshCategories.where((c) => c.id == cat.id).firstOrNull ?? cat;
            return {
              'category': freshCat,
              'amount': (dist['amount'] as num).toDouble(),
            };
          }).toList();

          await pbService.logIncomeAndDistribute(
            incomeTx,
            unallocFinal,
            freshDistributions,
            syncImmediately: false,
          );
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in addIncomeWithDistributions: $e");
        }
      }());

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
      final now = DateTime.now();
      final txDate = date ?? now;

      // 1. Optimistic updates immediately to category & transaction states
      _ref.read(categoriesProvider.notifier).updateOptimisticBalances({
        source.id: -amount,
        destination.id: amount,
      });

      final optTx = TransactionModel(
        id: 'opt_${now.microsecondsSinceEpoch}_xfer',
        description: description,
        amount: amount,
        type: TransactionType.transfer,
        sourceCategory: source.id,
        destinationCategory: destination.id,
        date: txDate,
        user: currentUserId,
      );
      addOptimisticTransaction(optTx);

      _setUndoAction(UndoAction(
        description: 'Transfer from ${source.name} to ${destination.name}',
        createdTransactionIds: [optTx.id],
        updatedTransactions: [],
        categoryBalanceChanges: {
          source.id: -amount,
          destination.id: amount,
        },
      ));

      // 2. Background persistence & sync
      unawaited(() async {
        try {
          final transferTx = TransactionModel(
            id: '',
            description: description,
            amount: amount,
            type: TransactionType.transfer,
            sourceCategory: source.id,
            destinationCategory: destination.id,
            date: txDate,
            user: currentUserId,
          );

          final freshCategories = pbService.categories;
          final freshSource = freshCategories.firstWhere(
            (c) => c.id == source.id,
            orElse: () => source,
          );
          final freshDest = freshCategories.firstWhere(
            (c) => c.id == destination.id,
            orElse: () => destination,
          );

          await pbService.logTransfer(transferTx, freshSource, freshDest, syncImmediately: false);
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in addTransfer: $e");
        }
      }());

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

      // 1. Optimistic updates
      final Map<String, double> balanceChanges = {};
      final List<String> optTxIds = [];

      for (final entry in distributions.entries) {
        final targetCat = entry.key;
        final transferAmount = entry.value;
        if (transferAmount <= 0) continue;

        balanceChanges[targetCat.id] = (balanceChanges[targetCat.id] ?? 0.0) + transferAmount;

        final optTx = TransactionModel(
          id: 'opt_${now.microsecondsSinceEpoch}_del_${targetCat.id}',
          description: 'Empty balance for deleted envelope "${category.name}"',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: category.id,
          destinationCategory: targetCat.id,
          date: now,
          user: currentUserId,
        );
        optTxIds.add(optTx.id);
        addOptimisticTransaction(optTx);
      }

      final catNotifier = _ref.read(categoriesProvider.notifier);
      catNotifier.updateOptimisticBalances(balanceChanges);
      // Remove deleted category optimistically from provider
      catNotifier.state = catNotifier.state.where((c) => c.id != category.id).toList();

      // 2. Background persistence & sync
      unawaited(() async {
        try {
          final Map<String, Category> localCategories = {
            for (final cat in pbService.categories) cat.id: cat
          };

          for (final entry in distributions.entries) {
            final targetCat = entry.key;
            final transferAmount = entry.value;
            if (transferAmount <= 0) continue;

            final transferTx = TransactionModel(
              id: '',
              description: 'Empty balance for deleted envelope "${category.name}"',
              amount: transferAmount,
              type: TransactionType.transfer,
              sourceCategory: category.id,
              destinationCategory: targetCat.id,
              date: now,
              user: currentUserId,
            );

            final freshSource = localCategories[category.id] ?? category;
            final freshDest = localCategories[targetCat.id] ?? targetCat;

            await pbService.logTransfer(transferTx, freshSource, freshDest, syncImmediately: false);

            localCategories[category.id] = freshSource.copyWith(
              balance: freshSource.balance - transferAmount,
            );
            localCategories[targetCat.id] = freshDest.copyWith(
              balance: freshDest.balance + transferAmount,
            );
          }

          await pbService.deleteCategory(category.id, syncImmediately: false);
          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in distributeBalanceAndDeleteCategory: $e");
        }
      }());

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

      // 1. Optimistic updates
      final Map<String, double> balanceChanges = {};
      final List<String> optTxIds = [];

      for (final entry in distributions.entries) {
        final targetCat = entry.key;
        final transferAmount = entry.value;
        if (transferAmount <= 0) continue;

        balanceChanges[unallocatedCategory.id] = (balanceChanges[unallocatedCategory.id] ?? 0.0) - transferAmount;
        balanceChanges[targetCat.id] = (balanceChanges[targetCat.id] ?? 0.0) + transferAmount;

        final optTx = TransactionModel(
          id: 'opt_${now.microsecondsSinceEpoch}_unalloc_${targetCat.id}',
          description: 'Allocated from Unallocated Funds',
          amount: transferAmount,
          type: TransactionType.transfer,
          sourceCategory: unallocatedCategory.id,
          destinationCategory: targetCat.id,
          date: now,
          user: currentUserId,
        );
        optTxIds.add(optTx.id);
        addOptimisticTransaction(optTx);
      }

      _ref.read(categoriesProvider.notifier).updateOptimisticBalances(balanceChanges);

      _setUndoAction(UndoAction(
        description: 'Allocate Unallocated Funds',
        createdTransactionIds: optTxIds,
        updatedTransactions: [],
        categoryBalanceChanges: balanceChanges,
      ));

      // 2. Background sync
      unawaited(() async {
        try {
          final Map<String, Category> localCategories = {
            for (final cat in pbService.categories) cat.id: cat
          };

          for (final entry in distributions.entries) {
            final targetCat = entry.key;
            final transferAmount = entry.value;
            if (transferAmount <= 0) continue;

            final transferTx = TransactionModel(
              id: '',
              description: 'Allocated from Unallocated Funds',
              amount: transferAmount,
              type: TransactionType.transfer,
              sourceCategory: unallocatedCategory.id,
              destinationCategory: targetCat.id,
              date: now,
              user: currentUserId,
            );

            final freshSource = localCategories[unallocatedCategory.id] ?? unallocatedCategory;
            final freshDest = localCategories[targetCat.id] ?? targetCat;

            await pbService.logTransfer(transferTx, freshSource, freshDest, syncImmediately: false);

            localCategories[unallocatedCategory.id] = freshSource.copyWith(
              balance: freshSource.balance - transferAmount,
            );
            localCategories[targetCat.id] = freshDest.copyWith(
              balance: freshDest.balance + transferAmount,
            );
          }

          await pbService.syncVaultToCloud();
        } catch (e) {
          print("Background sync error in distributeUnallocatedFunds: $e");
        }
      }());

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
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat
      };

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
        for (final cat in _ref.read(categoriesProvider)) cat.id: cat
      };

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
    
    try {
      // 1. Delete all transactions created in this action
      for (final txId in action.createdTransactionIds) {
        try {
          await pbService.deleteTransaction(txId, syncImmediately: false);
        } catch (e) {
          print("Error deleting transaction $txId during undo: $e");
        }
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
            await pbService.updateTransaction(
              revertedTx,
              clearCategory: info.originalCategory == null,
              syncImmediately: false,
            );
          }
        } catch (e) {
          print("Error reverting transaction ${info.transactionId} during undo: $e");
        }
      }

      // 3. Revert category balances (subtract the balance changes)
      if (action.categoryBalanceChanges.isNotEmpty) {
        final freshCategoriesList = await pbService.fetchCategories();
        final Map<String, Category> categoriesMap = {
          for (final cat in freshCategoriesList) cat.id: cat
        };

        for (final entry in action.categoryBalanceChanges.entries) {
          final categoryId = entry.key;
          final balanceChange = entry.value;

          final category = categoriesMap[categoryId];
          if (category != null) {
            final revertedCategory = category.copyWith(
              balance: category.balance - balanceChange,
            );
            await pbService.updateCategory(
              revertedCategory,
              syncImmediately: false,
            );
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

      unawaited(pbService.syncVaultToCloud().catchError((_) {}));

      // 5. Clear the action state
      await _clearUndoAction();

      // 6. Reload categories and transactions
      await _ref.read(categoriesProvider.notifier).loadCategories();
      await loadTransactions();
      
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
