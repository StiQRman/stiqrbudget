import 'package:flutter_test/flutter_test.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/services/spending_report_engine.dart';

void main() {
  group('SpendingReportEngine Validation Tests', () {
    final testCategory = Category(
      id: 'cat_groceries',
      name: 'Groceries',
      balance: 100.0,
      colorHex: '#10B981',
      iconName: 'shopping_cart',
      allocationType: AllocationType.manual,
      allocationValue: 0.0,
      user: 'user1',
    );

    test('should fail validation if date range is missing', () {
      expect(
        SpendingReportEngine.isValidFilter(
          startDate: null,
          endDate: DateTime.now(),
          category: testCategory,
          description: null,
        ),
        isFalse,
      );

      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime.now(),
          endDate: null,
          category: testCategory,
          description: null,
        ),
        isFalse,
      );
    });

    test('should fail validation if neither category nor description is provided', () {
      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime.now(),
          endDate: DateTime.now(),
          category: null,
          description: null,
        ),
        isFalse,
      );

      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime.now(),
          endDate: DateTime.now(),
          category: null,
          description: '   ',
        ),
        isFalse,
      );
    });

    test('should pass validation if date range and category are provided', () {
      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2026, 9, 30),
          category: testCategory,
          description: null,
        ),
        isTrue,
      );
    });

    test('should pass validation if date range and description are provided', () {
      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2026, 9, 30),
          category: null,
          description: 'Costco',
        ),
        isTrue,
      );
    });

    test('should pass validation if date range, category, and description are all provided', () {
      expect(
        SpendingReportEngine.isValidFilter(
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2026, 9, 30),
          category: testCategory,
          description: 'Costco',
        ),
        isTrue,
      );
    });
  });

  group('SpendingReportEngine Calculation Tests', () {
    late Category unallocated;
    late Category groceries;
    late Category savings;
    late Category entertainment;

    setUp(() {
      unallocated = Category(
        id: 'cat_unallocated',
        name: 'Unallocated',
        balance: 500.0,
        colorHex: '#64748B',
        iconName: 'inbox',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'user1',
      );

      groceries = Category(
        id: 'cat_groceries',
        name: 'Groceries',
        balance: 200.0,
        colorHex: '#10B981',
        iconName: 'shopping_cart',
        allocationType: AllocationType.fixedCheck,
        allocationValue: 300.0,
        user: 'user1',
      );

      savings = Category(
        id: 'cat_savings',
        name: 'Savings',
        balance: 1000.0,
        colorHex: '#6366F1',
        iconName: 'savings',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'user1',
      );

      entertainment = Category(
        id: 'cat_entertainment',
        name: 'Entertainment',
        balance: 50.0,
        colorHex: '#EC4899',
        iconName: 'movie',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'user1',
      );
    });

    test('should calculate spending and distinguish paycheck allocation vs transfers from other categories', () {
      final categories = [unallocated, groceries, savings, entertainment];

      final transactions = [
        // 1. Paycheck allocation into Groceries ($300 from Unallocated) on Sep 2
        TransactionModel(
          id: 'tx_paycheck_groceries',
          description: 'Allocated from: Paycheck',
          amount: 300.0,
          type: TransactionType.transfer,
          sourceCategory: 'cat_unallocated',
          destinationCategory: 'cat_groceries',
          date: DateTime(2026, 9, 2, 10, 0),
          user: 'user1',
        ),

        // 2. Transfer from Savings to cover deficit in Groceries ($45 from Savings) on Sep 12
        TransactionModel(
          id: 'tx_transfer_savings_groceries',
          description: 'Cover deficit for Groceries',
          amount: 45.0,
          type: TransactionType.transfer,
          sourceCategory: 'cat_savings',
          destinationCategory: 'cat_groceries',
          date: DateTime(2026, 9, 12, 14, 0),
          user: 'user1',
        ),

        // 3. Expense in Groceries: Trader Joe's ($120) on Sep 5
        TransactionModel(
          id: 'tx_exp_tj',
          description: "Trader Joe's",
          amount: -120.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 5, 11, 30),
          user: 'user1',
        ),

        // 4. Expense in Groceries: Costco ($150) on Sep 15
        TransactionModel(
          id: 'tx_exp_costco',
          description: 'Costco Wholesale',
          amount: -150.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 15, 16, 0),
          user: 'user1',
        ),

        // 5. Expense in Entertainment: Cinema ($25) on Sep 18 (should not be included in Groceries report)
        TransactionModel(
          id: 'tx_exp_cinema',
          description: 'Cinema',
          amount: -25.0,
          type: TransactionType.expense,
          category: 'cat_entertainment',
          date: DateTime(2026, 9, 18, 19, 0),
          user: 'user1',
        ),

        // 6. Expense in Groceries outside date range on August 28
        TransactionModel(
          id: 'tx_exp_august',
          description: 'Old August Grocery',
          amount: -80.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 8, 28, 12, 0),
          user: 'user1',
        ),
      ];

      final report = SpendingReportEngine.generateReport(
        startDate: DateTime(2026, 9, 1),
        endDate: DateTime(2026, 9, 30),
        filterCategory: groceries,
        filterDescription: null,
        allCategories: categories,
        allTransactions: transactions,
      );

      // Verify spending metrics
      expect(report.totalSpent, 270.0); // 120 + 150
      expect(report.totalExpenseCount, 2);
      expect(report.matchingExpenses.length, 2);
      expect(report.matchingExpenses[0].description, 'Costco Wholesale');
      expect(report.matchingExpenses[1].description, "Trader Joe's");

      // Verify funding breakdown
      expect(report.allocatedFromPaychecks, 300.0);
      expect(report.takenFromOtherCategories, 45.0);
      expect(report.totalFunding, 345.0);
      expect(report.netBalance, 75.0); // 345 - 270 = +75 surplus

      // Verify funding items
      expect(report.fundingItems.length, 2);
      final paycheckItem = report.fundingItems.firstWhere((f) => f.isPaycheckAllocation);
      expect(paycheckItem.amount, 300.0);
      expect(paycheckItem.sourceCategoryName, 'Unallocated');

      final otherItem = report.fundingItems.firstWhere((f) => !f.isPaycheckAllocation);
      expect(otherItem.amount, 45.0);
      expect(otherItem.sourceCategoryName, 'Savings');
    });

    test('should filter by description across categories and attribute envelope funding', () {
      final categories = [unallocated, groceries, savings, entertainment];

      final transactions = [
        // Paycheck to Groceries ($200)
        TransactionModel(
          id: 'tx_p1',
          description: 'Allocated from: Paycheck',
          amount: 200.0,
          type: TransactionType.transfer,
          sourceCategory: 'cat_unallocated',
          destinationCategory: 'cat_groceries',
          date: DateTime(2026, 9, 2),
          user: 'user1',
        ),
        // Transfer from Groceries to Entertainment ($30)
        TransactionModel(
          id: 'tx_t1',
          description: 'Reallocate for Movie night',
          amount: 30.0,
          type: TransactionType.transfer,
          sourceCategory: 'cat_groceries',
          destinationCategory: 'cat_entertainment',
          date: DateTime(2026, 9, 10),
          user: 'user1',
        ),
        // Expense with description "Costco" in Groceries ($110)
        TransactionModel(
          id: 'tx_e1',
          description: 'Costco Groceries',
          amount: -110.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 5),
          user: 'user1',
        ),
        // Expense with description "Costco" in Entertainment (e.g. Costco movie tickets $40)
        TransactionModel(
          id: 'tx_e2',
          description: 'Costco Movie Tickets',
          amount: -40.0,
          type: TransactionType.expense,
          category: 'cat_entertainment',
          date: DateTime(2026, 9, 12),
          user: 'user1',
        ),
        // Another expense NOT matching "Costco"
        TransactionModel(
          id: 'tx_e3',
          description: 'Target Store',
          amount: -55.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 14),
          user: 'user1',
        ),
      ];

      final report = SpendingReportEngine.generateReport(
        startDate: DateTime(2026, 9, 1),
        endDate: DateTime(2026, 9, 30),
        filterCategory: null, // No category selected
        filterDescription: 'Costco',
        allCategories: categories,
        allTransactions: transactions,
      );

      expect(report.totalSpent, 150.0); // 110 + 40
      expect(report.totalExpenseCount, 2);
      expect(report.allocatedFromPaychecks, 200.0);
      expect(report.takenFromOtherCategories, 30.0);
      expect(report.categoryBreakdowns.length, 2);
    });

    test('should filter by both category and description combined', () {
      final categories = [unallocated, groceries, savings, entertainment];

      final transactions = [
        TransactionModel(
          id: 'tx_p1',
          description: 'Allocated from: Paycheck',
          amount: 300.0,
          type: TransactionType.transfer,
          sourceCategory: 'cat_unallocated',
          destinationCategory: 'cat_groceries',
          date: DateTime(2026, 9, 1),
          user: 'user1',
        ),
        TransactionModel(
          id: 'tx_e1',
          description: 'Costco Bulk Food',
          amount: -180.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 8),
          user: 'user1',
        ),
        TransactionModel(
          id: 'tx_e2',
          description: 'Trader Joes',
          amount: -60.0,
          type: TransactionType.expense,
          category: 'cat_groceries',
          date: DateTime(2026, 9, 15),
          user: 'user1',
        ),
      ];

      final report = SpendingReportEngine.generateReport(
        startDate: DateTime(2026, 9, 1),
        endDate: DateTime(2026, 9, 30),
        filterCategory: groceries,
        filterDescription: 'Costco',
        allCategories: categories,
        allTransactions: transactions,
      );

      // Only the Costco expense should match
      expect(report.totalSpent, 180.0);
      expect(report.totalExpenseCount, 1);
      expect(report.matchingExpenses.first.description, 'Costco Bulk Food');
      // Groceries funding in this period is still reported
      expect(report.allocatedFromPaychecks, 300.0);
      expect(report.takenFromOtherCategories, 0.0);
    });
  });
}
