import 'dart:math';
import '../models/transaction_model.dart';
import '../models/bank_sync_config.dart';

class ParsedStatement {
  final String merchant;
  final double amount;
  final TransactionType type;
  final double? reportedBalance;
  final String rawSnippet;
  final DateTime? extractedDate;

  const ParsedStatement({
    required this.merchant,
    required this.amount,
    required this.type,
    this.reportedBalance,
    required this.rawSnippet,
    this.extractedDate,
  });

  /// Evaluates balance verification math against current total app balance.
  /// Returns a tuple of: (hasDiscrepancy, discrepancyAmount, expectedBalance).
  (bool hasDiscrepancy, double discrepancy, double expectedBalance) verifyAgainstAppBalance(
    double currentAppBalance,
  ) {
    if (reportedBalance == null) {
      return (false, 0.0, currentAppBalance);
    }

    final double expected;
    if (type == TransactionType.income) {
      expected = currentAppBalance + amount.abs();
    } else {
      expected = currentAppBalance - amount.abs();
    }

    final diff = ((expected - reportedBalance!) * 100).roundToDouble() / 100;
    final hasDiscrepancy = diff.abs() > 0.01;

    return (hasDiscrepancy, diff, expected);
  }
}

class BankStatementParser {
  /// Parses raw email text / subject into a structured [ParsedStatement].
  /// Returns null if no transaction amount could be found.
  static ParsedStatement? parseEmail({
    required String textContent,
    String? subject,
    BankSyncConfig config = const BankSyncConfig(),
  }) {
    final fullText = subject != null && subject.isNotEmpty
        ? '$subject\n\n$textContent'
        : textContent;

    // 1. Extract Amount (always preceded by $)
    // Handles formats like $1,833.22, $45.67, etc.
    final dollarAmountRegex = RegExp(
      r'\$\s*([0-9,]+\.[0-9]{2})',
      caseSensitive: false,
    );
    // Fallback if no $ found: look for USD / CAD / amount:
    final fallbackAmountRegex = RegExp(
      r'(?:USD\s*|CAD\s*|amount\s*[:\-]?\s*\$?)\s*([0-9,]+\.[0-9]{2})',
      caseSensitive: false,
    );
    
    Match? amountMatch = dollarAmountRegex.firstMatch(fullText);
    amountMatch ??= fallbackAmountRegex.firstMatch(fullText);

    if (amountMatch == null) {
      return null;
    }

    final rawAmountStr = amountMatch.group(1)!.replaceAll(',', '');
    final double amount = double.tryParse(rawAmountStr) ?? 0.0;
    if (amount <= 0.0) {
      return null;
    }

    // 2. Transaction Type (Income vs Expense / Deposits vs Withdrawals)
    // If "withdrawls" or "withdrawal" or "withdraw" is present -> expense.
    // If "deposits" or "deposit" is present -> income.
    final lowerText = fullText.toLowerCase();
    final bool hasWithdrawalKeyword = lowerText.contains('withdrawl') ||
        lowerText.contains('withdrawal') ||
        lowerText.contains('withdrew') ||
        lowerText.contains('debit') ||
        lowerText.contains('spent') ||
        lowerText.contains('charge') ||
        lowerText.contains('purchase');

    final bool hasDepositKeyword = lowerText.contains('deposit') ||
        lowerText.contains('payroll') ||
        lowerText.contains('paycheck') ||
        lowerText.contains('refund') ||
        lowerText.contains('credit applied') ||
        lowerText.contains('direct deposit');

    TransactionType txType;
    if (hasDepositKeyword && !hasWithdrawalKeyword) {
      txType = TransactionType.income;
    } else if (hasWithdrawalKeyword && !hasDepositKeyword) {
      txType = TransactionType.expense;
    } else if (lowerText.contains('deposit')) {
      // If both appear (e.g. statement template listing both headers), check proximity to amount
      final depositIdx = lowerText.indexOf('deposit');
      final withdrawalIdx = lowerText.indexOf('withdraw');
      final amtIdx = amountMatch.start;
      final distToDeposit = (depositIdx - amtIdx).abs();
      final distToWithdraw = (withdrawalIdx - amtIdx).abs();
      txType = distToDeposit < distToWithdraw ? TransactionType.income : TransactionType.expense;
    } else {
      txType = TransactionType.expense;
    }

    // 3. Extract Merchant / Description (occurs before the amount / preceded by transaction info)
    String merchant = 'Unknown Merchant';
    
    // Check if there is text before the amount in the same line or immediate context
    final amountStartIndex = amountMatch.start;
    final textBeforeAmount = fullText.substring(0, amountStartIndex).trim();

    // Standard merchant patterns
    final merchantPatterns = [
      // "at [Merchant] on/for/date"
      RegExp(r"(?:at|from|to|charge\s+at|purchase\s+at|payment\s+to|charged\s+at)\s+([A-Za-z0-9\s#\&\-\.\*'\/]+?)(?:\s+on|\s+for|\s+date|\s+\.|\n|\r|$)", caseSensitive: false),
      // "authorized a $X charge at [Merchant]"
      RegExp(r"charge\s+at\s+([A-Za-z0-9\s#\&\-\.\*'\/]+?)(?:\s+has|\s+was|\.|\n|\r|$)", caseSensitive: false),
      // "card was used at [Merchant]"
      RegExp(r"used\s+at\s+([A-Za-z0-9\s#\&\-\.\*'\/]+?)(?:\s+on|\.|\n|\r|$)", caseSensitive: false),
    ];

    for (final pattern in merchantPatterns) {
      final match = pattern.firstMatch(fullText);
      if (match != null) {
        final extracted = match.group(1)?.trim();
        if (extracted != null && extracted.isNotEmpty && extracted.length > 1) {
          // Clean up unwanted trailing prepositions & verbs
          merchant = extracted
              .replaceAll(RegExp(r'\s+(on|for|with|using|was|has|is)(\s+authorized|\s+declined|\s+approved|\s+made)?$', caseSensitive: false), '')
              .replaceAll(RegExp(r'\s+(was\s+authorized|has\s+been\s+authorized|was\s+declined|was\s+approved)$', caseSensitive: false), '')
              .trim();
          break;
        }
      }
    }

    if (merchant == 'Unknown Merchant' && textBeforeAmount.isNotEmpty) {
      // Split into lines and inspect backwards from the amount
      final lines = textBeforeAmount
          .split(RegExp(r'[\r\n]+'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      for (int i = lines.length - 1; i >= 0; i--) {
        String candidate = lines[i];
        // Strip out dates
        candidate = candidate
            .replaceAll(RegExp(r'\b(?:on|date)\s*[:\-]?\s*[0-9]{1,2}[\/\-][0-9]{1,2}(?:[\/\-][0-9]{2,4})?\b', caseSensitive: false), '')
            .replaceAll(RegExp(r'\b[0-9]{1,2}[\/\-][0-9]{1,2}(?:[\/\-][0-9]{2,4})?\b'), '')
            .trim();

        // Strip leading keywords like "Withdrawls:", "Deposits:", "Description:", "Memo:"
        candidate = candidate
            .replaceAll(RegExp(r'^(?:description|desc|memo|merchant|transaction|withdraw(?:a)?ls?|deposits?|paid\s+to|received\s+from)\s*[:\-]?\s*', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s*[:\-]\s*$'), '')
            .trim();

        // Skip generic header lines like "Transaction Alert", "Account Activity", etc.
        final isGenericHeader = RegExp(
          r'^(?:transaction\s+alert|account\s+activity|bank\s+alert|notification|activity\s+alert|direct\s+deposit\s+notification)$',
          caseSensitive: false,
        ).hasMatch(candidate);

        if (candidate.isNotEmpty && !isGenericHeader) {
          merchant = candidate.substring(0, min(candidate.length, 60)).trim();
          break;
        }
      }
    }

    // 4. Extract Current Balance (Configurable Rule, allows raw number with no $)
    double? reportedBalance;
    final balancePatternStr = config.balancePattern.isNotEmpty
        ? config.balancePattern
        : r'(?:Current\s+balance|Available\s+balance|Bal|Balance|Remaining\s+balance)\s*[:\-]?\s*([0-9,]+\.[0-9]{2})';

    try {
      final balanceRegex = RegExp(balancePatternStr, caseSensitive: false);
      final balanceMatch = balanceRegex.firstMatch(fullText);
      if (balanceMatch != null && balanceMatch.groupCount >= 1) {
        final balStr = balanceMatch.group(1)!.replaceAll(',', '');
        reportedBalance = double.tryParse(balStr);
      }
    } catch (_) {
      // Ignore regex compile error and fallback
    }

    // 5. Extract Date (e.g. MM/DD/YYYY, MM/DD/YY, Nov 3, 2026, etc.)
    DateTime? extractedDate;
    final dateMatch = RegExp(r'\b(0?[1-9]|1[0-2])[\/\-](0?[1-9]|[12]\d|3[01])[\/\-](\d{2,4})\b').firstMatch(fullText);
    if (dateMatch != null) {
      try {
        final month = int.parse(dateMatch.group(1)!);
        final day = int.parse(dateMatch.group(2)!);
        int year = int.parse(dateMatch.group(3)!);
        if (year < 100) year += 2000;
        extractedDate = DateTime(year, month, day);
      } catch (_) {}
    }

    // Snippet for audit/preview
    final snippet = fullText.length > 200 ? '${fullText.substring(0, 200)}...' : fullText;

    return ParsedStatement(
      merchant: merchant,
      amount: amount,
      type: txType,
      reportedBalance: reportedBalance,
      rawSnippet: snippet,
      extractedDate: extractedDate,
    );
  }
}
