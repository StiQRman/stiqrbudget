import '../models/category.dart';
import '../models/transaction_model.dart';

/// Represents a single inflow transaction into an envelope (either from paychecks or another envelope).
class FundingSourceItem {
  final String transactionId;
  final DateTime date;
  final String description;
  final double amount;
  final String? sourceCategoryId;
  final String sourceCategoryName;
  final String destinationCategoryId;
  final String destinationCategoryName;
  final bool isPaycheckAllocation; // true if from paycheck/unallocated, false if from another category

  FundingSourceItem({
    required this.transactionId,
    required this.date,
    required this.description,
    required this.amount,
    this.sourceCategoryId,
    required this.sourceCategoryName,
    required this.destinationCategoryId,
    required this.destinationCategoryName,
    required this.isPaycheckAllocation,
  });
}

/// Breakdown per individual category when multiple categories are involved in the report.
class SpendingReportCategoryBreakdown {
  final Category category;
  final double totalSpent;
  final int expenseCount;
  final double allocatedFromPaychecks;
  final double takenFromOtherCategories;
  final double reallocatedToOtherCategories;
  final List<TransactionModel> expenses;
  final List<FundingSourceItem> fundingItems;

  SpendingReportCategoryBreakdown({
    required this.category,
    required this.totalSpent,
    required this.expenseCount,
    required this.allocatedFromPaychecks,
    required this.takenFromOtherCategories,
    required this.reallocatedToOtherCategories,
    required this.expenses,
    required this.fundingItems,
  });

  double get totalFunding =>
      double.parse((allocatedFromPaychecks + takenFromOtherCategories).toStringAsFixed(2));

  double get netFlow =>
      double.parse((totalFunding - totalSpent).toStringAsFixed(2));
}

/// Aggregate output of a spending report query.
class SpendingReportResult {
  final DateTime startDate;
  final DateTime endDate;
  final Category? filterCategory;
  final String? filterDescription;

  final double totalSpent;
  final int totalExpenseCount;
  final double allocatedFromPaychecks;
  final double takenFromOtherCategories;
  final double reallocatedToOtherCategories;

  final List<TransactionModel> matchingExpenses;
  final List<FundingSourceItem> fundingItems;
  final List<SpendingReportCategoryBreakdown> categoryBreakdowns;

  SpendingReportResult({
    required this.startDate,
    required this.endDate,
    this.filterCategory,
    this.filterDescription,
    required this.totalSpent,
    required this.totalExpenseCount,
    required this.allocatedFromPaychecks,
    required this.takenFromOtherCategories,
    required this.reallocatedToOtherCategories,
    required this.matchingExpenses,
    required this.fundingItems,
    required this.categoryBreakdowns,
  });

  double get totalFunding =>
      double.parse((allocatedFromPaychecks + takenFromOtherCategories).toStringAsFixed(2));

  double get netBalance =>
      double.parse((totalFunding - totalSpent).toStringAsFixed(2));

  double get averageExpense => totalExpenseCount > 0
      ? double.parse((totalSpent / totalExpenseCount).toStringAsFixed(2))
      : 0.0;
}

class SpendingReportEngine {
  /// Validates the report requirements:
  /// - Date range is required (startDate and endDate must not be null).
  /// - Either category or description (or both) must be provided.
  static bool isValidFilter({
    required DateTime? startDate,
    required DateTime? endDate,
    required Category? category,
    required String? description,
  }) {
    if (startDate == null || endDate == null) return false;
    final hasCategory = category != null;
    final hasDescription = description != null && description.trim().isNotEmpty;
    return hasCategory || hasDescription;
  }

  /// Calculates the spending report metrics, matching expenses, and funding breakdown.
  static SpendingReportResult generateReport({
    required DateTime startDate,
    required DateTime endDate,
    Category? filterCategory,
    String? filterDescription,
    required List<Category> allCategories,
    required List<TransactionModel> allTransactions,
  }) {
    // 1. Normalize date range (start of day to end of day)
    final start = DateTime(startDate.year, startDate.month, startDate.day, 0, 0, 0);
    final end = DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59, 999);

    final cleanDesc = filterDescription?.trim().toLowerCase();
    final hasDesc = cleanDesc != null && cleanDesc.isNotEmpty;

    // Fast category lookup map
    final categoryMap = {for (final c in allCategories) c.id: c};
    final unallocatedIds = allCategories
        .where((c) => c.isUnallocated)
        .map((c) => c.id)
        .toSet();

    String resolveCategoryName(String? id) {
      if (id == null) return 'Unallocated';
      if (categoryMap.containsKey(id)) return categoryMap[id]!.name;
      return 'Other Envelope';
    }

