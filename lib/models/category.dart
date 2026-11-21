enum AllocationType {
  manual,
  percentCheck,
  fixedCheck,
  monthlyTarget,
}

class BudgetCategoryHelper {
  static String getBudgetId(String categoryName) {
    if (categoryName.contains(':')) {
      final parts = categoryName.split(':');
      if (parts.length >= 2 && parts[0].startsWith('budget_')) {
        return parts[0];
      }
    }
    return 'budget_1'; // Default
  }

  static String getStrippedName(String categoryName) {
    if (categoryName.contains(':')) {
      final parts = categoryName.split(':');
      if (parts.length >= 2 && parts[0].startsWith('budget_')) {
        return parts.sublist(1).join(':');
      }
    }
    return categoryName;
  }
}

class Category {
  final String id;
  final String name;
  final double balance;
  final String colorHex;
  final String iconName;
  final AllocationType allocationType;
  final double allocationValue;
  final String user;
  final String budgetId;

  Category({
    required this.id,
    required this.name,
    required double balance,
    required this.colorHex,
    required this.iconName,
    required this.allocationType,
    required double allocationValue,
    required this.user,
    this.budgetId = 'budget_1',
  })  : balance = ((balance * 100).roundToDouble() / 100),
        allocationValue = ((allocationValue * 100).roundToDouble() / 100);

  factory Category.fromJson(Map<String, dynamic> json) {
    AllocationType parseAllocationType(String? val) {
      switch (val) {
        case 'percent_check':
        case 'percentCheck':
          return AllocationType.percentCheck;
        case 'fixed_check':
        case 'fixedCheck':
          return AllocationType.fixedCheck;
        case 'monthly_target':
        case 'monthlyTarget':
          return AllocationType.monthlyTarget;
        case 'manual':
        default:
          return AllocationType.manual;
      }
    }

    double parseDouble(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    final rawName = json['name'] ?? '';
    final bId = (json['budgetId'] ?? json['budget_id'])?.toString() ??
        BudgetCategoryHelper.getBudgetId(rawName);
    final strippedName = BudgetCategoryHelper.getStrippedName(rawName);

    return Category(
      id: json['id'] ?? '',
      name: strippedName,
      balance: parseDouble(json['balance']),
      colorHex: json['color'] ?? json['colorHex'] ?? '#2196F3',
      iconName: json['icon'] ?? json['iconName'] ?? 'folder',
      allocationType: parseAllocationType(json['allocation_type'] ?? json['allocationType']),
      allocationValue: parseDouble(json['allocation_value'] ?? json['allocationValue']),
      user: json['user'] ?? '',
      budgetId: bId,
    );
  }

  Map<String, dynamic> toJson() {
    String allocationTypeToString(AllocationType type) {
      switch (type) {
        case AllocationType.percentCheck:
          return 'percent_check';
        case AllocationType.fixedCheck:
          return 'fixed_check';
        case AllocationType.monthlyTarget:
          return 'monthly_target';
        case AllocationType.manual:
          return 'manual';
      }
    }

    final dbName = budgetId == 'budget_1' ? name : '$budgetId:$name';

    return {
      if (id.isNotEmpty) 'id': id,
      'name': dbName,
      'balance': balance,
      'color': colorHex,
      'icon': iconName,
      'allocation_type': allocationTypeToString(allocationType),
      'allocation_value': allocationValue,
      'user': user,
      'budgetId': budgetId,
    };
  }

  Category copyWith({
    String? id,
    String? name,
    double? balance,
    String? colorHex,
    String? iconName,
    AllocationType? allocationType,
    double? allocationValue,
    String? user,
    String? budgetId,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      balance: balance ?? this.balance,
      colorHex: colorHex ?? this.colorHex,
      iconName: iconName ?? this.iconName,
      allocationType: allocationType ?? this.allocationType,
      allocationValue: allocationValue ?? this.allocationValue,
      user: user ?? this.user,
      budgetId: budgetId ?? this.budgetId,
    );
  }

  // Check if it's the system's unallocated funds envelope
  bool get isUnallocated => name.toLowerCase() == 'unallocated';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Category &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
