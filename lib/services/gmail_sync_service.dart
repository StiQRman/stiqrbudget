import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bank_sync_config.dart';
import '../models/transaction_model.dart';
import 'bank_statement_parser.dart';
import 'pocketbase_service.dart';

class SyncResult {
  final int importedCount;
  final int discrepancyCount;
  final List<String> warnings;
  final String? error;

  const SyncResult({
    this.importedCount = 0,
    this.discrepancyCount = 0,
    this.warnings = const [],
    this.error,
  });
}

class GmailSyncService {
  static const String _prefKey = 'stiqrbudget_bank_sync_config';
  static final GmailSyncService _instance = GmailSyncService._internal();

  factory GmailSyncService() => _instance;
  GmailSyncService._internal();

  BankSyncConfig _config = const BankSyncConfig();
  BankSyncConfig get config => _config;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw != null && raw.isNotEmpty) {
      _config = BankSyncConfig.decode(raw);
    }
  }

  Future<void> saveConfig(BankSyncConfig newConfig) async {
    _config = newConfig;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, newConfig.encode());
  }

  /// Builds the targeted Gmail query matching bank senders and keywords
  String buildGmailQuery() {
    final senders = _config.watchedSenders
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final keywords = _config.watchedKeywords
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    final List<String> parts = ['newer_than:7d'];

    if (senders.isNotEmpty) {
      parts.add('from:(${senders.join(' OR ')})');
    }
    if (keywords.isNotEmpty) {
      parts.add('(${keywords.map((k) => '"$k"').join(' OR ')})');
    }

    return parts.join(' ');
  }

  /// Calculates the app's current total balance across all categories + unallocated
  double getAppTotalBalance(PocketBaseService pbService) {
    double total = 0.0;
    for (final cat in pbService.categories) {
      total += cat.balance;
    }
    return ((total * 100).roundToDouble()) / 100;
  }

  /// Ingests a raw email statement text (from Gmail or test injection)
  /// and creates a Pending Inbox transaction with balance verification.
  Future<TransactionModel?> ingestEmailStatement({
    required String textContent,
    String? subject,
    String? sender,
    DateTime? date,
    required PocketBaseService pbService,
  }) async {
    final statement = BankStatementParser.parseEmail(
      textContent: textContent,
      subject: subject,
      config: _config,
    );

    if (statement == null) {
      return null;
    }

    final currentAppBalance = getAppTotalBalance(pbService);
    final (hasDiscrepancy, diff, expected) = statement.verifyAgainstAppBalance(currentAppBalance);

    // Prefer statement's in-text date if found, otherwise email received date
    final effectiveDate = statement.extractedDate ?? date ?? DateTime.now();
    final existing = pbService.transactions.where((t) {
      final sameMerchant = t.description.toLowerCase() == statement.merchant.toLowerCase();
      final sameAmount = (t.amount.abs() - statement.amount.abs()).abs() < 0.001;
      final diffHours = (t.date.difference(effectiveDate)).inHours.abs();
      return sameMerchant && sameAmount && diffHours < 36;
    }).toList();

    if (existing.isNotEmpty) {
      debugPrint('[BankSync] Skipping duplicate transaction for ${statement.merchant}');
      return null;
    }

    final signedAmount = statement.type == TransactionType.income
        ? statement.amount.abs()
        : -statement.amount.abs();

    final tx = TransactionModel(
      id: '',
      description: statement.merchant,
      amount: signedAmount,
      type: statement.type,
      category: null, // Null category puts it directly into Pending / Unallocated Inbox!
      date: effectiveDate,
      user: pbService.currentUserId ?? '',
      reportedBalance: statement.reportedBalance,
      balanceDiscrepancy: hasDiscrepancy ? diff : null,
      hasBalanceWarning: hasDiscrepancy,
      statementEmailSender: sender ?? (config.watchedSenders.isNotEmpty ? config.watchedSenders.first : 'bank-alert'),
      rawEmailSnippet: statement.rawSnippet,
    );

    return await pbService.createTransaction(tx, syncImmediately: true);
  }

  /// Syncs statement messages directly from Gmail via the Gmail REST API
  Future<SyncResult> syncGmailStatements(PocketBaseService pbService) async {
    return const SyncResult(error: 'Email sync feature is currently disabled.');
  }
}
