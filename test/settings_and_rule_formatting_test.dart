import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/models/undo_action.dart';
import 'package:budget_app/providers/auth_provider.dart';
import 'package:budget_app/providers/categories_provider.dart';
import 'package:budget_app/providers/pb_provider.dart';
import 'package:budget_app/providers/shared_prefs_provider.dart';
import 'package:budget_app/providers/transactions_provider.dart';
import 'package:budget_app/providers/budgets_provider.dart';
import 'package:budget_app/providers/releases_provider.dart';
import 'package:budget_app/services/pocketbase_service.dart';
import 'package:budget_app/views/privacy_policy_view.dart';
import 'package:budget_app/views/settings_view.dart';
import 'package:budget_app/views/dashboard_view.dart';

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
  UndoAction? get lastUndoAction => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockBudgetsListNotifier extends StateNotifier<List<Budget>>
    implements BudgetsListNotifier {
  MockBudgetsListNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockActiveBudgetIdNotifier extends StateNotifier<String>
    implements ActiveBudgetIdNotifier {
  MockActiveBudgetIdNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SlowSyncPocketBaseService extends PocketBaseService {
  final Completer<void> syncCompleter = Completer<void>();
  int syncCalls = 0;

  @override
  String? get currentUserId => 'test_user_pub';

  @override
  Future<List<Category>> fetchCategories() async => List<Category>.from(categories);

  @override
  Future<void> syncVaultToCloud() {
    syncCalls++;
    return syncCompleter.future;
  }
}

class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier(super.ref) {
    state = AuthState(isAuthenticated: true, email: 'test@stiqrbudget.com');
  }
}

void main() {
  group('SettingsView & Rule Formatting Tests', () {
    testWidgets('SettingsView renders as a dedicated Scaffold page with AppBar back button', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith((ref) => MockCategoriesNotifier([])),
            transactionsProvider.overrideWith((ref) => MockTransactionsNotifier([])),
            budgetsListProvider.overrideWith((ref) => MockBudgetsListNotifier([Budget(id: 'b1', name: 'Personal')])),
            activeBudgetIdProvider.overrideWith((ref) => MockActiveBudgetIdNotifier('b1')),
            latestReleaseProvider.overrideWith((ref) => null),
            hasUpdateProvider.overrideWith((ref) => false),
            currentAppVersionProvider.overrideWith((ref) => '1.0.14'),
          ],
          child: const MaterialApp(
            home: SettingsView(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Scaffold AppBar with Settings title and Back button
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // Verify main settings options exist
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Spending Report'), findsOneWidget);
      expect(find.text('Transaction History'), findsOneWidget);
      expect(find.text('Export Data to CSV (Free)'), findsOneWidget);
      expect(find.text('Fingerprint Log In'), findsOneWidget);
      expect(find.text('Public Key QR & Budget Collaborators'), findsOneWidget);
      expect(find.text('Add New Budget'), findsNothing);
      expect(find.text('Log Out'), findsOneWidget);
      expect(find.text('Delete Account'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('Privacy Policy tile in SettingsView navigates to PrivacyPolicyView with PQE & contact details', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith((ref) => MockCategoriesNotifier([])),
            transactionsProvider.overrideWith((ref) => MockTransactionsNotifier([])),
            budgetsListProvider.overrideWith((ref) => MockBudgetsListNotifier([Budget(id: 'b1', name: 'Personal')])),
            activeBudgetIdProvider.overrideWith((ref) => MockActiveBudgetIdNotifier('b1')),
            latestReleaseProvider.overrideWith((ref) => null),
            hasUpdateProvider.overrideWith((ref) => false),
            currentAppVersionProvider.overrideWith((ref) => '1.0.22'),
          ],
          child: const MaterialApp(
            home: SettingsView(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final privacyTile = find.text('Privacy Policy');
      await tester.ensureVisible(privacyTile);
      await tester.pumpAndSettle();
      await tester.tap(privacyTile);
      await tester.pumpAndSettle();

      expect(find.byType(PrivacyPolicyView), findsOneWidget);
      expect(find.text('StiQRbudget Privacy Policy'), findsOneWidget);
      expect(find.textContaining('ML-KEM-768'), findsOneWidget);
      expect(find.textContaining('stiqrapps@gmail.com'), findsOneWidget);
    });

    test('CategoriesNotifier.addCategory updates state optimistically without waiting on syncVaultToCloud', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final slowPb = _SlowSyncPocketBaseService();

      final container = ProviderContainer(
        overrides: [
          pbServiceProvider.overrideWithValue(slowPb),
          sharedPreferencesProvider.overrideWithValue(prefs),
          authProvider.overrideWith((ref) => _StaticAuthNotifier(ref)),
          activeBudgetIdProvider.overrideWith((ref) => MockActiveBudgetIdNotifier('budget_1')),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(categoriesProvider.notifier);

      // Even though syncVaultToCloud() never completes unless syncCompleter finishes,
      // addCategory must complete immediately and update in-memory state.
      final created = await notifier
          .addCategory(
            name: 'Coffee',
            balance: 25.0,
            colorHex: '#10B981',
            iconName: 'coffee',
            allocationType: AllocationType.fixedCheck,
            allocationValue: 25.0,
          )
          .timeout(const Duration(seconds: 2));

      expect(created, isNotNull);
      expect(created!.name, 'Coffee');
      final currentCats = container.read(categoriesProvider);
      expect(currentCats.any((c) => c.id == created.id && c.name == 'Coffee'), isTrue);
      expect(slowPb.syncCalls, greaterThanOrEqualTo(1));

      // Cleanly complete the background future
      slowPb.syncCompleter.complete();
    });

    testWidgets('Delete Account tile opens confirmation dialog requiring DELETE to enable button', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith((ref) => MockCategoriesNotifier([])),
            transactionsProvider.overrideWith((ref) => MockTransactionsNotifier([])),
            budgetsListProvider.overrideWith((ref) => MockBudgetsListNotifier([Budget(id: 'b1', name: 'Personal')])),
            activeBudgetIdProvider.overrideWith((ref) => MockActiveBudgetIdNotifier('b1')),
            latestReleaseProvider.overrideWith((ref) => null),
            hasUpdateProvider.overrideWith((ref) => false),
            currentAppVersionProvider.overrideWith((ref) => '1.0.19'),
          ],
          child: const MaterialApp(
            home: SettingsView(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll to and tap Delete Account tile
      final deleteTile = find.text('Delete Account');
      await tester.ensureVisible(deleteTile);
      await tester.pumpAndSettle();
      await tester.tap(deleteTile);
      await tester.pumpAndSettle();

      // Verify confirmation dialog renders cleanly
      expect(find.text('Delete Account?'), findsOneWidget);
      expect(find.textContaining('permanently erase all local and cloud-synced budgets'), findsOneWidget);
      expect(find.text('Type DELETE to confirm:'), findsOneWidget);

      // Button should be disabled before typing DELETE
      final confirmButtonFinder = find.widgetWithText(ElevatedButton, 'Delete Account');
      expect(confirmButtonFinder, findsOneWidget);
      expect(tester.widget<ElevatedButton>(confirmButtonFinder).onPressed, isNull);

      // Typing partial text keeps it disabled
      await tester.enterText(find.byType(TextField), 'DEL');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(confirmButtonFinder).onPressed, isNull);

      // Typing DELETE enables the confirmation button
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(confirmButtonFinder).onPressed, isNotNull);

      // Cancel closes the dialog cleanly
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Account?'), findsNothing);
    });

    testWidgets('Envelope card rule labels format cleanly without duplicate preceding symbols', (WidgetTester tester) async {
      final catPercent = Category(
        id: 'c1',
        name: 'Savings',
        balance: 100.0,
        colorHex: '#10B981',
        iconName: 'savings',
        allocationType: AllocationType.percentCheck,
        allocationValue: 10.0,
        user: 'u1',
      );

      final catFixed = Category(
        id: 'c2',
        name: 'Rent',
        balance: 500.0,
        colorHex: '#6366F1',
        iconName: 'rent',
        allocationType: AllocationType.fixedCheck,
        allocationValue: 100.0,
        user: 'u1',
      );

      final catTarget = Category(
        id: 'c3',
        name: 'Groceries',
        balance: 50.0,
        colorHex: '#06B6D4',
        iconName: 'cart',
        allocationType: AllocationType.monthlyTarget,
        allocationValue: 50.0,
        user: 'u1',
      );

      final catManual = Category(
        id: 'c4',
        name: 'Entertainment',
        balance: 20.0,
        colorHex: '#F59E0B',
        iconName: 'games',
        allocationType: AllocationType.manual,
        allocationValue: 0.0,
        user: 'u1',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith((ref) => MockCategoriesNotifier([catPercent, catFixed, catTarget, catManual])),
            transactionsProvider.overrideWith((ref) => MockTransactionsNotifier([])),
            budgetsListProvider.overrideWith((ref) => MockBudgetsListNotifier([Budget(id: 'b1', name: 'Personal')])),
            activeBudgetIdProvider.overrideWith((ref) => MockActiveBudgetIdNotifier('b1')),
          ],
          child: const MaterialApp(
            home: DashboardView(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Check clean rule formatting in envelope cards
      expect(find.text('10% of Check'), findsOneWidget);
      expect(find.text('\$100 Per Check'), findsOneWidget);
      expect(find.text('\$50/mo Target'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);

      // Verify no duplicate preceding "% 10% of check" or "$ $100 per check" or "Fixed $50/mo"
      expect(find.text('% 10% of check'), findsNothing);
      expect(find.text('\$ \$100 per check'), findsNothing);
      expect(find.text('Fixed \$50/mo'), findsNothing);
    });
  });
}
