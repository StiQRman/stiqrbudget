import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../models/bank_sync_config.dart';
import '../services/gmail_sync_service.dart';
import '../services/pocketbase_service.dart';
import 'pb_provider.dart';

final bankSyncServiceProvider = Provider<GmailSyncService>((ref) {
  return GmailSyncService();
});

class BankSyncState {
  final BankSyncConfig config;
  final bool isSyncing;
  final String? lastMessage;
  final bool hasError;

  const BankSyncState({
    required this.config,
    this.isSyncing = false,
    this.lastMessage,
    this.hasError = false,
  });

  BankSyncState copyWith({
    BankSyncConfig? config,
    bool? isSyncing,
    String? lastMessage,
    bool? hasError,
  }) {
    return BankSyncState(
      config: config ?? this.config,
      isSyncing: isSyncing ?? this.isSyncing,
      lastMessage: lastMessage ?? this.lastMessage,
      hasError: hasError ?? this.hasError,
    );
  }
}

class BankSyncNotifier extends StateNotifier<BankSyncState> {
  final GmailSyncService _service;
  final PocketBaseService _pbService;

  BankSyncNotifier(this._service, this._pbService)
      : super(BankSyncState(config: _service.config)) {
    _init();
  }

  Future<void> _init() async {
    await _service.init();
    state = state.copyWith(config: _service.config);
  }

  Future<void> updateConfig(BankSyncConfig newConfig) async {
    await _service.saveConfig(newConfig);
    state = state.copyWith(config: newConfig);
  }

  Future<void> addSender(String sender) async {
    final clean = sender.trim().toLowerCase();
    if (clean.isEmpty || state.config.watchedSenders.contains(clean)) return;
    final updated = [...state.config.watchedSenders, clean];
    await updateConfig(state.config.copyWith(watchedSenders: updated));
  }

  Future<void> removeSender(String sender) async {
    final updated = state.config.watchedSenders.where((s) => s != sender).toList();
    await updateConfig(state.config.copyWith(watchedSenders: updated));
  }

  Future<void> addKeyword(String keyword) async {
    final clean = keyword.trim().toLowerCase();
    if (clean.isEmpty || state.config.watchedKeywords.contains(clean)) return;
    final updated = [...state.config.watchedKeywords, clean];
    await updateConfig(state.config.copyWith(watchedKeywords: updated));
  }

  Future<void> removeKeyword(String keyword) async {
    final updated = state.config.watchedKeywords.where((k) => k != keyword).toList();
    await updateConfig(state.config.copyWith(watchedKeywords: updated));
  }

  Future<void> updateBalancePattern(String pattern, String keyword) async {
    await updateConfig(state.config.copyWith(
      balancePattern: pattern.trim(),
      balanceKeyword: keyword.trim(),
    ));
  }

  Future<void> toggleGoogleConnection(bool connected, {String? email, String? token}) async {
    final updated = state.config.copyWith(
      isGoogleConnected: connected,
      googleEmail: email,
      accessToken: token,
    );
    await updateConfig(updated);
  }

  Future<SyncResult> syncStatements() async {
    const errorMsg = 'Email connection features are disabled.';
    state = state.copyWith(
      isSyncing: false,
      hasError: true,
      lastMessage: errorMsg,
    );
    return const SyncResult(error: errorMsg);
  }

  /// Inject test statement for instant preview and validation of balance math
  Future<bool> injectTestStatement({
    required String textContent,
    String? subject,
    String? sender,
  }) async {
    try {
      final created = await _service.ingestEmailStatement(
        textContent: textContent,
        subject: subject,
        sender: sender,
        pbService: _pbService,
      );
      if (created != null) {
        state = state.copyWith(
          lastMessage: 'Successfully imported test transaction: ${created.description}',
          hasError: false,
        );
        return true;
      } else {
        state = state.copyWith(
          lastMessage: 'Could not parse amount from email text.',
          hasError: true,
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        lastMessage: 'Error injecting test email: $e',
        hasError: true,
      );
      return false;
    }
  }
}

final bankSyncProvider = StateNotifierProvider<BankSyncNotifier, BankSyncState>((ref) {
  final service = ref.watch(bankSyncServiceProvider);
  final pbService = ref.watch(pbServiceProvider);
  return BankSyncNotifier(service, pbService);
});
