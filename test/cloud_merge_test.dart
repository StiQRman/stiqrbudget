import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/providers/budgets_provider.dart';
import 'package:budget_app/providers/shared_prefs_provider.dart';
import 'package:budget_app/services/pocketbase_service.dart';
import 'package:budget_app/views/dashboard_view.dart';

void main() {
  group('Non-destructive cloud merge', () {
    test('two devices pushing concurrently to same shard merge both transactions', () {
      final initialTx = TransactionModel(
        id: 'tx_initial',
        amount: 25.0,
        category: 'cat_groceries',
        type: TransactionType.expense,
        user: 'test',
        date: DateTime(2026, 11, 1),
        description: 'Initial groceries',
      );

      // Device A adds tx_device_a and pushes to cloud
      final txA = TransactionModel(
        id: 'tx_device_a',
        amount: 42.50,
        category: 'cat_groceries',
        type: TransactionType.expense,
        user: 'test',
        date: DateTime(2026, 11, 14),
        description: 'Husband coffee',
      );
      final cloudShardAfterA = PocketBaseService.mergeTransactions(
        [initialTx],
        [initialTx, txA],
        {},
      );
      expect(cloudShardAfterA.map((t) => t.id).toSet(), {'tx_initial', 'tx_device_a'});

      // Device B (without having pulled tx_device_a yet) adds tx_device_b and pushes
      final txB = TransactionModel(
        id: 'tx_device_b',
        amount: 88.00,
        category: 'cat_groceries',
        type: TransactionType.expense,
        user: 'test',
        date: DateTime(2026, 11, 14),
        description: 'Wife dinner',
      );
      final cloudShardAfterB = PocketBaseService.mergeTransactions(
        cloudShardAfterA,
        [initialTx, txB],
        {},
      );

      // Both tx_device_a and tx_device_b must be preserved!
      expect(
        cloudShardAfterB.map((t) => t.id).toSet(),
        {'tx_initial', 'tx_device_a', 'tx_device_b'},
      );
    });

    test('explicitly deleted transaction is not resurrected by remote shard', () {
      final tx1 = TransactionModel(
        id: 'tx_1',
        amount: 10.0,
        category: 'cat_1',
        type: TransactionType.expense,
        user: 'test',
        date: DateTime(2026, 11, 14),
        description: 'Keep',
      );
      final tx2 = TransactionModel(
        id: 'tx_2',
        amount: 20.0,
        category: 'cat_1',
        type: TransactionType.expense,
        user: 'test',
        date: DateTime(2026, 11, 14),
        description: 'Deleted locally',
      );

      final merged = PocketBaseService.mergeTransactions(
        [tx1, tx2],
        [tx1],
        {'tx_2'},
      );

      expect(merged.map((t) => t.id).toList(), ['tx_1']);
    });

    test('concurrent category merge preserves collaborator categories', () {
      final catA = Category(
        id: 'cat_a',
        name: 'Groceries',
        balance: 0.0,
        allocationType: AllocationType.values.first,
        allocationValue: 0.0,
        colorHex: '#000000',
        iconName: 'shopping_cart',
        user: 'test',
        budgetId: 'default',
      );
      final catB = Category(
        id: 'cat_b',
        name: 'Gas',
        balance: 0.0,
        allocationType: AllocationType.values.first,
        allocationValue: 0.0,
        colorHex: '#000000',
        iconName: 'local_gas_station',
        user: 'test',
        budgetId: 'default',
      );

      final merged = PocketBaseService.mergeCategories([catA], [catB], {});
      expect(merged.map((c) => c.id).toSet(), {'cat_a', 'cat_b'});
    });
  });

  group('Per-budget expected income & paychecks per month', () {
    test('switching activeBudgetIdProvider isolates expectedIncome and paychecksPerMonth', () async {
      SharedPreferences.setMockInitialValues({
        'expected_monthly_income_budget_a': 6500.0,
        'paychecks_per_month_budget_a': 2,
        'expected_monthly_income_budget_b': 3200.0,
        'paychecks_per_month_budget_b': 4,
      });

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      container.read(activeBudgetIdProvider.notifier).state = 'budget_a';
      expect(container.read(expectedIncomeProvider), 6500.0);
      expect(container.read(paychecksPerMonthProvider), 2);

      container.read(activeBudgetIdProvider.notifier).state = 'budget_b';
      expect(container.read(expectedIncomeProvider), 3200.0);
      expect(container.read(paychecksPerMonthProvider), 4);
    });
  });
}
