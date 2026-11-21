import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_app/models/app_release.dart';
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/models/undo_action.dart';
import 'package:budget_app/providers/budgets_provider.dart';
import 'package:budget_app/providers/categories_provider.dart';
import 'package:budget_app/providers/releases_provider.dart';
import 'package:budget_app/providers/transactions_provider.dart';
import 'package:budget_app/utils/app_theme.dart';
import 'package:budget_app/views/dashboard_view.dart';
import 'package:budget_app/views/landing_view.dart';
import 'package:budget_app/views/settings_view.dart';

class _MockCategoriesNotifier extends StateNotifier<List<Category>>
    implements CategoriesNotifier {
  _MockCategoriesNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockTransactionsNotifier extends StateNotifier<List<TransactionModel>>
    implements TransactionsNotifier {
  _MockTransactionsNotifier(super.state);

  @override
  UndoAction? get lastUndoAction => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockBudgetsListNotifier extends StateNotifier<List<Budget>>
    implements BudgetsListNotifier {
  _MockBudgetsListNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockActiveBudgetIdNotifier extends StateNotifier<String>
    implements ActiveBudgetIdNotifier {
  _MockActiveBudgetIdNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _sampleCategories = <Category>[
  Category(
    id: 'unalloc',
    name: 'Unallocated',
    iconName: 'account_balance_wallet',
    colorHex: '#64748B',
    balance: 420.50,
    allocationType: AllocationType.manual,
    allocationValue: 0,
    user: 'test_user',
  ),
  Category(
    id: 'c1',
    name: 'Groceries & Household Essentials',
    iconName: 'shopping_cart',
    colorHex: '#10B981',
    balance: 315.25,
    allocationType: AllocationType.percentCheck,
    allocationValue: 15,
    user: 'test_user',
  ),
  Category(
    id: 'c2',
    name: 'Rent & Utilities',
    iconName: 'home',
    colorHex: '#6366F1',
    balance: 1450.00,
    allocationType: AllocationType.monthlyTarget,
    allocationValue: 1600,
    user: 'test_user',
  ),
  Category(
    id: 'c3',
    name: 'Dining Out',
    iconName: 'restaurant',
    colorHex: '#F59E0B',
    balance: 92.00,
    allocationType: AllocationType.fixedCheck,
    allocationValue: 75,
    user: 'test_user',
  ),
];

const _viewports = <String, Size>{
  'Flip (320x650)': Size(320, 650),
  'Mobile (390x844)': Size(390, 844),
  'Fold unfolded (700x840)': Size(700, 840),
  'iPad (820x1180)': Size(820, 1180),
  'Desktop (1280x800)': Size(1280, 800),
};

Future<void> _pumpAtSize(
  WidgetTester tester,
  Size size,
  Widget child,
) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
  };

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;

  try {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith((ref) => _MockCategoriesNotifier(_sampleCategories)),
          transactionsProvider.overrideWith((ref) => _MockTransactionsNotifier([])),
          budgetsListProvider.overrideWith(
            (ref) => _MockBudgetsListNotifier([Budget(id: 'b1', name: 'Family Primary Budget')]),
          ),
          activeBudgetIdProvider.overrideWith((ref) => _MockActiveBudgetIdNotifier('b1')),
          latestReleaseProvider.overrideWith((ref) => null),
          hasUpdateProvider.overrideWith((ref) => false),
          currentAppVersionProvider.overrideWith((ref) => '1.0.20'),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  } finally {
    FlutterError.onError = previousOnError;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  expect(
    errors,
    isEmpty,
    reason: 'Unexpected Flutter/overflow errors at ${size.width}x${size.height}: '
        '${errors.map((e) => e.exceptionAsString()).join('\n')}',
  );
}

void main() {
  group('Responsive Layout Audit', () {
    for (final entry in _viewports.entries) {
      final label = entry.key;
      final size = entry.value;

      testWidgets('DashboardView renders cleanly with zero overflows on $label',
          (tester) async {
        await _pumpAtSize(tester, size, const DashboardView());

        expect(find.text('Budget Envelopes'), findsOneWidget);
        expect(find.text('Groceries & Household Essentials'), findsOneWidget);

        // Verify the scrollable body fills the viewport and is NOT collapsed/crammed at the top
        final scrollViewRect = tester.getRect(find.byType(SingleChildScrollView));
        expect(
          scrollViewRect.height,
          greaterThan(size.height * 0.5),
          reason: 'DashboardView body collapsed on $label (height=${scrollViewRect.height})',
        );

        // Verify bottom action bar stays at the bottom and does not overlap AppBar/Settings
        final addIncomeRect = tester.getRect(find.text('Add Income'));
        final settingsRect = tester.getRect(find.byTooltip('Settings'));
        expect(
          addIncomeRect.top,
          greaterThan(size.height * 0.75),
          reason: 'Bottom action bar should sit near bottom on $label (top=${addIncomeRect.top})',
        );
        expect(
          settingsRect.bottom,
          lessThan(addIncomeRect.top),
          reason: 'Settings button should be above bottom action bar on $label',
        );

        if (size.width >= 600) {
          final gridFinder = find.byType(GridView);
          expect(gridFinder, findsOneWidget);
          final grid = tester.widget<GridView>(gridFinder);
          final delegate =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          final expectedCols = size.width >= 1000 ? 3 : 2;
          expect(delegate.crossAxisCount, expectedCols);
        } else {
          expect(find.byType(ReorderableListView), findsOneWidget);
        }
      });

      testWidgets('SettingsView renders cleanly with zero overflows on $label',
          (tester) async {
        await _pumpAtSize(tester, size, const SettingsView());

        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Appearance'), findsOneWidget);
      });

      testWidgets('LandingView renders cleanly with zero overflows on $label',
          (tester) async {
        await _pumpAtSize(tester, size, const LandingView());

        expect(find.text('StiQRbudget'), findsOneWidget);
        expect(find.text('Sign In / Get Started'), findsOneWidget);
      });
    }

    testWidgets('SettingsView footer displays running app version 1.0.20 even if latestRelease is older',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final olderRelease = AppRelease(
        id: 'rel_1019',
        version: 'v1.0.19',
        releaseDate: DateTime(2026, 11, 1),
        apkFileName: 'app-release.apk',
        apkUrl: 'https://example.com/app.apk',
        changelog: 'Older APK',
        isLatest: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith((ref) => _MockCategoriesNotifier(_sampleCategories)),
            transactionsProvider.overrideWith((ref) => _MockTransactionsNotifier([])),
            budgetsListProvider.overrideWith(
              (ref) => _MockBudgetsListNotifier([Budget(id: 'b1', name: 'Family Primary Budget')]),
            ),
            activeBudgetIdProvider.overrideWith((ref) => _MockActiveBudgetIdNotifier('b1')),
            latestReleaseProvider.overrideWith((ref) => olderRelease),
            hasUpdateProvider.overrideWith((ref) => false),
            currentAppVersionProvider.overrideWith((ref) => '1.0.20'),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const SettingsView(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('StiqrBudget v1.0.20'), findsOneWidget);
      expect(find.text('StiqrBudget v1.0.19'), findsNothing);
    });
  });
}
