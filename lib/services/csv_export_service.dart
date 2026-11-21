import 'package:intl/intl.dart';
import '../models/category.dart';
import '../models/transaction_model.dart';

class EnvelopeProgressResult {
  final double monthlyBaseline;
  final int percentLeft;
  final double progressBarValue;
  final String progressLabel;

  const EnvelopeProgressResult({
    required this.monthlyBaseline,
    required this.percentLeft,
    required this.progressBarValue,
    required this.progressLabel,
  });
}

class CsvExportService {
  /// Calculates the monthly baseline, percentage left, progress bar value, and label
  /// for a given category envelope.
  static EnvelopeProgressResult calculateEnvelopeProgress({
    required Category category,
    required List<TransactionModel> transactions,
    required double expectedIncome,
    required int paychecksPerMonth,
    DateTime? nowOverride,
  }) {
    final currencyFormat = NumberFormat.simpleCurrency();
    double monthlyBaseline = 0.0;

    if (category.allocationValue > 0) {
      switch (category.allocationType) {
        case AllocationType.monthlyTarget:
          monthlyBaseline = category.allocationValue;
          break;
        case AllocationType.fixedCheck:
          monthlyBaseline = category.allocationValue * paychecksPerMonth;
          break;
        case AllocationType.percentCheck:
          monthlyBaseline = expectedIncome * (category.allocationValue / 100.0);
          break;
        case AllocationType.manual:
          monthlyBaseline = 0.0;
          break;
      }
    }

    if (monthlyBaseline <= 0) {
      // Manual rule or 0 rule value: sum of positive inflows/allocations to this category this month
      final now = nowOverride ?? DateTime.now();
      final firstOfMonth = DateTime(now.year, now.month, 1);
      monthlyBaseline = transactions
          .where((tx) =>
              tx.amount > 0 &&
              !tx.date.isBefore(firstOfMonth) &&
              ((tx.type == TransactionType.transfer && tx.destinationCategory == category.id) ||
                  (tx.type == TransactionType.income && tx.category == category.id)))
          .fold<double>(0.0, (sum, tx) => sum + tx.amount);
    }

    int percentLeft;
    double progressBarValue;
    String progressLabel;

    if (category.balance <= 0) {
      percentLeft = 0;
      progressBarValue = 0.0;
      if (monthlyBaseline > 0) {
        progressLabel =
            '${currencyFormat.format(category.balance)} of ${currencyFormat.format(monthlyBaseline)} / mo';
      } else {
        progressLabel = '${currencyFormat.format(category.balance)} available';
      }
    } else if (monthlyBaseline > 0) {
      final rawRatio = category.balance / monthlyBaseline;
      percentLeft = (rawRatio * 100).round();
      progressBarValue = rawRatio.clamp(0.0, 1.0);
      progressLabel =
          '${currencyFormat.format(category.balance)} of ${currencyFormat.format(monthlyBaseline)} / mo';
    } else {
      percentLeft = 100;
      progressBarValue = 1.0;
      progressLabel = '${currencyFormat.format(category.balance)} available';
    }

    return EnvelopeProgressResult(
      monthlyBaseline: monthlyBaseline,
      percentLeft: percentLeft,
      progressBarValue: progressBarValue,
      progressLabel: progressLabel,
    );
  }

  /// Generates a clean, comprehensive CSV containing current Envelopes and Transactions.
  static String generateBudgetCsv({
    required String budgetName,
    required List<Category> categories,
    required List<TransactionModel> transactions,
  }) {
    final buffer = StringBuffer();
    final categoryMap = <String, String>{};
    for (final cat in categories) {
      categoryMap[cat.id] = cat.name;
    }

    // Section 1: Envelopes Summary
    buffer.writeln(_csvRow(['Budget Name', budgetName]));
    buffer.writeln(_csvRow(['Export Date', DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())]));
    buffer.writeln();
    buffer.writeln(_csvRow(['=== ENVELOPES SUMMARY ===']));
    buffer.writeln(_csvRow([
      'Category Name',
      'Current Balance',
      'Allocation Rule',
      'Allocation Value',
    ]));

