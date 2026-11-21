import 'package:flutter_test/flutter_test.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/services/allocation_engine.dart';
import 'package:budget_app/services/csv_export_service.dart';

void main() {
  group('AllocationEngine Tests', () {
    late Category unallocated;
    late Category rent;
    late Category vacation;
    late Category savings;

    setUp(() {
      unallocated = Category(
        id: 'unallocated_id',
        name: 'Unallocated',
        balance: 0.0,
        colorHex: '#64748B',
        iconName: 'inbox',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'user1',
      );

      rent = Category(
        id: 'rent_id',
        name: 'Rent',
        balance: 0.0,
        colorHex: '#6366F1',
        iconName: 'rent',
        allocationType: AllocationType.monthlyTarget,
        allocationValue: 2000.0, // $2000 target per month
        user: 'user1',
      );

      vacation = Category(
        id: 'vacation_id',
        name: 'Vacation',
        balance: 0.0,
        colorHex: '#06B6D4',
        iconName: 'vacation',
        allocationType: AllocationType.percentCheck,
        allocationValue: 2.0, // 2% of each check
        user: 'user1',
      );

      savings = Category(
        id: 'savings_id',
        name: 'Savings',
        balance: 0.0,
        colorHex: '#10B981',
        iconName: 'savings',
        allocationType: AllocationType.fixedCheck,
        allocationValue: 50.0, // $50 from each check
        user: 'user1',
      );
    });

    test('should calculate basic allocations with no previous month transactions', () {
      final categories = [unallocated, rent, vacation, savings];
      final transactions = <TransactionModel>[];

      // Income check = $5,000
      // 2% for vacation = $100
      // $50 for savings = $50
      // Rent monthly target = $2,000 (needs full $2,000)
      // Leftovers = 5000 - 100 - 50 - 2000 = $2850
      final result = AllocationEngine.calculateAllocations(
        checkAmount: 5000.0,
        categories: categories,
        allTransactions: transactions,
      );

      expect(result.length, 4);

      final vacationAlloc = result.firstWhere((r) => r.category.id == 'vacation_id');
      expect(vacationAlloc.amount, 100.0);
      expect(vacationAlloc.description, '2% of check');

      final savingsAlloc = result.firstWhere((r) => r.category.id == 'savings_id');
      expect(savingsAlloc.amount, 50.0);
      expect(savingsAlloc.description, '\$50.00 per check');

      final rentAlloc = result.firstWhere((r) => r.category.id == 'rent_id');
      expect(rentAlloc.amount, 2000.0);
      expect(rentAlloc.description, contains('Monthly Target'));

      final unallocatedAlloc = result.firstWhere((r) => r.category.id == 'unallocated_id');
      expect(unallocatedAlloc.amount, 2850.0);
    });

    test('should calculate allocations with rollover monthly target', () {
      final categories = [unallocated, rent, vacation, savings];
      
      // Assume user already transferred $1,200 to Rent earlier this month
      final now = DateTime.now();
      final previousTransfers = [
        TransactionModel(
          id: 'tx_1',
          description: 'Allocation',
          amount: 1200.0,
          type: TransactionType.transfer,
          sourceCategory: 'unallocated_id',
          destinationCategory: 'rent_id',
          date: DateTime(now.year, now.month, 10), // Current Month
          user: 'user1',
        )
      ];

      // Income check = $5,000
      // 2% for vacation = $100
      // $50 for savings = $50
      // Rent monthly target = $2,000. Already allocated: $1,200. Remaining needed: $800.
      // Leftovers = 5000 - 100 - 50 - 800 = $4,050
      final result = AllocationEngine.calculateAllocations(
        checkAmount: 5000.0,
        categories: categories,
        allTransactions: previousTransfers,
      );

      final rentAlloc = result.firstWhere((r) => r.category.id == 'rent_id');
      expect(rentAlloc.amount, 800.0);
      expect(rentAlloc.description, contains('\$1200.00 filled'));

      final unallocatedAlloc = result.firstWhere((r) => r.category.id == 'unallocated_id');
      expect(unallocatedAlloc.amount, 4050.0);
    });

    test('should calculate allocation capped by check amount limit', () {
      final categories = [unallocated, rent, vacation, savings];
      final transactions = <TransactionModel>[];

      // Income check = $100
      // 2% for vacation = $2.00
      // $50 for savings = $50.00
      // Rent monthly target = $2000. Remaining check: 100 - 2 - 50 = $48.00
      // Rent gets capped to $48.00. Leftover = $0.
      final result = AllocationEngine.calculateAllocations(
        checkAmount: 100.0,
        categories: categories,
        allTransactions: transactions,
      );

      final vacationAlloc = result.firstWhere((r) => r.category.id == 'vacation_id');
      expect(vacationAlloc.amount, 2.0);

      final savingsAlloc = result.firstWhere((r) => r.category.id == 'savings_id');
      expect(savingsAlloc.amount, 50.0);

      final rentAlloc = result.firstWhere((r) => r.category.id == 'rent_id');
      expect(rentAlloc.amount, 48.0);

      // Verify no leftovers
      final unallocatedAlloc = result.where((r) => r.category.id == 'unallocated_id');
      expect(unallocatedAlloc.isEmpty, true);
    });
  });

  group('Double Precision Rounding Tests', () {
    test('Category constructor rounds balance and allocationValue to 2 decimal places', () {
      final category = Category(
        id: 'test_precision',
        name: 'Test Precision',
        balance: 12.34567,
        colorHex: '#6366F1',
        iconName: 'home',
        allocationType: AllocationType.fixedCheck,
        allocationValue: 45.6789,
        user: 'user1',
      );

      expect(category.balance, 12.35);
      expect(category.allocationValue, 45.68);
    });

    test('TransactionModel constructor rounds amount to 2 decimal places', () {
      final tx = TransactionModel(
        id: 'tx_precision',
        description: 'Test amount precision rounding',
        amount: -123.4567,
        type: TransactionType.expense,
        date: DateTime.now(),
        user: 'user1',
      );

      expect(tx.amount, -123.46);
    });

    test('Category.fromJson handles both numeric and string balance/allocation values', () {
      final json1 = {
        'id': 'cat_str',
        'name': 'Groceries',
        'balance': '150.75',
        'colorHex': '#10B981',
        'iconName': 'groceries',
        'allocationType': 'fixedCheck',
        'allocationValue': '50.25',
        'user': 'user1',
      };
      final cat1 = Category.fromJson(json1);
      expect(cat1.balance, 150.75);
      expect(cat1.allocationValue, 50.25);

      final json2 = {
        'id': 'cat_num',
        'name': 'Utilities',
        'balance': 200,
        'colorHex': '#10B981',
        'iconName': 'utilities',
        'allocationType': 'monthlyTarget',
        'allocationValue': 200.0,
        'user': 'user1',
      };
      final cat2 = Category.fromJson(json2);
      expect(cat2.balance, 200.0);
      expect(cat2.allocationValue, 200.0);
    });

    test('TransactionModel.fromJson handles both numeric and string amounts', () {
      final json1 = {
        'id': 'tx_str',
        'description': 'Trader Joe',
        'amount': '-45.50',
        'type': 'expense',
        'date': '2026-11-09T12:00:00Z',
        'user': 'user1',
      };
      final tx1 = TransactionModel.fromJson(json1);
      expect(tx1.amount, -45.50);

      final json2 = {
        'id': 'tx_num',
        'description': 'Direct Deposit',
        'amount': 2500,
        'type': 'income',
        'date': '2026-11-09T12:00:00Z',
        'user': 'user1',
      };
      final tx2 = TransactionModel.fromJson(json2);
      expect(tx2.amount, 2500.0);
    });

    test('Multi-category split allocations deduct exact balances across envelopes', () {
      final envelopeA = Category(
        id: 'cat_a',
        name: 'Groceries',
        balance: 100.00,
        colorHex: '#10B981',
        iconName: 'groceries',
        allocationType: AllocationType.manual,
        allocationValue: 0,
        user: 'user1',
      );
      final envelopeB = Category(
        id: 'cat_b',
        name: 'Dining',
        balance: 50.00,
        colorHex: '#6366F1',
        iconName: 'dining',
        allocationType: AllocationType.manual,
        allocationValue: 0,
        user: 'user1',
      );

      const splitAllocations = [
        {'categoryId': 'cat_a', 'amount': 75.00},
        {'categoryId': 'cat_b', 'amount': 45.00},
      ];

      final totalSplit = splitAllocations.fold<double>(
        0.0,
        (sum, item) => sum + (item['amount'] as double),
      );
      expect(totalSplit, 120.00);

      final updatedA = envelopeA.copyWith(balance: envelopeA.balance - 75.00);
      final updatedB = envelopeB.copyWith(balance: envelopeB.balance - 45.00);

      expect(updatedA.balance, 25.00);
      expect(updatedB.balance, 5.00);
    });
  });

  group('Envelope Progress Bar & Percentage Left Tests', () {
    test('fixedCheck rule: \$50/check * 2 checks = \$100 baseline; \$70 balance -> 70% left, \$0 -> 0%, \$150 -> 150%', () {
      final cat70 = Category(
        id: 'cat_fixed',
        name: 'Groceries',
        balance: 70.0,
        colorHex: '#10B981',
        iconName: 'groceries',
        allocationType: AllocationType.fixedCheck,
        allocationValue: 50.0,
        user: 'user1',
      );

      final res70 = CsvExportService.calculateEnvelopeProgress(
        category: cat70,
        transactions: const [],
        expectedIncome: 5000.0,
        paychecksPerMonth: 2,
      );
      expect(res70.monthlyBaseline, 100.0);
      expect(res70.percentLeft, 70);
      expect(res70.progressBarValue, closeTo(0.7, 0.001));
      expect(res70.progressLabel, '\$70.00 of \$100.00 / mo');

      final cat0 = cat70.copyWith(balance: 0.0);
      final res0 = CsvExportService.calculateEnvelopeProgress(
        category: cat0,
        transactions: const [],
        expectedIncome: 5000.0,
        paychecksPerMonth: 2,
      );
      expect(res0.percentLeft, 0);
      expect(res0.progressBarValue, 0.0);

      final cat150 = cat70.copyWith(balance: 150.0);
      final res150 = CsvExportService.calculateEnvelopeProgress(
        category: cat150,
        transactions: const [],
        expectedIncome: 5000.0,
        paychecksPerMonth: 2,
      );
      expect(res150.percentLeft, 150);
      expect(res150.progressBarValue, 1.0); // Clamped for LinearProgressIndicator
      expect(res150.progressLabel, '\$150.00 of \$100.00 / mo');
    });

    test('percentCheck rule: 10% of \$4000 expected income = \$400 baseline', () {
      final cat = Category(
        id: 'cat_pct',
        name: 'Savings',
        balance: 200.0,
        colorHex: '#06B6D4',
        iconName: 'savings',
        allocationType: AllocationType.percentCheck,
        allocationValue: 10.0,
        user: 'user1',
      );

      final res = CsvExportService.calculateEnvelopeProgress(
        category: cat,
        transactions: const [],
        expectedIncome: 4000.0,
        paychecksPerMonth: 2,
      );
      expect(res.monthlyBaseline, 400.0);
      expect(res.percentLeft, 50);
      expect(res.progressBarValue, 0.5);
      expect(res.progressLabel, '\$200.00 of \$400.00 / mo');
    });

    test('monthlyTarget rule and manual rule with/without monthly inflows', () {
      final manualCat = Category(
        id: 'cat_manual',
        name: 'Fun Money',
        balance: 45.0,
        colorHex: '#6366F1',
        iconName: 'fun',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'user1',
      );

      // No transactions this month, balance > 0 -> 100% available
      final resNoTx = CsvExportService.calculateEnvelopeProgress(
        category: manualCat,
        transactions: const [],
        expectedIncome: 5000.0,
        paychecksPerMonth: 2,
      );
      expect(resNoTx.monthlyBaseline, 0.0);
      expect(resNoTx.percentLeft, 100);
      expect(resNoTx.progressBarValue, 1.0);
      expect(resNoTx.progressLabel, '\$45.00 available');

      // Manual with 0 balance -> 0% left
      final resZero = CsvExportService.calculateEnvelopeProgress(
        category: manualCat.copyWith(balance: 0.0),
        transactions: const [],
        expectedIncome: 5000.0,
        paychecksPerMonth: 2,
      );
      expect(resZero.percentLeft, 0);
      expect(resZero.progressBarValue, 0.0);
    });
  });

  group('CSV Data Export Tests', () {
    test('generateBudgetCsv outputs envelopes summary, unallocated balance, and transactions', () {
      final categories = [
        Category(
          id: 'unalloc',
          name: 'Unallocated',
          balance: 250.50,
          colorHex: '#64748B',
          iconName: 'inbox',
          allocationType: AllocationType.manual,
          allocationValue: 0.0,
          user: 'u1',
        ),
        Category(
          id: 'groceries_id',
          name: 'Groceries, Food & More',
          balance: 70.00,
          colorHex: '#10B981',
          iconName: 'groceries',
          allocationType: AllocationType.fixedCheck,
          allocationValue: 50.0,
          user: 'u1',
        ),
      ];

      final transactions = [
        TransactionModel(
          id: 'tx1',
          description: 'Trader Joe\'s "Special"',
          amount: -30.00,
          type: TransactionType.expense,
          category: 'groceries_id',
          date: DateTime(2026, 11, 10, 14, 30),
          user: 'u1',
        ),
        TransactionModel(
          id: 'tx2',
          description: 'Paycheck Allocation',
          amount: 100.00,
          type: TransactionType.transfer,
          sourceCategory: 'unalloc',
          destinationCategory: 'groceries_id',
          date: DateTime(2026, 11, 1, 9, 0),
          user: 'u1',
        ),
      ];

      final csv = CsvExportService.generateBudgetCsv(
        budgetName: 'Family Budget',
        categories: categories,
        transactions: transactions,
      );

      expect(csv, contains('Budget Name,Family Budget'));
      expect(csv, contains('=== ENVELOPES SUMMARY ==='));
      expect(csv, contains('"Groceries, Food & More",70.00,Fixed per Check,50.00'));
      expect(csv, contains('Unallocated,250.50,System Unallocated,0.00'));
      expect(csv, contains('Total Cash Pool,320.50,,'));
      expect(csv, contains('=== TRANSACTION HISTORY ==='));
      expect(csv, contains('2026-11-10 14:30,Expense,"Trader Joe\'s ""Special""",-30.00,"Groceries, Food & More"'));
      expect(csv, contains('2026-11-01 09:00,Transfer,Paycheck Allocation,100.00,Unallocated,"Groceries, Food & More"'));
    });

    test('Transaction models preserve past-only custom dates and sort chronologically descending', () {
      final now = DateTime.now();
      final pastDate1 = DateTime(2025, 5, 12, 10, 0);
      final pastDate2 = DateTime(2026, 1, 15, 16, 45);

      final t1 = TransactionModel(
        id: 't1',
        description: 'Old expense',
        amount: -25.0,
        type: TransactionType.expense,
        category: 'groceries_id',
        date: pastDate1,
        user: 'u1',
      );

      final t2 = TransactionModel(
        id: 't2',
        description: 'Recent expense',
        amount: -15.0,
        type: TransactionType.expense,
        category: 'groceries_id',
        date: pastDate2,
        user: 'u1',
      );

      final t3 = TransactionModel(
        id: 't3',
        description: 'Today expense',
        amount: -5.0,
        type: TransactionType.expense,
        category: 'groceries_id',
        date: now,
        user: 'u1',
      );

      expect(t1.date.isBefore(now), isTrue);
      expect(t2.date.isBefore(now), isTrue);

      final list = [t1, t3, t2]..sort((a, b) => b.date.compareTo(a.date));
      expect(list.map((t) => t.id).toList(), ['t3', 't2', 't1']);
    });
  });
}
