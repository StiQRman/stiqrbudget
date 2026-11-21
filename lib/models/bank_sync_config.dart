import 'dart:convert';

/// Configuration for watching bank statement emails and extracting transactions.
class BankSyncConfig {
  final bool isEnabled;
  final bool isGoogleConnected;
  final String? googleEmail;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? tokenExpiry;
  final List<String> watchedSenders;
  final List<String> watchedKeywords;
  final String balanceKeyword;
  final String balancePattern;
  final bool verifyBalance;
  final DateTime? lastSyncTime;

  const BankSyncConfig({
    this.isEnabled = true,
    this.isGoogleConnected = false,
    this.googleEmail,
    this.accessToken,
    this.refreshToken,
    this.tokenExpiry,
    this.watchedSenders = const [
      'alerts@chase.com',
      'alertsp.chase.com',
      'wellsfargo.com',
      'americanexpress.com',
      'alerts@capitalone.com',
      'citi.com',
      'bankofamerica.com',
      'apple.com',
    ],
    this.watchedKeywords = const [
      'transaction',
      'spent',
      'charge',
      'purchase',
      'debit',
      'sent',
      'withdrawal',
    ],
    this.balanceKeyword = 'Current balance',
    this.balancePattern = r'(?:Current\s+balance|Available\s+balance|Bal|Balance|Remaining\s+balance)\s*[:\-]?\s*([0-9,]+\.[0-9]{2})',
    this.verifyBalance = true,
    this.lastSyncTime,
  });

  BankSyncConfig copyWith({
    bool? isEnabled,
    bool? isGoogleConnected,
    String? googleEmail,
    String? accessToken,
    String? refreshToken,
    DateTime? tokenExpiry,
    List<String>? watchedSenders,
    List<String>? watchedKeywords,
    String? balanceKeyword,
    String? balancePattern,
    bool? verifyBalance,
    DateTime? lastSyncTime,
  }) {
    return BankSyncConfig(
      isEnabled: isEnabled ?? this.isEnabled,
      isGoogleConnected: isGoogleConnected ?? this.isGoogleConnected,
      googleEmail: googleEmail ?? this.googleEmail,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      tokenExpiry: tokenExpiry ?? this.tokenExpiry,
      watchedSenders: watchedSenders ?? this.watchedSenders,
      watchedKeywords: watchedKeywords ?? this.watchedKeywords,
      balanceKeyword: balanceKeyword ?? this.balanceKeyword,
      balancePattern: balancePattern ?? this.balancePattern,
      verifyBalance: verifyBalance ?? this.verifyBalance,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    );
  }

  factory BankSyncConfig.fromJson(Map<String, dynamic> json) {
    List<String> parseStringList(dynamic val, List<String> fallback) {
      if (val is List) {
        return val.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      }
      return fallback;
    }

    DateTime? parseDate(dynamic val) {
      if (val is String && val.isNotEmpty) {
        return DateTime.tryParse(val);
      }
      return null;
    }

    return BankSyncConfig(
      isEnabled: json['is_enabled'] as bool? ?? true,
      isGoogleConnected: json['is_google_connected'] as bool? ?? false,
      googleEmail: json['google_email'] as String?,
      accessToken: json['access_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      tokenExpiry: parseDate(json['token_expiry']),
      watchedSenders: parseStringList(json['watched_senders'], const [
        'alerts@chase.com',
        'alertsp.chase.com',
        'wellsfargo.com',
        'americanexpress.com',
        'alerts@capitalone.com',
        'citi.com',
        'bankofamerica.com',
        'apple.com',
      ]),
      watchedKeywords: parseStringList(json['watched_keywords'], const [
        'transaction',
        'spent',
        'charge',
        'purchase',
        'debit',
        'sent',
        'withdrawal',
      ]),
      balanceKeyword: json['balance_keyword'] as String? ?? 'Current balance',
      balancePattern: json['balance_pattern'] as String? ??
          r'(?:Current\s+balance|Available\s+balance|Bal|Balance|Remaining\s+balance)\s*[:\-]?\s*([0-9,]+\.[0-9]{2})',
      verifyBalance: json['verify_balance'] as bool? ?? true,
      lastSyncTime: parseDate(json['last_sync_time']),
    );
  }

  Map<String, dynamic> toJson() => {
        'is_enabled': isEnabled,
        'is_google_connected': isGoogleConnected,
        if (googleEmail != null) 'google_email': googleEmail,
        if (accessToken != null) 'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (tokenExpiry != null) 'token_expiry': tokenExpiry!.toIso8601String(),
        'watched_senders': watchedSenders,
        'watched_keywords': watchedKeywords,
        'balance_keyword': balanceKeyword,
        'balance_pattern': balancePattern,
        'verify_balance': verifyBalance,
        if (lastSyncTime != null) 'last_sync_time': lastSyncTime!.toIso8601String(),
      };

  String encode() => jsonEncode(toJson());

  static BankSyncConfig decode(String str) {
    try {
      final map = jsonDecode(str) as Map<String, dynamic>;
      return BankSyncConfig.fromJson(map);
    } catch (_) {
      return const BankSyncConfig();
    }
  }
}
