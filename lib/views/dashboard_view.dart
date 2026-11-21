import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hexcolor/hexcolor.dart';
import 'package:intl/intl.dart';
import '../providers/pb_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../providers/budgets_provider.dart';
import '../providers/shared_prefs_provider.dart';
import '../models/category.dart';
import '../models/transaction_model.dart';
import '../services/allocation_engine.dart';
import '../services/csv_export_service.dart';
import '../utils/icon_mapper.dart';
import '../utils/app_theme.dart';
import '../utils/responsive_layout.dart';
import 'transaction_ledger_view.dart';
import 'income_allocator_view.dart';
import 'transaction_creator_view.dart';
import 'settings_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

final cardFlippedProvider = StateProvider<bool>((ref) => false);

class ExpectedIncomeNotifier extends StateNotifier<double> {
  final Ref _ref;
  final String _budgetId;
  final SharedPreferences? _prefs;

  ExpectedIncomeNotifier(this._ref, this._budgetId, [this._prefs])
      : super(_readInitial(_prefs, _budgetId)) {
    if (_prefs == null) {
      _load();
    }
    _ref.read(pbServiceProvider).addMetadataListener(_load);
  }

  static double _readInitial(SharedPreferences? prefs, String budgetId) {
    if (prefs == null) return 5000.0;
    return prefs.getDouble('expected_monthly_income_$budgetId') ??
        prefs.getDouble('expected_monthly_income') ??
        5000.0;
  }

  Future<void> _load() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getDouble('expected_monthly_income_$_budgetId') ??
        prefs.getDouble('expected_monthly_income') ??
        5000.0;
  }

  Future<void> updateIncome(double value) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setDouble('expected_monthly_income_$_budgetId', value);
    state = value;
    final pbService = _ref.read(pbServiceProvider);
    pbService.markBudgetMetaDirty(_budgetId);
    if (pbService.isAuthenticated) {
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
    }
  }
}

final expectedIncomeProvider = StateNotifierProvider<ExpectedIncomeNotifier, double>((ref) {
  final budgetId = ref.watch(activeBudgetIdProvider);
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return ExpectedIncomeNotifier(ref, budgetId, prefs);
});

class PaychecksPerMonthNotifier extends StateNotifier<int> {
  final Ref _ref;
  final String _budgetId;
  final SharedPreferences? _prefs;

  PaychecksPerMonthNotifier(this._ref, this._budgetId, [this._prefs])
      : super(_readInitial(_prefs, _budgetId)) {
    if (_prefs == null) {
      _load();
    }
    _ref.read(pbServiceProvider).addMetadataListener(_load);
  }

  static int _readInitial(SharedPreferences? prefs, String budgetId) {
    if (prefs == null) return 2;
    return prefs.getInt('paychecks_per_month_$budgetId') ??
        prefs.getInt('paychecks_per_month') ??
        2;
  }

  Future<void> _load() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getInt('paychecks_per_month_$_budgetId') ??
        prefs.getInt('paychecks_per_month') ??
        2;
  }

  Future<void> updatePaychecks(int value) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setInt('paychecks_per_month_$_budgetId', value);
    state = value;
    final pbService = _ref.read(pbServiceProvider);
    pbService.markBudgetMetaDirty(_budgetId);
    if (pbService.isAuthenticated) {
      unawaited(pbService.syncVaultToCloud().catchError((_) {}));
    }
  }
}

final paychecksPerMonthProvider = StateNotifierProvider<PaychecksPerMonthNotifier, int>((ref) {
  final budgetId = ref.watch(activeBudgetIdProvider);
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {}
  return PaychecksPerMonthNotifier(ref, budgetId, prefs);
});

