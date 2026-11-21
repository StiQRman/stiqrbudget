import 'package:flutter/material.dart';

class IconMapper {
  static IconData getIcon(String name) {
    switch (name.toLowerCase()) {
      case 'rent':
      case 'home':
      case 'house':
        return Icons.home_outlined;
      case 'vacation':
      case 'travel':
      case 'flight':
        return Icons.flight_takeoff_outlined;
      case 'groceries':
      case 'food':
        return Icons.shopping_basket_outlined;
      case 'shopping':
      case 'cart':
        return Icons.shopping_cart_outlined;
      case 'bills':
      case 'receipt':
        return Icons.receipt_long_outlined;
      case 'savings':
      case 'piggy':
        return Icons.savings_outlined;
      case 'car':
      case 'transport':
        return Icons.directions_car_outlined;
      case 'health':
      case 'medical':
        return Icons.medical_services_outlined;
      case 'entertainment':
      case 'movie':
        return Icons.movie_filter_outlined;
      case 'inbox':
        return Icons.inbox_outlined;
      default:
        return Icons.folder_open_outlined;
    }
  }

  static List<String> getAvailableIcons() {
    return [
      'rent',
      'vacation',
      'groceries',
      'shopping',
      'bills',
      'savings',
      'car',
      'health',
      'entertainment',
    ];
  }
}
