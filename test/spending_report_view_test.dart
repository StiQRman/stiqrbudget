import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/providers/categories_provider.dart';
import 'package:budget_app/providers/transactions_provider.dart';
import 'package:budget_app/views/spending_report_view.dart';

class MockCategoriesNotifier extends StateNotifier<List<Category>>
    implements CategoriesNotifier {
  MockCategoriesNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockTransactionsNotifier extends StateNotifier<List<TransactionModel>>
    implements TransactionsNotifier {
  MockTransactionsNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'SpendingReportView renders correctly with validation prompt and metrics',
      (WidgetTester tester) async {
    final unallocated = Category(
      id: 'cat_unallocated',
      name: 'Unallocated',
      balance: 1000.0,
      colorHex: '#64748B',
      iconName: 'inbox',
      allocationType: AllocationType.manual,
      allocationValue: 0.0,
      user: 'user1',
    );

    final groceries = Category(
      id: 'cat_groceries',
      name: 'Groceries',
      balance: 250.0,
      colorHex: '#10B981',
      iconName: 'shopping_cart',
      allocationType: AllocationType.fixedCheck,
      allocationValue: 200.0,
      user: 'user1',
    );

    final transactions = [
      TransactionModel(
        id: 'tx_paycheck_1',
        description: 'Allocated from: Paycheck',
        amount: 200.0,
        type: TransactionType.transfer,
        sourceCategory: 'cat_unallocated',
        destinationCategory: 'cat_groceries',
        date: DateTime.now(),
        user: 'user1',
      ),
      TransactionModel(
        id: 'tx_grocery_expense',
        description: 'Trader Joe Market',
        amount: -85.50,
        type: TransactionType.expense,
        category: 'cat_groceries',
        date: DateTime.now(),
        user: 'user1',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider
              .overrideWith((ref) => MockCategoriesNotifier([unallocated, groceries])),
          transactionsProvider
              .overrideWith((ref) => MockTransactionsNotifier(transactions)),
        ],
        child: const MaterialApp(
          home: SpendingReportView(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 1. Verify app bar title
    expect(find.text('Spending Report'), findsOneWidget);

    // 2. Initially with no category or description selected, validation prompt is shown
    expect(find.text('Select Envelope or Description'), findsOneWidget);

    // 3. Now enter a description into the keyword field
    await tester.enterText(find.byType(TextFormField), 'Trader Joe');
    await tester.pumpAndSettle();

    // 4. Verification that validation prompt is replaced with report metrics
    expect(find.text('TOTAL SPENT'), findsOneWidget);
    expect(find.text('From Paychecks'), findsOneWidget);
    expect(find.text('Other Envelopes'), findsOneWidget);
    expect(find.text('\$85.50'), findsWidgets);
    expect(find.text('\$200.00'), findsWidgets);
  });
}