    // 2. Filter matching expenses within date range
    final matchingExpenses = allTransactions.where((tx) {
      // Date range check
      if (tx.date.isBefore(start) || tx.date.isAfter(end)) return false;

      // Must be an expense
      if (tx.type != TransactionType.expense) return false;

      // Category filter check (if category is specified)
      if (filterCategory != null && tx.category != filterCategory.id) {
        return false;
      }

      // Description keyword filter check (if description is specified)
      if (hasDesc && !tx.description.toLowerCase().contains(cleanDesc)) {
        return false;
      }

      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    // 3. Determine the target category IDs for funding analysis
    final Set<String> targetCategoryIds = {};
    if (filterCategory != null) {
      targetCategoryIds.add(filterCategory.id);
    } else {
      // If category wasn't filtered, target the categories touched by matching expenses
      for (final tx in matchingExpenses) {
        if (tx.category != null && !unallocatedIds.contains(tx.category)) {
          targetCategoryIds.add(tx.category!);
        }
      }
    }

    // 4. Trace funding inflows and outflows for the target categories in this date range
    final List<FundingSourceItem> fundingItems = [];
    double allocatedFromPaychecks = 0.0;
    double takenFromOtherCategories = 0.0;
    double reallocatedToOtherCategories = 0.0;

    for (final tx in allTransactions) {
      // Date range check
      if (tx.date.isBefore(start) || tx.date.isAfter(end)) continue;

      // Case A: Transfer INTO a target category
      if (tx.type == TransactionType.transfer &&
          tx.destinationCategory != null &&
          targetCategoryIds.contains(tx.destinationCategory)) {
        final srcId = tx.sourceCategory;
        final isFromPaycheck = srcId == null ||
            unallocatedIds.contains(srcId) ||
            tx.description.toLowerCase().contains('allocated from');

        final item = FundingSourceItem(
          transactionId: tx.id,
          date: tx.date,
          description: tx.description.isEmpty
              ? (isFromPaycheck ? 'Paycheck Allocation' : 'Envelope Transfer')
              : tx.description,
          amount: tx.amount.abs(),
          sourceCategoryId: srcId,
          sourceCategoryName: srcId != null ? resolveCategoryName(srcId) : 'Paychecks (Unallocated)',
          destinationCategoryId: tx.destinationCategory!,
          destinationCategoryName: resolveCategoryName(tx.destinationCategory),
          isPaycheckAllocation: isFromPaycheck,
        );
        fundingItems.add(item);

        if (isFromPaycheck) {
          allocatedFromPaychecks += item.amount;
        } else {
          takenFromOtherCategories += item.amount;
        }
      }

      // Case B: Direct income logged into a target category
      if (tx.type == TransactionType.income &&
          tx.category != null &&
          targetCategoryIds.contains(tx.category)) {
        final item = FundingSourceItem(
          transactionId: tx.id,
          date: tx.date,
          description: tx.description.isEmpty ? 'Direct Income Deposit' : tx.description,
          amount: tx.amount.abs(),
          sourceCategoryId: null,
          sourceCategoryName: 'Direct Income',
          destinationCategoryId: tx.category!,
          destinationCategoryName: resolveCategoryName(tx.category),
          isPaycheckAllocation: true,
        );
        fundingItems.add(item);
        allocatedFromPaychecks += item.amount;
      }

      // Case C: Transferred OUT of a target category to another envelope
      if (tx.type == TransactionType.transfer &&
          tx.sourceCategory != null &&
          targetCategoryIds.contains(tx.sourceCategory)) {
        if (tx.destinationCategory != null &&
            !unallocatedIds.contains(tx.destinationCategory) &&
            !targetCategoryIds.contains(tx.destinationCategory)) {
          reallocatedToOtherCategories += tx.amount.abs();
        }
      }
    }

    fundingItems.sort((a, b) => b.date.compareTo(a.date));

    // Calculate total spent
    final totalSpent = matchingExpenses.fold<double>(
        0.0, (sum, tx) => sum + tx.amount.abs());

    // Build per-category breakdowns
    final List<SpendingReportCategoryBreakdown> breakdowns = [];
    for (final catId in targetCategoryIds) {
      final cat = categoryMap[catId];
      if (cat == null) continue;

      final catExpenses =
          matchingExpenses.where((tx) => tx.category == catId).toList();
      final catFunding = fundingItems
          .where((fi) => fi.destinationCategoryId == catId)
          .toList();

      final catSpent = catExpenses.fold<double>(
          0.0, (sum, tx) => sum + tx.amount.abs());
      final catPaycheck = catFunding
          .where((fi) => fi.isPaycheckAllocation)
          .fold<double>(0.0, (sum, fi) => sum + fi.amount);
      final catOther = catFunding
          .where((fi) => !fi.isPaycheckAllocation)
          .fold<double>(0.0, (sum, fi) => sum + fi.amount);

      breakdowns.add(SpendingReportCategoryBreakdown(
        category: cat,
        totalSpent: double.parse(catSpent.toStringAsFixed(2)),
        expenseCount: catExpenses.length,
        allocatedFromPaychecks: double.parse(catPaycheck.toStringAsFixed(2)),
        takenFromOtherCategories: double.parse(catOther.toStringAsFixed(2)),
        reallocatedToOtherCategories: 0.0,
        expenses: catExpenses,
        fundingItems: catFunding,
      ));
    }

    return SpendingReportResult(
      startDate: start,
      endDate: end,
      filterCategory: filterCategory,
      filterDescription: filterDescription,
      totalSpent: double.parse(totalSpent.toStringAsFixed(2)),
      totalExpenseCount: matchingExpenses.length,
      allocatedFromPaychecks:
          double.parse(allocatedFromPaychecks.toStringAsFixed(2)),
      takenFromOtherCategories:
          double.parse(takenFromOtherCategories.toStringAsFixed(2)),
      reallocatedToOtherCategories:
          double.parse(reallocatedToOtherCategories.toStringAsFixed(2)),
      matchingExpenses: matchingExpenses,
      fundingItems: fundingItems,
      categoryBreakdowns: breakdowns,
    );
  }
}