    // Ensure Unallocated is listed clearly alongside all other envelopes
    final unallocated = categories.where((c) => c.isUnallocated).toList();
    final others = categories.where((c) => !c.isUnallocated).toList();

    for (final cat in [...others, ...unallocated]) {
      buffer.writeln(_csvRow([
        cat.name,
        cat.balance.toStringAsFixed(2),
        cat.isUnallocated ? 'System Unallocated' : _formatAllocationRule(cat.allocationType),
        cat.allocationValue.toStringAsFixed(2),
      ]));
    }

    final totalBalance = categories.fold<double>(0.0, (sum, c) => sum + c.balance);
    buffer.writeln(_csvRow([
      'Total Cash Pool',
      totalBalance.toStringAsFixed(2),
      '',
      '',
    ]));

    buffer.writeln();
    buffer.writeln(_csvRow(['=== TRANSACTION HISTORY ===']));
    buffer.writeln(_csvRow([
      'Date',
      'Type',
      'Description',
      'Amount',
      'Source Envelope',
      'Destination/Category Envelope',
      'Payee/Notes',
    ]));

    // Sort transactions newest first
    final sortedTxs = List<TransactionModel>.from(transactions)
      ..sort((a, b) => b.date.compareTo(a.date));

    final dateFormatter = DateFormat('yyyy-MM-dd HH:mm');

    for (final tx in sortedTxs) {
      final dateStr = dateFormatter.format(tx.date);
      final typeStr = _formatTransactionType(tx.type);
      String sourceEnv = '';
      String destEnv = '';

      if (tx.type == TransactionType.transfer) {
        sourceEnv = tx.sourceCategory != null
            ? (categoryMap[tx.sourceCategory!] ?? tx.sourceCategory!)
            : '';
        destEnv = tx.destinationCategory != null
            ? (categoryMap[tx.destinationCategory!] ?? tx.destinationCategory!)
            : '';
      } else if (tx.type == TransactionType.expense) {
        sourceEnv = tx.category != null
            ? (categoryMap[tx.category!] ?? tx.category!)
            : '';
        destEnv = sourceEnv;
      } else if (tx.type == TransactionType.income) {
        destEnv = tx.category != null
            ? (categoryMap[tx.category!] ?? tx.category!)
            : (tx.destinationCategory != null
                ? (categoryMap[tx.destinationCategory!] ?? tx.destinationCategory!)
                : 'Unallocated');
      }

      final notesParts = <String>[];
      if (tx.statementEmailSender != null && tx.statementEmailSender!.isNotEmpty) {
        notesParts.add('From: ${tx.statementEmailSender}');
      }
      if (tx.rawEmailSnippet != null && tx.rawEmailSnippet!.isNotEmpty) {
        notesParts.add(tx.rawEmailSnippet!);
      }
      final notes = notesParts.isEmpty ? tx.description : notesParts.join(' | ');

      buffer.writeln(_csvRow([
        dateStr,
        typeStr,
        tx.description,
        tx.amount.toStringAsFixed(2),
        sourceEnv,
        destEnv,
        notes,
      ]));
    }

    return buffer.toString();
  }

  static String _formatAllocationRule(AllocationType type) {
    switch (type) {
      case AllocationType.monthlyTarget:
        return 'Monthly Target';
      case AllocationType.fixedCheck:
        return 'Fixed per Check';
      case AllocationType.percentCheck:
        return 'Percent of Check';
      case AllocationType.manual:
        return 'Manual';
    }
  }

  static String _formatTransactionType(TransactionType type) {
    switch (type) {
      case TransactionType.income:
        return 'Income';
      case TransactionType.expense:
        return 'Expense';
      case TransactionType.transfer:
        return 'Transfer';
    }
  }

  static String _csvRow(List<String> fields) {
    return fields.map(_escapeCsvField).join(',');
  }

  static String _escapeCsvField(String field) {
    if (field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      final escaped = field.replaceAll('"', '""');
      return '"$escaped"';
    }
    return field;
  }
}
