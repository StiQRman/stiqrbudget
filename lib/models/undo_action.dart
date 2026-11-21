class UndoAction {
  final String description;
  final List<String> createdTransactionIds;
  final List<UpdatedTransactionInfo> updatedTransactions;
  final Map<String, double> categoryBalanceChanges;
  final String? createdRuleId;

  UndoAction({
    required this.description,
    required this.createdTransactionIds,
    required this.updatedTransactions,
    required this.categoryBalanceChanges,
    this.createdRuleId,
  });

  Map<String, dynamic> toJson() {
    return {
      'description': description,
      'createdTransactionIds': createdTransactionIds,
      'updatedTransactions': updatedTransactions.map((tx) => tx.toJson()).toList(),
      'categoryBalanceChanges': categoryBalanceChanges,
      'createdRuleId': createdRuleId,
    };
  }

  factory UndoAction.fromJson(Map<String, dynamic> json) {
    final Map<String, double> changes = {};
    if (json['categoryBalanceChanges'] != null) {
      (json['categoryBalanceChanges'] as Map<String, dynamic>).forEach((key, val) {
        changes[key] = (val as num).toDouble();
      });
    }

    return UndoAction(
      description: json['description'] ?? '',
      createdTransactionIds: List<String>.from(json['createdTransactionIds'] ?? []),
      updatedTransactions: (json['updatedTransactions'] as List<dynamic>?)
              ?.map((item) => UpdatedTransactionInfo.fromJson(item))
              .toList() ??
          [],
      categoryBalanceChanges: changes,
      createdRuleId: json['createdRuleId'],
    );
  }
}

class UpdatedTransactionInfo {
  final String transactionId;
  final String? originalCategory;
  final double originalAmount;

  UpdatedTransactionInfo({
    required this.transactionId,
    this.originalCategory,
    required this.originalAmount,
  });

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'originalCategory': originalCategory,
      'originalAmount': originalAmount,
    };
  }

  factory UpdatedTransactionInfo.fromJson(Map<String, dynamic> json) {
    return UpdatedTransactionInfo(
      transactionId: json['transactionId'] ?? '',
      originalCategory: json['originalCategory'],
      originalAmount: (json['originalAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
