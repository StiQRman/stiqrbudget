import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/providers/auth_provider.dart';
import 'package:budget_app/providers/categories_provider.dart';
import 'package:budget_app/providers/pb_provider.dart';
import 'package:budget_app/providers/shared_prefs_provider.dart';
import 'package:budget_app/providers/transactions_provider.dart';
import 'package:budget_app/services/pocketbase_service.dart';

Category _makeCat(
  String id,
  String name, {
  double balance = 0.0,
  String budgetId = 'budget_1',
}) {
  return Category(
    id: id,
    name: name,
    balance: balance,
    allocationType: AllocationType.manual,
    allocationValue: 0.0,
    colorHex: '#10B981',
    iconName: 'category',
    user: 'test_user',
    budgetId: budgetId,
  );
}

sc.RecordModel _makeRecord(String collection, String id, String text) {
  return sc.RecordModel(
    id: id,
    collection: collection,
    data: {'text': text},
  );
}

class _TestSetup {
  final ProviderContainer container;
  final PocketBaseService service;

  _TestSetup(this.container, this.service);
  Future<void> dispose() async {
    // Allow any background unawaited sync/pull microtasks to settle before disposing container
    await Future<void>.delayed(const Duration(milliseconds: 50));
    container.dispose();
  }
}

Future<_TestSetup> _createTestSetup(List<Category> initialCategories) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  final service = PocketBaseService();
  final cloudStore = <String, sc.RecordModel>{};
  service.debugGetRecordOverride = (collection, recordId) async {
    return cloudStore['$collection/$recordId'];
  };
  service.debugUpsertRecordOverride = (collection, recordId, textPayload) async {
    final rec = _makeRecord(collection, recordId, textPayload);
    cloudStore['$collection/$recordId'] = rec;
    return rec;
  };

  await service.debugInitTestSession(
    email: 'bugs@stiqrbudget.test',
    password: 'StrongTestPassword!1',
    hasLoadedRemoteOnce: true,
  );

  for (final cat in initialCategories) {
    await service.createCategory(cat, syncImmediately: false);
  }

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      pbServiceProvider.overrideWithValue(service),
    ],
  );

  // Trigger auth + providers initialization and realtime subscriptions
  container.read(authProvider);
  await container.read(categoriesProvider.notifier).loadCategories();
  await container.read(transactionsProvider.notifier).loadTransactions();

  return _TestSetup(container, service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Bug 1: No duplicate transactions & single balance deduction', () {
    test('addSimpleTransaction logs exactly 1 transaction and deducts balance once', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_groceries', 'Groceries', balance: 100.0),
      ]);
      addTearDown(setup.dispose);

      final groceries = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_groceries');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addSimpleTransaction(
            description: 'Milk & Bread',
            amount: -25.50,
            type: TransactionType.expense,
            category: groceries,
          );

      expect(ok, isTrue);

      final providerTxs = setup.container.read(transactionsProvider);
      expect(providerTxs.length, 1, reason: 'Provider state must have exactly 1 transaction');
      expect(setup.service.transactions.length, 1, reason: 'Service must have exactly 1 transaction');
      expect(providerTxs.first.id, setup.service.transactions.first.id);

      final updatedGroceries = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_groceries');
      expect(updatedGroceries.balance, closeTo(74.50, 0.001));
      expect(
        setup.service.categories.firstWhere((c) => c.id == 'cat_groceries').balance,
        closeTo(74.50, 0.001),
      );
    });

    test('addTransfer logs exactly 1 transfer and updates balances once', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 200.0),
        _makeCat('cat_rent', 'Rent', balance: 50.0),
      ]);
      addTearDown(setup.dispose);

      final cats = setup.container.read(categoriesProvider);
      final unalloc = cats.firstWhere((c) => c.id == 'cat_unalloc');
      final rent = cats.firstWhere((c) => c.id == 'cat_rent');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addTransfer(
            description: 'Move to Rent',
            amount: 75.0,
            source: unalloc,
            destination: rent,
          );

      expect(ok, isTrue);
      expect(setup.container.read(transactionsProvider).length, 1);
      expect(setup.service.transactions.length, 1);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(125.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_rent').balance,
        closeTo(125.0, 0.001),
      );
    });
  });

  group('Bug 2: undoLastAction restores exact balances instead of double-subtracting', () {
    test('undoLastAction after simple expense restores exact original envelope balance', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_dining', 'Dining', balance: 100.0),
      ]);
      addTearDown(setup.dispose);

      final dining = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_dining');

      final logged = await setup.container
          .read(transactionsProvider.notifier)
          .addSimpleTransaction(
            description: 'Tacos',
            amount: -30.0,
            type: TransactionType.expense,
            category: dining,
          );
      expect(logged, isTrue);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_dining').balance,
        closeTo(70.0, 0.001),
      );

      final undone = await setup.container
          .read(transactionsProvider.notifier)
          .undoLastAction();
      expect(undone, isTrue);

      // Must be restored to 100.0, NOT subtracted again to 40.0!
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_dining').balance,
        closeTo(100.0, 0.001),
      );
      expect(
        setup.service.categories.firstWhere((c) => c.id == 'cat_dining').balance,
        closeTo(100.0, 0.001),
      );
      expect(setup.container.read(transactionsProvider), isEmpty);
      expect(setup.service.transactions, isEmpty);
    });

    test('undoLastAction after split expense restores all affected envelopes', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_a', 'Food', balance: 40.0),
        _makeCat('cat_b', 'Fun', balance: 60.0),
      ]);
      addTearDown(setup.dispose);

      final cats = setup.container.read(categoriesProvider);
      final food = cats.firstWhere((c) => c.id == 'cat_a');
      final fun = cats.firstWhere((c) => c.id == 'cat_b');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addSplitExpense(
            description: 'Dinner & Movie',
            totalAmount: 75.0,
            splits: [
              {'category': food, 'amount': 40.0},
              {'category': fun, 'amount': 35.0},
            ],
          );
      expect(ok, isTrue);
      expect(setup.container.read(transactionsProvider).length, 2);

      final undone = await setup.container
          .read(transactionsProvider.notifier)
          .undoLastAction();
      expect(undone, isTrue);

      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_a').balance,
        closeTo(40.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_b').balance,
        closeTo(60.0, 0.001),
      );
      expect(setup.container.read(transactionsProvider), isEmpty);
      expect(setup.service.transactions, isEmpty);
    });

    test('undoLastAction after transfer reverses balances cleanly and clamps >= 0', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 100.0),
        _makeCat('cat_gas', 'Gas', balance: 20.0),
      ]);
      addTearDown(setup.dispose);

      final cats = setup.container.read(categoriesProvider);
      final unalloc = cats.firstWhere((c) => c.id == 'cat_unalloc');
      final gas = cats.firstWhere((c) => c.id == 'cat_gas');

      await setup.container.read(transactionsProvider.notifier).addTransfer(
            description: 'Fund Gas',
            amount: 30.0,
            source: unalloc,
            destination: gas,
          );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(70.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_gas').balance,
        closeTo(50.0, 0.001),
      );

      final undone = await setup.container
          .read(transactionsProvider.notifier)
          .undoLastAction();
      expect(undone, isTrue);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(100.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_gas').balance,
        closeTo(20.0, 0.001),
      );
    });

    test('undoLastAction after income distribution reverses added amounts cleanly', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 10.0),
        _makeCat('cat_savings', 'Savings', balance: 50.0),
      ]);
      addTearDown(setup.dispose);

      final savings = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_savings');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addIncomeWithDistributions(
            description: 'Paycheck',
            amount: 500.0,
            distributions: [
              {'category': savings, 'amount': 200.0},
            ],
          );
      expect(ok, isTrue);
      expect(setup.container.read(transactionsProvider).length, 2);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(310.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_savings').balance,
        closeTo(250.0, 0.001),
      );

      final undone = await setup.container
          .read(transactionsProvider.notifier)
          .undoLastAction();
      expect(undone, isTrue);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(10.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_savings').balance,
        closeTo(50.0, 0.001),
      );
      expect(setup.container.read(transactionsProvider), isEmpty);
      expect(setup.service.transactions, isEmpty);
    });
  });

  group('Bug 3: Envelopes must NEVER go negative & require covering envelopes on overdraw', () {
    test('uncovered overdraw via addSimpleTransaction is rejected and balance stays unchanged', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_coffee', 'Coffee', balance: 15.0),
      ]);
      addTearDown(setup.dispose);

      final coffee = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_coffee');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addSimpleTransaction(
            description: 'Expensive Espresso Machine',
            amount: -50.0,
            type: TransactionType.expense,
            category: coffee,
          );

      expect(ok, isFalse);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_coffee').balance,
        closeTo(15.0, 0.001),
      );
      expect(setup.container.read(transactionsProvider), isEmpty);
      expect(setup.service.transactions, isEmpty);
    });

    test('addSplitExpense rejects duplicate envelope rows whose sum exceeds balance', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_food', 'Food', balance: 30.0),
      ]);
      addTearDown(setup.dispose);

      final food = setup.container
          .read(categoriesProvider)
          .firstWhere((c) => c.id == 'cat_food');

      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addSplitExpense(
            description: 'Overdraw Attempt',
            totalAmount: 50.0,
            splits: [
              {'category': food, 'amount': 30.0},
              {'category': food, 'amount': 20.0},
            ],
          );

      expect(ok, isFalse);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_food').balance,
        closeTo(30.0, 0.001),
      );
      expect(setup.container.read(transactionsProvider), isEmpty);
    });

    test('covering an overdraw across 1+ envelopes succeeds and leaves all envelopes >= 0.0', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 10.0),
        _makeCat('cat_food', 'Food', balance: 30.0),
        _makeCat('cat_fun', 'Fun', balance: 25.0),
      ]);
      addTearDown(setup.dispose);

      final cats = setup.container.read(categoriesProvider);
      final unalloc = cats.firstWhere((c) => c.id == 'cat_unalloc');
      final food = cats.firstWhere((c) => c.id == 'cat_food');
      final fun = cats.firstWhere((c) => c.id == 'cat_fun');

      // $60 expense on Food ($30), covered by Fun ($25) + Unallocated ($5)
      final ok = await setup.container
          .read(transactionsProvider.notifier)
          .addSplitExpense(
            description: 'Grocery Haul',
            totalAmount: 60.0,
            splits: [
              {'category': food, 'amount': 30.0},
              {'category': fun, 'amount': 25.0},
              {'category': unalloc, 'amount': 5.0},
            ],
          );

      expect(ok, isTrue);
      for (final cat in setup.container.read(categoriesProvider)) {
        expect(cat.balance, greaterThanOrEqualTo(0.0));
      }
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_food').balance,
        closeTo(0.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_fun').balance,
        closeTo(0.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_unalloc').balance,
        closeTo(5.0, 0.001),
      );
    });

    test('addExpenseWithCoverage rejects insufficient coverage and succeeds when fully covered', () async {
      final setup = await _createTestSetup([
        _makeCat('cat_unalloc', 'Unallocated', balance: 0.0),
        _makeCat('cat_bills', 'Bills', balance: 40.0),
        _makeCat('cat_misc', 'Misc', balance: 30.0),
      ]);
      addTearDown(setup.dispose);

      final cats = setup.container.read(categoriesProvider);
      final bills = cats.firstWhere((c) => c.id == 'cat_bills');
      final misc = cats.firstWhere((c) => c.id == 'cat_misc');

      // $80 expense on Bills ($40) with only $30 from Misc -> still $10 short -> rejected
      final rejected = await setup.container
          .read(transactionsProvider.notifier)
          .addExpenseWithCoverage(
            description: 'Electric Bill',
            amount: 80.0,
            category: bills,
            coverages: {misc: 30.0},
          );
      expect(rejected, isFalse);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_bills').balance,
        closeTo(40.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_misc').balance,
        closeTo(30.0, 0.001),
      );

      // $65 expense on Bills ($40) with $25 from Misc -> fully covered -> succeeds
      final accepted = await setup.container
          .read(transactionsProvider.notifier)
          .addExpenseWithCoverage(
            description: 'Electric Bill',
            amount: 65.0,
            category: bills,
            coverages: {misc: 25.0},
          );
      expect(accepted, isTrue);
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_bills').balance,
        closeTo(0.0, 0.001),
      );
      expect(
        setup.container.read(categoriesProvider).firstWhere((c) => c.id == 'cat_misc').balance,
        closeTo(5.0, 0.001),
      );
    });
  });
}
