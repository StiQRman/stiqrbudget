import 'package:flutter_test/flutter_test.dart';
import 'package:budget_app/models/bank_sync_config.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/services/bank_statement_parser.dart';

void main() {
  group('BankStatementParser Tests', () {
    test('Parses bank alert with current balance as raw number (no dollar sign)', () {
      const email = '''
Chase Alert:
A charge of \$45.50 at Trader Joe's was authorized on card ...1234.
Current balance 1250.45
Thank you for banking with Chase.
''';

      final statement = BankStatementParser.parseEmail(
        textContent: email,
        subject: 'Chase Transaction Alert',
      );

      expect(statement, isNotNull);
      expect(statement!.merchant, equals("Trader Joe's"));
      expect(statement.amount, equals(45.50));
      expect(statement.type, equals(TransactionType.expense));
      expect(statement.reportedBalance, equals(1250.45));
    });

    test('Verifies balance math matching perfectly', () {
      const email = '''
Purchase at Chevron for \$50.00.
Available balance: 950.00
''';

      final statement = BankStatementParser.parseEmail(textContent: email);
      expect(statement, isNotNull);
      expect(statement!.amount, equals(50.00));
      expect(statement.reportedBalance, equals(950.00));

      // App balance prior to transaction was $1000.00
      // 1000.00 - 50.00 = 950.00 -> should match!
      final (hasDiscrepancy, diff, expected) = statement.verifyAgainstAppBalance(1000.00);
      expect(hasDiscrepancy, isFalse);
      expect(diff, equals(0.0));
      expect(expected, equals(950.00));
    });

    test('Detects balance math discrepancy and flags error when math does not match', () {
      const email = '''
Debit card charge at Target for \$30.00.
Current balance 800.00
''';

      final statement = BankStatementParser.parseEmail(textContent: email);
      expect(statement, isNotNull);
      expect(statement!.reportedBalance, equals(800.00));

      // App balance prior to transaction was $900.00
      // Expected = 900.00 - 30.00 = 870.00.
      // But bank says 800.00! ($70 discrepancy)
      final (hasDiscrepancy, diff, expected) = statement.verifyAgainstAppBalance(900.00);
      expect(hasDiscrepancy, isTrue);
      expect(expected, equals(870.00));
      expect(diff, equals(70.00)); // Expected 870, reported 800 -> diff 70
    });

    test('Custom balance pattern works with different bank phrasing', () {
      const config = BankSyncConfig(
        balancePattern: r'Remaining\s*[:=]\s*([0-9,]+\.[0-9]{2})',
      );

      const email = '''
Spent \$14.99 at Spotify.
Remaining = 425.80
''';

      final statement = BankStatementParser.parseEmail(
        textContent: email,
        config: config,
      );

      expect(statement, isNotNull);
      expect(statement!.amount, equals(14.99));
      expect(statement.reportedBalance, equals(425.80));
    });

    test('Parses Withdrawls as expense with dollar formatted amount and leading description', () {
      const email = '''
Transaction Alert
Date: 11/03/2026
Safeway Store #1234
Withdrawls: \$1,833.22
Current balance 5420.10
''';

      final statement = BankStatementParser.parseEmail(
        textContent: email,
        subject: 'Bank Account Activity Alert',
      );

      expect(statement, isNotNull);
      expect(statement!.amount, equals(1833.22));
      expect(statement.type, equals(TransactionType.expense));
      expect(statement.merchant, contains('Safeway Store #1234'));
      expect(statement.reportedBalance, equals(5420.10));
      expect(statement.extractedDate, equals(DateTime(2026, 11, 3)));
    });

    test('Parses Deposits as income with dollar formatted amount and leading description', () {
      const email = '''
Direct Deposit Notification
Payroll Acme Corp
Deposits: \$2,500.00
Current balance 7920.10
''';

      final statement = BankStatementParser.parseEmail(
        textContent: email,
        subject: 'Deposit Notification',
      );

      expect(statement, isNotNull);
      expect(statement!.amount, equals(2500.00));
      expect(statement.type, equals(TransactionType.income));
      expect(statement.merchant, contains('Payroll Acme Corp'));
      expect(statement.reportedBalance, equals(7920.10));
    });
  });
}
