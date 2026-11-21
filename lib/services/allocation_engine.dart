import '../models/category.dart';
import '../models/transaction_model.dart';

class AllocationBreakdown {
  final Category category;
  final double amount;
  final String description;

  AllocationBreakdown({
    required this.category,
    required this.amount,
    required this.description,
  });
}

class AllocationEngine {
  /// Calculates the suggested envelope allocations for a given income check.
  static List<AllocationBreakdown> calculateAllocations({
    required double checkAmount,
    required List<Category> categories,
    required List<TransactionModel> allTransactions,
  }) {
    if (checkAmount <= 0) return [];

    final List<AllocationBreakdown> breakdowns = [];
    double remainingAmount = checkAmount;

    // Filter out the system Unallocated category from rule processing
    final ruleCategories = categories.where((cat) => !cat.isUnallocated).toList();

    // --- STEP 1: Percent of Check Rules ---
    // (e.g. 2% of each check)
    for (final cat in ruleCategories) {
      if (cat.allocationType == AllocationType.percentCheck && cat.allocationValue > 0) {
        final percent = cat.allocationValue;
        double calculated = double.parse((checkAmount * (percent / 100)).toStringAsFixed(2));
        
        // Ensure we don't allocate more than we have
        if (calculated > remainingAmount) {
          calculated = remainingAmount;
        }

        if (calculated > 0) {
          breakdowns.add(AllocationBreakdown(
            category: cat,
            amount: calculated,
            description: '${percent.toStringAsRegExp()}% of check',
          ));
          remainingAmount = double.parse((remainingAmount - calculated).toStringAsFixed(2));
        }
      }
    }

    // --- STEP 2: Fixed amount per check ---
    // (e.g. $50 from each check)
    for (final cat in ruleCategories) {
      if (cat.allocationType == AllocationType.fixedCheck && cat.allocationValue > 0) {
        double fixedValue = cat.allocationValue;

        if (fixedValue > remainingAmount) {
          fixedValue = remainingAmount;
        }

        if (fixedValue > 0) {
          breakdowns.add(AllocationBreakdown(
            category: cat,
            amount: fixedValue,
            description: '\$${fixedValue.toStringAsFixed(2)} per check',
          ));
          remainingAmount = double.parse((remainingAmount - fixedValue).toStringAsFixed(2));
        }
      }
    }

    // --- STEP 3: Monthly Targets (with rollover) ---
    // (e.g. Fill up to $2,000 per month)
    // To know how much we've already allocated this month, we sum all transfer transactions
    // going INTO this category during the current calendar month.
    final now = DateTime.now();
    final firstOfCurrentMonth = DateTime(now.year, now.month, 1);

    for (final cat in ruleCategories) {
      if (cat.allocationType == AllocationType.monthlyTarget && cat.allocationValue > 0) {
        final target = cat.allocationValue;

        // Sum allocations (transfers in) that occurred this month
        final allocationsThisMonth = allTransactions
            .where((tx) =>
                tx.type == TransactionType.transfer &&
                tx.destinationCategory == cat.id &&
                tx.date.isAfter(firstOfCurrentMonth))
            .fold<double>(0.0, (sum, tx) => sum + tx.amount);

        final remainingTarget = target - allocationsThisMonth;

        if (remainingTarget > 0) {
          double allocateValue = remainingTarget;
          if (allocateValue > remainingAmount) {
            allocateValue = remainingAmount;
          }

          if (allocateValue > 0) {
            breakdowns.add(AllocationBreakdown(
              category: cat,
              amount: double.parse(allocateValue.toStringAsFixed(2)),
              description: 'Monthly Target (\$${target.toStringAsFixed(0)}), \$${allocationsThisMonth.toStringAsFixed(2)} filled',
            ));
            remainingAmount = double.parse((remainingAmount - allocateValue).toStringAsFixed(2));
          }
        }
      }
    }

    // --- STEP 4: Unallocated Remainder ---
    // Any leftovers go to the Unallocated category
    final unallocatedCat = categories.firstWhere(
      (cat) => cat.isUnallocated,
      orElse: () => Category(
        id: 'unallocated_fallback',
        name: 'Unallocated',
        balance: 0.0,
        colorHex: '#64748B',
        iconName: 'inbox',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: '',
      ),
    );

    if (remainingAmount > 0) {
      breakdowns.add(AllocationBreakdown(
        category: unallocatedCat,
        amount: remainingAmount,
        description: 'Remaining unallocated balance',
      ));
    }

    return breakdowns;
  }
}

extension DoubleFormatting on double {
  String toStringAsRegExp() {
    return toString().replaceAll(RegExp(r'\.0$'), '');
  }
}