class DashboardView extends ConsumerWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pbService = ref.read(pbServiceProvider);
    pbService.onDuplicateTransactionsDetected = (duplicates) {
      if (!context.mounted || duplicates.isEmpty) return;
      final pair = duplicates.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Potential Duplicate Expense'),
            content: Text(
              'Two devices recorded \$${pair.localTx.amount.toStringAsFixed(2)} '
              '("${pair.localTx.description}" & "${pair.remoteTx.description}"). '
              'Are both intentional, or would you like to keep only one?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Keep Both'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await pbService.deleteTransaction(pair.remoteTx.id);
                },
                child: const Text('Keep Only One'),
              ),
            ],
          ),
        );
      });
    };

    final categories = ref.watch(categoriesProvider);
    final transactions = ref.watch(transactionsProvider);
    final isFlipped = ref.watch(cardFlippedProvider);
    final expectedIncome = ref.watch(expectedIncomeProvider);
    final paychecksPerMonth = ref.watch(paychecksPerMonthProvider);

    // Calculate metrics
    final totalPoolBalance = categories.fold<double>(0.0, (sum, cat) => sum + cat.balance);

    // Calculate total budgeted including targets, percentage and fixed checks
    double totalBudgeted = 0.0;
    for (final cat in categories) {
      if (cat.isUnallocated) continue;
      switch (cat.allocationType) {
        case AllocationType.monthlyTarget:
          totalBudgeted += cat.allocationValue;
          break;
        case AllocationType.percentCheck:
          totalBudgeted += expectedIncome * (cat.allocationValue / 100.0);
          break;
        case AllocationType.fixedCheck:
          totalBudgeted += cat.allocationValue * paychecksPerMonth;
          break;
        case AllocationType.manual:
          break;
      }
    }

    final isOverBudget = totalBudgeted > expectedIncome;
    final unallocatedCategory = categories.firstWhere(
      (cat) => cat.isUnallocated,
      orElse: () => Category(
        id: '',
        name: 'Unallocated',
        balance: 0.0,
        colorHex: '#64748B',
        iconName: 'inbox',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: '',
      ),
    );

    final otherCategories = categories.where((cat) => !cat.isUnallocated).toList();
    final currencyFormat = NumberFormat.simpleCurrency();
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: colors.scaffoldBg,
        elevation: 0,
        foregroundColor: colors.textPrimary,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: PopupMenuButton<String>(
                offset: const Offset(0, 40),
                color: colors.cardBg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onSelected: (budgetId) {
                  ref.read(activeBudgetIdProvider.notifier).setActiveBudget(budgetId);
                },
                itemBuilder: (context) {
                  final budgets = ref.watch(budgetsListProvider);
                  final activeBudgetId = ref.watch(activeBudgetIdProvider);
                  return budgets.map((b) {
                    final isActive = b.id == activeBudgetId;
                    return PopupMenuItem<String>(
                      value: b.id,
                      child: Row(
                        children: [
                          Icon(
                            isActive ? Icons.check_circle : Icons.circle_outlined,
                            color: isActive ? const Color(0xFF06B6D4) : const Color(0xFF64748B),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              b.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                color: colors.textPrimary,
                                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList();
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        () {
                          final budgets = ref.watch(budgetsListProvider);
                          final activeBudgetId = ref.watch(activeBudgetIdProvider);
                          final activeBudget = budgets.firstWhere(
                            (b) => b.id == activeBudgetId,
                            orElse: () => Budget(id: 'budget_1', name: 'My Budget'),
                          );
                          return activeBudget.name;
                        }(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: colors.iconSecondary,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.edit_outlined, size: 16, color: colors.iconMuted),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                final budgets = ref.read(budgetsListProvider);
                final activeBudgetId = ref.read(activeBudgetIdProvider);
                final activeBudget = budgets.firstWhere(
                  (b) => b.id == activeBudgetId,
                  orElse: () => Budget(id: 'budget_1', name: 'My Budget'),
                );
                _showRenameBudgetDialog(context, ref, activeBudgetId, activeBudget.name);
              },
              tooltip: 'Rename budget',
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.history_outlined, color: colors.iconPrimary),
            tooltip: 'Transaction History',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TransactionLedgerView()),
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: colors.iconPrimary),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsView()),
              );
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Gradient decoration
          Positioned(
            top: -50,
            left: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withOpacity(0.08),
                    blurRadius: 100.0,
                    spreadRadius: 50.0,
                  ),
                ],
              ),
            ),
          ),

          RefreshIndicator(
            onRefresh: () async {
              await ref.read(pbServiceProvider).pullFromCloud(notifyChanges: true);
              await ref.read(categoriesProvider.notifier).loadCategories();
              await ref.read(transactionsProvider.notifier).loadTransactions();
            },
            color: colors.primary,
            backgroundColor: colors.cardBg,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
                final columns = ResponsiveBreakpoints.envelopeColumns(constraints.maxWidth);
                final maxContentWidth = columns >= 3 ? 1120.0 : 900.0;

                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.all(isNarrow ? 12.0 : 20.0),
                  child: ResponsiveCenter(
                    maxWidth: maxContentWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                  if (ref.watch(pbServiceProvider).isBudgetReadOnly(ref.watch(activeBudgetIdProvider)))
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.45)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.visibility_outlined, color: Color(0xFFF59E0B), size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'View-Only Shared Budget — Live updates enabled, editing disabled.',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colors.isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Total Cash Pool Card (Tappable to toggle view)
                  GestureDetector(
                    onTap: () {
                      ref.read(cardFlippedProvider.notifier).state = !isFlipped;
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: isFlipped
                            ? LinearGradient(
                                colors: isOverBudget
                                    ? [const Color(0xFFEF4444), const Color(0xFFB91C1C)] // Premium Reds
                                    : [const Color(0xFF10B981), const Color(0xFF047857)], // Premium Greens
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : const LinearGradient(
                                colors: [Color(0xFF6366F1), Color(0xFF4F46E5)], // Indigo gradients
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: (isFlipped
                                    ? (isOverBudget ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                                    : const Color(0xFF6366F1))
                                .withOpacity(0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return FadeTransition(opacity: animation, child: child);
                        },
                        child: isFlipped
                            ? Column(
                                key: const ValueKey('flipped'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'BUDGET VS EXPECTED',
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white.withOpacity(0.8),
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      const Icon(Icons.analytics_outlined, color: Colors.white70),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'EXPECTED INCOME',
                                              style: GoogleFonts.inter(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white.withOpacity(0.8),
                                                letterSpacing: 1.0,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              children: [
                                                Text(
                                                  currencyFormat.format(expectedIncome),
                                                  style: GoogleFonts.outfit(
                                                    fontSize: 20,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                GestureDetector(
                                                  onTap: () {
                                                    final paychecks = ref.read(paychecksPerMonthProvider);
                                                    _showEditExpectedIncomeDialog(context, ref, expectedIncome, paychecks);
                                                  },
                                                  child: const Icon(
                                                    Icons.edit,
                                                    size: 14,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        width: 1,
                                        height: 40,
                                        color: Colors.white.withOpacity(0.2),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'AMOUNT BUDGETED',
                                              style: GoogleFonts.inter(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white.withOpacity(0.8),
                                                letterSpacing: 1.0,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              currencyFormat.format(totalBudgeted),
                                              style: GoogleFonts.outfit(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : Column(
                                key: const ValueKey('default'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'TOTAL CASH POOL',
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white.withOpacity(0.8),
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      const Icon(Icons.wallet, color: Colors.white70),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      currencyFormat.format(totalPoolBalance),
                                      style: GoogleFonts.outfit(
                                        fontSize: 36,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Unallocated Funds Card
                  GestureDetector(
                    onTap: () {
                      _showAllocateUnallocatedFundsModal(context, ref, unallocatedCategory);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.cardBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: colors.border,
                        ),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF64748B).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              IconMapper.getIcon(unallocatedCategory.iconName),
                              color: const Color(0xFF94A3B8),
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Unallocated Funds',
                                  style: GoogleFonts.outfit(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                Text(
                                  'Ready to distribute',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            currencyFormat.format(unallocatedCategory.balance),
                            style: GoogleFonts.outfit(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: unallocatedCategory.balance > 0
                                  ? const Color(0xFF10B981) // Emerald
                                  : colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Envelopes Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Budget Envelopes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: isNarrow ? 18 : 20,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showAddCategoryModal(context, ref),
                        icon: const Icon(Icons.add, size: 18, color: Color(0xFF06B6D4)),
                        label: Text(
                          isNarrow ? 'New' : 'New Envelope',
                          style: GoogleFonts.inter(
                            color: const Color(0xFF06B6D4),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // List / Responsive Grid of Category Envelopes
                  if (otherCategories.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        children: [
                          Icon(Icons.folder_open, size: 48, color: const Color(0xFF475569)),
                          const SizedBox(height: 12),
                          Text(
                            'No envelopes created yet.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(color: const Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap "New Envelope" to get started.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(color: const Color(0xFF475569), fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  else if (columns >= 2)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: otherCategories.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        mainAxisExtent: 144,
                      ),
                      itemBuilder: (context, index) {
                        final cat = otherCategories[index];
                        return _buildCategoryCard(
                          context,
                          ref,
                          cat,
                          transactions,
                          isGrid: true,
                        );
                      },
                    )
                  else
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: otherCategories.length,
                      onReorder: (oldIndex, newIndex) {
                        ref.read(categoriesProvider.notifier).reorderCategories(oldIndex, newIndex);
                      },
                      itemBuilder: (context, index) {
                        final cat = otherCategories[index];
                        return _buildCategoryCard(context, ref, cat, transactions);
                      },
                    ),
                ],
              ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
            return ResponsiveCenter(
              maxWidth: 680,
              padding: EdgeInsets.fromLTRB(isNarrow ? 12 : 16, 0, isNarrow ? 12 : 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const IncomeAllocatorView()),
                        );
                      },
                      icon: Icon(Icons.add_card, size: isNarrow ? 18 : 20),
                      label: const Text(
                        'Add Income',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981), // Emerald
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: isNarrow ? 8 : 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: isNarrow ? 8 : 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const TransactionCreatorView()),
                        );
                      },
                      icon: Icon(Icons.payments_outlined, size: isNarrow ? 18 : 20),
                      label: const Text(
                        'Log Expense',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1), // Indigo
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: isNarrow ? 8 : 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Category Envelope Card Builder ---
  Widget _buildCategoryCard(
      BuildContext context, WidgetRef ref, Category cat, List<TransactionModel> transactions,
      {bool isGrid = false}) {
    final currencyFormat = NumberFormat.simpleCurrency();
    final color = HexColor(cat.colorHex);
    final colors = AppColors.of(context);
    final expectedIncome = ref.watch(expectedIncomeProvider);
    final paychecksPerMonth = ref.watch(paychecksPerMonthProvider);

    final progressResult = CsvExportService.calculateEnvelopeProgress(
      category: cat,
      transactions: transactions,
      expectedIncome: expectedIncome,
      paychecksPerMonth: paychecksPerMonth,
    );
    final progress = progressResult.progressBarValue;
    final progressLabel = progressResult.progressLabel;
    final percentLeft = progressResult.percentLeft;
    return Container(
      key: ValueKey(cat.id),
      margin: isGrid ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TransactionLedgerView(filterCategoryId: cat.id),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        IconMapper.getIcon(cat.iconName),
                        color: color,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cat.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: colors.isDark
                                  ? const Color(0xFF334155).withValues(alpha: 0.85)
                                  : const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: colors.isDark
                                    ? const Color(0xFF475569)
                                    : const Color(0xFFCBD5E1),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              _getAllocationRuleLabel(cat),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: colors.isDark
                                    ? const Color(0xFFF1F5F9)
                                    : const Color(0xFF1E293B),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      currencyFormat.format(cat.balance),
                      style: GoogleFonts.outfit(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.edit_outlined,
                        color: colors.iconMuted,
                        size: 18,
                      ),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        _showAddCategoryModal(context, ref, existingCategory: cat);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: colors.surfaceSecondary,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),

                // Progress Label
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        progressLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$percentLeft% left',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getAllocationRuleLabel(Category cat) {
    switch (cat.allocationType) {
      case AllocationType.percentCheck:
        return '${cat.allocationValue.toStringAsRegExp()}% of Check';
      case AllocationType.fixedCheck:
        final val = cat.allocationValue.truncateToDouble() == cat.allocationValue
            ? cat.allocationValue.toInt().toString()
            : cat.allocationValue.toStringAsFixed(2);
        return '\$$val Per Check';
      case AllocationType.monthlyTarget:
        final val = cat.allocationValue.truncateToDouble() == cat.allocationValue
            ? cat.allocationValue.toInt().toString()
            : cat.allocationValue.toStringAsFixed(2);
        return '\$$val/mo Target';
      case AllocationType.manual:
        return 'Manual';
    }
  }

  // --- Add/Edit Category Dialog ---
  void _showAddCategoryModal(BuildContext context, WidgetRef ref, {Category? existingCategory}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.of(context).modalBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return _CategoryFormModal(existingCategory: existingCategory);
      },
    );
  }

  void _showAllocateUnallocatedFundsModal(BuildContext context, WidgetRef ref, Category unallocatedCategory) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.of(context).modalBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return _AllocateUnallocatedFundsModal(unallocatedCategory: unallocatedCategory);
      },
    );
  }

  void _showEditExpectedIncomeDialog(BuildContext context, WidgetRef ref, double currentIncome, int currentPaychecks) {
    final incomeController = TextEditingController(text: currentIncome.toStringAsFixed(2));
    final paychecksController = TextEditingController(text: currentPaychecks.toString());
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: colors.cardBg,
          title: Text(
            'Monthly Income Settings',
            style: GoogleFonts.outfit(
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: incomeController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: colors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Expected Monthly Income',
                  hintText: 'e.g. 5000.00',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: paychecksController,
                keyboardType: TextInputType.number,
                style: TextStyle(color: colors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Paychecks per Month',
                  hintText: 'e.g. 2',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
              ),
              onPressed: () {
                final incomeVal = double.tryParse(incomeController.text.trim());
                final paychecksVal = int.tryParse(paychecksController.text.trim());
                if (incomeVal != null && incomeVal >= 0 && paychecksVal != null && paychecksVal > 0) {
                  ref.read(expectedIncomeProvider.notifier).updateIncome(incomeVal);
                  ref.read(paychecksPerMonthProvider.notifier).updatePaychecks(paychecksVal);
                  Navigator.pop(context);
                }
              },
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showRenameBudgetDialog(BuildContext context, WidgetRef ref, String budgetId, String currentName) {
    final controller = TextEditingController(text: currentName);
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (context) {
        bool isSaving = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: colors.cardBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                'Rename Budget',
                style: GoogleFonts.outfit(color: colors.textPrimary, fontWeight: FontWeight.bold),
              ),
              content: TextField(
                controller: controller,
                style: GoogleFonts.inter(color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Enter new budget name',
                  hintStyle: TextStyle(color: colors.textMuted),
                ),
                autofocus: true,
                enabled: !isSaving,
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  child: Text('Cancel', style: GoogleFonts.inter(color: colors.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: isSaving ? null : () async {
                    final newName = controller.text.trim();
                    if (newName.isNotEmpty) {
                      setState(() {
                        isSaving = true;
                      });
                      try {
                        await ref.read(budgetsListProvider.notifier).renameBudget(budgetId, newName);
                        if (context.mounted) Navigator.pop(context);
                      } finally {
                        if (context.mounted) {
                          setState(() {
                            isSaving = false;
                          });
                        }
                      }
                    }
                  },
                  child: isSaving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text('Save', style: GoogleFonts.inter(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// --- Category Form Modal Widget ---
class _CategoryFormModal extends ConsumerStatefulWidget {
  final Category? existingCategory;
  const _CategoryFormModal({this.existingCategory});

  @override
  ConsumerState<_CategoryFormModal> createState() => _CategoryFormModalState();
}

class _CategoryFormModalState extends ConsumerState<_CategoryFormModal> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _balanceController;
  late TextEditingController _ruleValueController;
  
  late String _selectedColorHex;
  late String _selectedIcon;
  late AllocationType _selectedRule;
  bool _isSaving = false;

  final List<String> _colors = [
    '#6366F1', // Indigo
    '#06B6D4', // Cyan
    '#10B981', // Emerald
    '#F59E0B', // Amber
    '#EF4444', // Red
    '#EC4899', // Pink
    '#8B5CF6', // Purple
    '#14B8A6', // Teal
  ];

  final List<String> _icons = IconMapper.getAvailableIcons();

  @override
  void initState() {
    super.initState();
    final cat = widget.existingCategory;
    
    _nameController = TextEditingController(text: cat?.name ?? '');
    _balanceController = TextEditingController(text: cat?.balance.toString() ?? '0.0');
    _ruleValueController = TextEditingController(text: cat?.allocationValue.toString() ?? '0.0');

    _selectedColorHex = cat?.colorHex ?? _colors.first;
    _selectedIcon = cat?.iconName ?? _icons.first;
    _selectedRule = cat?.allocationType ?? AllocationType.manual;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _balanceController.dispose();
    _ruleValueController.dispose();
    super.dispose();
  }

  void _save() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final balance = double.parse(_balanceController.text);
    final ruleValue = double.parse(_ruleValueController.text);

    final notifier = ref.read(categoriesProvider.notifier);
    bool success;

    setState(() {
      _isSaving = true;
    });

    try {
      if (widget.existingCategory != null) {
        final updated = widget.existingCategory!.copyWith(
          name: name,
          balance: balance,
          colorHex: _selectedColorHex,
          iconName: _selectedIcon,
          allocationType: _selectedRule,
          allocationValue: ruleValue,
        );
        success = await notifier.editCategory(updated);
      } else {
        final created = await notifier.addCategory(
          name: name,
          balance: balance,
          colorHex: _selectedColorHex,
          iconName: _selectedIcon,
          allocationType: _selectedRule,
          allocationValue: ruleValue,
        );
        success = created != null;
      }

      if (mounted) {
        if (success) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.existingCategory != null
                  ? 'Envelope updated!'
                  : 'Envelope created!'),
              backgroundColor: Colors.teal,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to save envelope. Try again.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.existingCategory != null;
    final colors = AppColors.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isEditing ? 'Edit Envelope' : 'New Envelope',
                    style: GoogleFonts.outfit(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (isEditing && !widget.existingCategory!.isUnallocated)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () async {
                        final balance = widget.existingCategory!.balance;
                        if (balance > 0) {
                          _showDeleteCategoryDistributionModal(context, ref, widget.existingCategory!);
                        } else {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: colors.cardBg,
                              title: Text('Delete Envelope', style: GoogleFonts.outfit(color: colors.textPrimary)),
                              content: Text(
                                'Are you sure you want to delete "${widget.existingCategory!.name}"?',
                                style: GoogleFonts.inter(color: colors.textSecondary),
                              ),
                              actions: [
                                TextButton(
                                  child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
                                  onPressed: () => Navigator.pop(context, false),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                  child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                  onPressed: () => Navigator.pop(context, true),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && mounted) {
                            final success = await ref
                                .read(categoriesProvider.notifier)
                                .removeCategory(widget.existingCategory!.id);
                            if (success && mounted) {
                              Navigator.pop(context); // Close sheet
                            }
                          }
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Name Field
              TextFormField(
                controller: _nameController,
                enabled: widget.existingCategory?.isUnallocated != true, // Disable for system Unallocated category
                style: GoogleFonts.inter(color: colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Envelope Name',
                  labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                  ),
                  filled: true,
                  fillColor: colors.inputFill,
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Name is required';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Balance Field (If editing, let them modify it directly, but note that it keeps total balanced)
              TextFormField(
                controller: _balanceController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: GoogleFonts.inter(color: colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Current Cash Balance',
                  labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                  prefixText: '\$ ',
                  prefixStyle: GoogleFonts.inter(color: colors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                  ),
                  filled: true,
                  fillColor: colors.inputFill,
                ),
                validator: (val) {
                  if (val == null || val.isEmpty) return 'Balance is required';
                  final num = double.tryParse(val);
                  if (num == null) return 'Must be a number';
                  if (num < 0) return 'Balance cannot be negative!';
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Allocation Type Dropdown
              if (widget.existingCategory?.isUnallocated != true) ...[
                DropdownButtonFormField<AllocationType>(
                  value: _selectedRule,
                  dropdownColor: colors.cardBg,
                  style: GoogleFonts.inter(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Income Allocation Rule',
                    labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                    ),
                    filled: true,
                    fillColor: colors.inputFill,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: AllocationType.manual,
                      child: Text('Manual (Distribute yourself)'),
                    ),
                    DropdownMenuItem(
                      value: AllocationType.percentCheck,
                      child: Text('Percent of incoming check (%)'),
                    ),
                    DropdownMenuItem(
                      value: AllocationType.fixedCheck,
                      child: Text('Fixed amount from check (\$)'),
                    ),
                    DropdownMenuItem(
                      value: AllocationType.monthlyTarget,
                      child: Text('Monthly Target (\$/month)'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _selectedRule = val;
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Rule Value Field
                if (_selectedRule != AllocationType.manual)
                  TextFormField(
                    controller: _ruleValueController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: GoogleFonts.inter(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: _selectedRule == AllocationType.percentCheck
                          ? 'Percentage value (%)'
                          : 'Allocation target value (\$)',
                      labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                      prefixText: _selectedRule == AllocationType.percentCheck ? '' : '\$ ',
                      suffixText: _selectedRule == AllocationType.percentCheck ? '%' : '',
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                      ),
                      filled: true,
                      fillColor: colors.inputFill,
                    ),
                    validator: (val) {
                      if (val == null || val.isEmpty) return 'Required';
                      final num = double.tryParse(val);
                      if (num == null) return 'Must be a number';
                      if (num <= 0) return 'Must be greater than 0';
                      if (_selectedRule == AllocationType.percentCheck && num > 100) {
                        return 'Cannot exceed 100%';
                      }
                      return null;
                    },
                  ),
                const SizedBox(height: 20),
              ],

              // Color Selector
              Text(
                'Color Coding',
                style: GoogleFonts.outfit(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _colors.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final hex = _colors[index];
                    final isSelected = hex == _selectedColorHex;
                    final envelopeColor = HexColor(hex);

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedColorHex = hex;
                        });
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: envelopeColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? colors.textPrimary : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, color: Colors.white, size: 20)
                            : null,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              // Icon Selector
              Text(
                'Envelope Icon',
                style: GoogleFonts.outfit(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _icons.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final iconKey = _icons[index];
                    final isSelected = iconKey == _selectedIcon;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedIcon = iconKey;
                        });
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? HexColor(_selectedColorHex).withOpacity(0.2)
                              : colors.surfaceSecondary,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? HexColor(_selectedColorHex)
                                : colors.border,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          IconMapper.getIcon(iconKey),
                          color: isSelected ? HexColor(_selectedColorHex) : colors.iconMuted,
                          size: 22,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 32),

              // Action Buttons
              ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: HexColor(_selectedColorHex),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        isEditing ? 'Save Changes' : 'Create Envelope',
                        style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteCategoryDistributionModal(BuildContext context, WidgetRef ref, Category category) async {
    final colors = AppColors.of(context);
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.modalBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return _DeleteCategoryDistributionModal(category: category);
      },
    );
    if (deleted == true && mounted) {
      Navigator.pop(context); // Close the edit category form sheet
    }
  }
}

class _DeleteCategoryDistributionModal extends ConsumerStatefulWidget {
  final Category category;

  const _DeleteCategoryDistributionModal({required this.category});

  @override
  ConsumerState<_DeleteCategoryDistributionModal> createState() =>
      _DeleteCategoryDistributionModalState();
}

class _DeleteCategoryDistributionModalState
    extends ConsumerState<_DeleteCategoryDistributionModal> {
  final Map<String, TextEditingController> _controllers = {};
  double _remaining = 0.0;
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.category.balance;
    final otherCats = ref
        .read(categoriesProvider)
        .where((c) => c.id != widget.category.id)
        .toList();

    for (final cat in otherCats) {
      final controller = TextEditingController(text: '0.00');
      _controllers[cat.id] = controller;
      controller.addListener(_updateRemaining);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.removeListener(_updateRemaining);
      controller.dispose();
    }
    super.dispose();
  }

  void _updateRemaining() {
    double totalDistributed = 0.0;
    for (final controller in _controllers.values) {
      final val = double.tryParse(controller.text) ?? 0.0;
      totalDistributed += val;
    }
    setState(() {
      _remaining = ((widget.category.balance - totalDistributed) * 100).roundToDouble() / 100;
    });
  }

  void _distributeAllTo(String categoryId) {
    double otherDistributed = 0.0;
    _controllers.forEach((id, controller) {
      if (id != categoryId) {
        final val = double.tryParse(controller.text) ?? 0.0;
        otherDistributed += val;
      }
    });

    final targetVal = ((widget.category.balance - otherDistributed) * 100).roundToDouble() / 100;
    if (targetVal >= 0) {
      _controllers[categoryId]?.text = targetVal.toStringAsFixed(2);
    }
  }

  void _confirmAndDelete() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_remaining != 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Remaining balance must be exactly \$0.00 to delete!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final categories = ref.read(categoriesProvider);
      final Map<Category, double> distributionsMap = {};

      _controllers.forEach((catId, controller) {
        final amount = double.tryParse(controller.text) ?? 0.0;
        if (amount > 0) {
          final targetCat = categories.firstWhere((c) => c.id == catId);
          distributionsMap[targetCat] = amount;
        }
      });

      final success = await ref
          .read(transactionsProvider.notifier)
          .distributeBalanceAndDeleteCategory(
            category: widget.category,
            distributions: distributionsMap,
          );

      if (mounted) {
        if (success) {
          Navigator.pop(context, true); // Pop distribution modal with true
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to delete envelope. Try again.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final otherCats = ref
        .watch(categoriesProvider)
        .where((c) => c.id != widget.category.id)
        .toList();
    final currencyFormat = NumberFormat.simpleCurrency();

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Distribute & Delete "${widget.category.name}"',
                style: GoogleFonts.outfit(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Before deleting, you must allocate the envelope\'s remaining balance to other active envelopes.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              
              // Status summary panel
              Container(
                decoration: BoxDecoration(
                  color: colors.surfaceSecondary,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colors.border),
                ),
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TOTAL TO DISTRIBUTE',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: colors.textMuted,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currencyFormat.format(widget.category.balance),
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'REMAINING',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: colors.textMuted,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currencyFormat.format(_remaining),
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _remaining == 0.0
                                ? const Color(0xFF10B981)
                                : const Color(0xFFEF4444),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Other Categories list
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: otherCats.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final cat = otherCats[index];
                  final controller = _controllers[cat.id];
                  final color = HexColor(cat.colorHex);

                  return Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          IconMapper.getIcon(cat.iconName),
                          color: color,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cat.name,
                              style: GoogleFonts.outfit(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                            Text(
                              'Bal: ${currencyFormat.format(cat.balance)}',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Text field for distribution amount
                      SizedBox(
                        width: 110,
                        child: TextFormField(
                          controller: controller,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.end,
                          style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 14),
                          decoration: InputDecoration(
                            prefixText: '\$',
                            prefixStyle: GoogleFonts.inter(color: colors.textSecondary, fontSize: 13),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: colors.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                            ),
                            filled: true,
                            fillColor: colors.inputFill,
                          ),
                          validator: (val) {
                            if (val == null || val.isEmpty) return 'Required';
                            final num = double.tryParse(val);
                            if (num == null) return 'Invalid';
                            if (num < 0) return 'Must be >= 0';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      // "All" button
                      TextButton(
                        onPressed: () => _distributeAllTo(cat.id),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          backgroundColor: colors.surfaceSecondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(color: colors.border),
                          ),
                        ),
                        child: Text(
                          'Max',
                          style: GoogleFonts.inter(
                            color: const Color(0xFF06B6D4),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),

              // Confirm button
              ElevatedButton(
                onPressed: (_remaining == 0.0 && !_isSaving) ? _confirmAndDelete : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  disabledBackgroundColor: const Color(0xFF475569),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white30,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Confirm & Delete Envelope',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllocateUnallocatedFundsModal extends ConsumerStatefulWidget {
  final Category unallocatedCategory;

  const _AllocateUnallocatedFundsModal({required this.unallocatedCategory});

  @override
  ConsumerState<_AllocateUnallocatedFundsModal> createState() =>
      _AllocateUnallocatedFundsModalState();
}

class _AllocateUnallocatedFundsModalState
    extends ConsumerState<_AllocateUnallocatedFundsModal> {
  final Map<String, TextEditingController> _controllers = {};
  double _totalAllocated = 0.0;
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.removeListener(_updateRemaining);
      controller.dispose();
    }
    super.dispose();
  }

  void _updateRemaining() {
    double total = 0.0;
    _controllers.forEach((catId, controller) {
      final val = double.tryParse(controller.text) ?? 0.0;
      total += val;
    });
    setState(() {
      _totalAllocated = total;
    });
  }

  double get _remainingUnallocated {
    return double.parse((widget.unallocatedCategory.balance - _totalAllocated).toStringAsFixed(2));
  }

  void _submit() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final categories = ref.read(categoriesProvider);
    final otherCats = categories.where((c) => !c.isUnallocated).toList();

    final Map<Category, double> distributions = {};
    _controllers.forEach((catId, controller) {
      final amt = double.tryParse(controller.text) ?? 0.0;
      if (amt > 0) {
        final cat = otherCats.firstWhere((c) => c.id == catId);
        distributions[cat] = amt;
      }
    });

    if (distributions.isEmpty) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final success = await ref
          .read(transactionsProvider.notifier)
          .distributeUnallocatedFunds(
            unallocatedCategory: widget.unallocatedCategory,
            distributions: distributions,
          );

      if (mounted) {
        if (success) {
          Navigator.pop(context); // Pop allocation modal
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Funds allocated successfully!'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to allocate funds. Try again.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final categories = ref.watch(categoriesProvider);
    final otherCats = categories.where((c) => !c.isUnallocated).toList();

    // Initialize/sync controllers for all non-unallocated categories
    for (final cat in otherCats) {
      if (!_controllers.containsKey(cat.id)) {
        _controllers[cat.id] = TextEditingController(text: '0.00');
        _controllers[cat.id]!.addListener(_updateRemaining);
      }
    }

    final currencyFormat = NumberFormat.simpleCurrency();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Allocate Unallocated Funds',
                style: GoogleFonts.outfit(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Distribute funds from Unallocated to your envelopes.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),

              // Status Banner
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceSecondary,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        Text(
                          'Available',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currencyFormat.format(widget.unallocatedCategory.balance),
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      width: 1,
                      height: 30,
                      color: colors.divider,
                    ),
                    Column(
                      children: [
                        Text(
                          'Remaining',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currencyFormat.format(_remainingUnallocated),
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _remainingUnallocated < 0
                                ? const Color(0xFFEF4444)
                                : (_remainingUnallocated == 0.0
                                    ? colors.textSecondary
                                    : const Color(0xFF06B6D4)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // List of other envelopes
              if (otherCats.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'No other envelopes found.',
                      style: GoogleFonts.inter(
                        color: colors.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                )
              else
                Column(
                  children: [
                    ...otherCats.map((cat) {
                      final controller = _controllers[cat.id];
                      if (controller == null) return const SizedBox.shrink();

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: HexColor(cat.colorHex).withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                IconMapper.getIcon(cat.iconName),
                                color: HexColor(cat.colorHex),
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    cat.name,
                                    style: GoogleFonts.outfit(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    'Balance: ${currencyFormat.format(cat.balance)}',
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            
                            // Max Button
                            TextButton(
                              onPressed: () {
                                final currentVal = double.tryParse(controller.text) ?? 0.0;
                                final otherAllocated = _totalAllocated - currentVal;
                                final targetVal = widget.unallocatedCategory.balance - otherAllocated;
                                if (targetVal >= 0) {
                                  controller.text = targetVal.toStringAsFixed(2);
                                }
                              },
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                'Max',
                                style: GoogleFonts.inter(
                                  color: const Color(0xFF06B6D4),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),

                            // Amount Input
                            SizedBox(
                              width: 100,
                              child: TextFormField(
                                controller: controller,
                                keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: colors.textPrimary,
                                ),
                                decoration: InputDecoration(
                                  prefixText: '\$ ',
                                  prefixStyle: GoogleFonts.inter(
                                    color: colors.textSecondary,
                                    fontSize: 13,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  isDense: true,
                                  fillColor: colors.inputFill,
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: colors.border),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                                  ),
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) return null;
                                  final num = double.tryParse(val.trim());
                                  if (num == null) return 'Invalid';
                                  if (num < 0) return '>= 0';
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),

              const SizedBox(height: 12),

              // Add Envelope option at the bottom
              TextButton.icon(
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: colors.modalBg,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    builder: (context) {
                      return const _CategoryFormModal();
                    },
                  );
                },
                icon: const Icon(Icons.add, size: 16, color: Color(0xFF6366F1)),
                label: Text(
                  'Add Envelope',
                  style: GoogleFonts.inter(
                    color: const Color(0xFF6366F1),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              ElevatedButton(
                onPressed: (_totalAllocated > 0 && _remainingUnallocated >= 0 && !_isSaving)
                    ? _submit
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  disabledBackgroundColor: const Color(0xFF475569),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white30,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Allocate Funds',
                        style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

