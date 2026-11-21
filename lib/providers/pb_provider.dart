import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/pocketbase_service.dart';

final pbServiceProvider = Provider<PocketBaseService>((ref) {
  return PocketBaseService();
});
