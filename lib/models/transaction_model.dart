enum TransactionType {
  income,
  expense,
  transfer,
}

class TransactionModel {
  final String id;
  final String description;
  final double amount;
  final TransactionType type;
  final String? category; // ID of the category (for expenses/income)
  final String? sourceCategory; // ID of the source category (for transfers)
  final String? destinationCategory; // ID of the destination category (for transfers)
  final DateTime date;
  final String user;
  final double? reportedBalance;
  final double? balanceDiscrepancy;
  final bool hasBalanceWarning;
  final String? statementEmailSender;
  final String? rawEmailSnippet;

  TransactionModel({
    required this.id,
    required this.description,
    required double amount,
    required this.type,
    this.category,
    this.sourceCategory,
    this.destinationCategory,
    required this.date,
    required this.user,
    this.reportedBalance,
    this.balanceDiscrepancy,
    this.hasBalanceWarning = false,
    this.statementEmailSender,
    this.rawEmailSnippet,
  }) : amount = ((amount * 100).roundToDouble() / 100);

  static bool useAmoutTypo = false;

  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('amout')) {
      useAmoutTypo = true;
    }
    
    TransactionType parseTransactionType(String? val) {
      switch (val) {
        case 'income':
          return TransactionType.income;
        case 'transfer':
          return TransactionType.transfer;
        case 'expense':
        default:
          return TransactionType.expense;
      }
    }

    double parseDouble(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    double? parseOptionalDouble(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val);
      return null;
    }

    final rawAmount = json['amount'] ?? json['amout'];
    final rawCat = json['category'] as String?;
    final rawSource = json['source_category'] as String?;
    final rawDest = json['destination_category'] as String?;

    return TransactionModel(
      id: json['id'] ?? '',
      description: json['description'] ?? '',
      amount: parseDouble(rawAmount),
      type: parseTransactionType(json['type']),
      category: (rawCat == null || rawCat.isEmpty) ? null : rawCat,
      sourceCategory: (rawSource == null || rawSource.isEmpty) ? null : rawSource,
      destinationCategory: (rawDest == null || rawDest.isEmpty) ? null : rawDest,
      date: json['date'] != null ? (DateTime.tryParse(json['date'].toString()) ?? DateTime.now()) : DateTime.now(),
      user: json['user'] ?? '',
      reportedBalance: parseOptionalDouble(json['reported_balance']),
      balanceDiscrepancy: parseOptionalDouble(json['balance_discrepancy']),
      hasBalanceWarning: (json['has_balance_warning'] as bool?) ?? false,
      statementEmailSender: json['statement_email_sender'] as String?,
      rawEmailSnippet: json['raw_email_snippet'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    String typeToString(TransactionType val) {
      switch (val) {
        case TransactionType.income:
          return 'income';
        case TransactionType.transfer:
          return 'transfer';
        case TransactionType.expense:
          return 'expense';
      }
    }

    return {
      if (id.isNotEmpty) 'id': id,
      'description': description,
      'amount': amount,
      'amout': amount,
      'type': typeToString(type),
      'category': category,
      'source_category': sourceCategory,
      'destination_category': destinationCategory,
      'date': date.toIso8601String(),
      'user': user,
      if (reportedBalance != null) 'reported_balance': reportedBalance,
      if (balanceDiscrepancy != null) 'balance_discrepancy': balanceDiscrepancy,
      'has_balance_warning': hasBalanceWarning,
      if (statementEmailSender != null) 'statement_email_sender': statementEmailSender,
      if (rawEmailSnippet != null) 'raw_email_snippet': rawEmailSnippet,
    };
  }

  TransactionModel copyWith({
    String? id,
    String? description,
    double? amount,
    TransactionType? type,
    String? category,
    String? sourceCategory,
    String? destinationCategory,
    DateTime? date,
    String? user,
    double? reportedBalance,
    double? balanceDiscrepancy,
    bool? hasBalanceWarning,
    String? statementEmailSender,
    String? rawEmailSnippet,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      description: description ?? this.description,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      category: category ?? this.category,
      sourceCategory: sourceCategory ?? this.sourceCategory,
      destinationCategory: destinationCategory ?? this.destinationCategory,
      date: date ?? this.date,
      user: user ?? this.user,
      reportedBalance: reportedBalance ?? this.reportedBalance,
      balanceDiscrepancy: balanceDiscrepancy ?? this.balanceDiscrepancy,
      hasBalanceWarning: hasBalanceWarning ?? this.hasBalanceWarning,
      statementEmailSender: statementEmailSender ?? this.statementEmailSender,
      rawEmailSnippet: rawEmailSnippet ?? this.rawEmailSnippet,
    );
  }
}
