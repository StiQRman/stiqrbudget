import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;
import '../config/app_config.dart';
import '../models/category.dart';
import '../models/transaction_model.dart';
import '../models/app_release.dart';
import 'pqe_crypto.dart';
import 'sse/sse_connection.dart';

class BudgetCollaborator {
  final String pubAddress;
  final String x25519Pub;
  final String label;
  final String role; // 'edit' | 'view'
  final String addedAt;

  const BudgetCollaborator({
    required this.pubAddress,
    required this.x25519Pub,
    required this.label,
    required this.role,
    required this.addedAt,
  });

  bool get canEdit => role == 'edit';

  String get shortPubKey {
    if (pubAddress.length <= 14) return pubAddress;
    return '${pubAddress.substring(0, 8)}...${pubAddress.substring(pubAddress.length - 6)}';
  }

  Map<String, dynamic> toJson() => {
        'pubAddress': pubAddress,
        'x25519Pub': x25519Pub,
        'label': label,
        'role': role,
        'addedAt': addedAt,
      };

  factory BudgetCollaborator.fromJson(Map<String, dynamic> json) {
    return BudgetCollaborator(
      pubAddress: (json['pubAddress'] ?? '').toString(),
      x25519Pub: (json['x25519Pub'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      role: (json['role'] ?? 'edit').toString() == 'view' ? 'view' : 'edit',
      addedAt: (json['addedAt'] ?? '').toString(),
    );
  }
}

class BudgetDescriptor {
  final String localBudgetId;
  final String name;
  final String sharedBudgetKey;
  final String ownerPubAddress;
  final Uint8List budgetDek;
  final String role; // 'owner' | 'edit' | 'view'
  final List<BudgetCollaborator> collaborators;

  const BudgetDescriptor({
    required this.localBudgetId,
    required this.name,
    required this.sharedBudgetKey,
    required this.ownerPubAddress,
    required this.budgetDek,
    required this.role,
    this.collaborators = const [],
  });

  bool get isOwner => role == 'owner';
  bool get isShared => role != 'owner';
  bool get canEdit => role == 'owner' || role == 'edit';
  bool get isReadOnly => role == 'view';

  BudgetDescriptor copyWith({
    String? name,
    String? role,
    List<BudgetCollaborator>? collaborators,
  }) {
    return BudgetDescriptor(
      localBudgetId: localBudgetId,
      name: name ?? this.name,
      sharedBudgetKey: sharedBudgetKey,
      ownerPubAddress: ownerPubAddress,
      budgetDek: budgetDek,
      role: role ?? this.role,
      collaborators: collaborators ?? this.collaborators,
    );
  }
}

class _DerivedAccountKeys {
  final String email;
  final Uint8List identitySeed;
  final Uint8List masterDek;
  final SimpleKeyPair signingKeyPair;
  final String pubAddress;
  final SimpleKeyPair x25519KeyPair;
  final String x25519PubHex;
  final Mlkem768KeyPair mlkem768KeyPair;
  final String mlkem768PubB64;
  final String accountRecordId;
  final String userIndexRecordId;
  final String legacyVaultRecordId;

  _DerivedAccountKeys({
    required this.email,
    required this.identitySeed,
    required this.masterDek,
    required this.signingKeyPair,
    required this.pubAddress,
    required this.x25519KeyPair,
    required this.x25519PubHex,
    required this.mlkem768KeyPair,
    required this.mlkem768PubB64,
    required this.accountRecordId,
    required this.userIndexRecordId,
    required this.legacyVaultRecordId,
  });
}

class DuplicateTxPair {
  final TransactionModel localTx;
  final TransactionModel remoteTx;
  const DuplicateTxPair({required this.localTx, required this.remoteTx});
}

/// Top-level function for isolate-based PBKDF2-HMAC-SHA256 key derivation
/// so login and sign-up never freeze the UI thread.
Future<Uint8List> _derivePbkdf2Bytes(Map<String, String> params) async {
  final cleanEmail = params['email']!;
  final password = params['password']!;
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 60000,
    bits: 512,
  );
  final salt = utf8.encode('stiqrbudget:zk:v1:$cleanEmail');
  final secretKey = await pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: salt,
  );
  return Uint8List.fromList(await secretKey.extractBytes());
}

class PocketBaseService {
  // Legacy PocketBase instance kept only for one-time migration on first login
  final PocketBase pb;
  static const String legacyPbUrl = 'https://api.stiqrnotes.com';

  static const String _lanCloudUrl =
      String.fromEnvironment('LAN_CLOUD_URL', defaultValue: '');
  static const String _lanHubUrl =
      String.fromEnvironment('LAN_HUB_URL', defaultValue: '');

  // StiQRcloud endpoints (HTTPS primary; optional LAN dev URL via --dart-define=LAN_CLOUD_URL=...)
  static List<String> get stiqrCloudNodes => [
        'https://stiqrcloud.stiqrnotes.com',
        if (!AppConfig.isPlayStore && _lanCloudUrl.isNotEmpty) _lanCloudUrl,
      ];

  // StiQRhub endpoints for APK releases (HTTPS primary; optional LAN dev URL via --dart-define=LAN_HUB_URL=...)
  static List<String> get stiqrHubNodes => [
        'https://stiqrnotes.com/hub',
        'https://hub.stiqrnotes.com',
        if (!AppConfig.isPlayStore && _lanHubUrl.isNotEmpty) _lanHubUrl,
      ];

  // StiQRcloud collections
  static const String accountsCollection = 'stiqrbudget_accounts';
  static const String pubkeysCollection = 'stiqrbudget_pubkeys';
  static const String userIndexCollection = 'stiqrbudget_user_index';
  static const String budgetMetaCollection = 'stiqrbudget_meta';
  static const String txShardsCollection = 'stiqrbudget_tx_shards';
  static const String grantsCollection = 'stiqrbudget_grants';
  static const String legacyVaultCollection = 'stiqrbudget_vault';

  static const String _zkSessionPrefKey = 'stiqrbudget_zk_session';
  static const String _secureIdentitySeedKey = 'stiqrbudget_identity_seed';
  static const String _secureMasterDekKey = 'stiqrbudget_master_dek';
  static const String _localCachePrefix = 'stiqrbudget_sharded_cache_v2_';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

  Future<String?> _readSecure(String key, SharedPreferences prefs) async {
    if (!kIsWeb) {
      try {
        final val = await _secureStorage.read(key: key);
        if (val != null) return val;
      } on MissingPluginException {
        // Fallback to SharedPreferences
      } on PlatformException {
        // Fallback to SharedPreferences
      }
    }
    return prefs.getString('zk_fallback_$key');
  }

  Future<void> _writeSecure(
      String key, String value, SharedPreferences prefs) async {
    if (!kIsWeb) {
      try {
        await _secureStorage.write(key: key, value: value);
        return;
      } on MissingPluginException {
        // Fallback to SharedPreferences
      } on PlatformException {
        // Fallback to SharedPreferences
      }
    }
    await prefs.setString('zk_fallback_$key', value);
  }

  Future<void> _deleteSecure(String key, SharedPreferences prefs) async {
    if (!kIsWeb) {
      try {
        await _secureStorage.delete(key: key);
      } on MissingPluginException {
        // Fallback to SharedPreferences
      } on PlatformException {
        // Fallback to SharedPreferences
      }
    }
    await prefs.remove('zk_fallback_$key');
  }

  // Zero-knowledge session state (stored locally only; never exposed to StiQRcloud)
  String? _currentUserEmail;
  String? _currentUserPubAddress;
  String? _currentUserX25519PubHex;
  String? _currentUserMlkem768PubB64;
  Uint8List? _identitySeed;
  Uint8List? _masterDek;
  SimpleKeyPair? _signingKeyPair;
  SimpleKeyPair? _x25519KeyPair;
  Mlkem768KeyPair? _mlkem768KeyPair;
  bool _pubkeyDirectoryPublished = false;
  final Set<String> _upgradedHybridGrantIds = {};

  // In-memory state across all owned + shared budgets
  final Map<String, BudgetDescriptor> _budgetsByLocalId = {};
  final Map<String, String> _localIdBySharedKey = {};
  final Map<String, Map<String, int>> _loadedShardRevisions = {};
  final Map<String, Set<String>> _dirtyMonthsBySharedKey = {};
  final Set<String> _deletedTxIds = {};
  final Set<String> _deletedCatIds = {};
  final Set<String> _sessionCreatedTxIds = {};
  final Set<String> _unsyncedLocalTxIds = {};
  final Set<String> _resolvedDuplicatePairs = {};
  Timer? _backgroundSyncTimer;

  /// Starts periodic background sync (every 45s) while authenticated so
  /// shared budgets stay up-to-date automatically across collaborators.
  void startBackgroundSync({Duration interval = const Duration(seconds: 45)}) {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = Timer.periodic(interval, (_) {
      if (!isAuthenticated || _pushDepth > 0 || _inFlightPush != null || _inFlightPull != null) {
        return;
      }
      if (_dirtyMonthsBySharedKey.isNotEmpty || _dirtyBudgetMetaKeys.isNotEmpty || _userIndexDirty) {
        unawaited(syncVaultToCloud().catchError((_) {}));
      } else {
        unawaited(_pullAllFromCloud(notifyChanges: true).catchError((_) => false));
      }
    });
  }

  void stopBackgroundSync() {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = null;
  }

  /// Optional UI callback invoked when a merge detects transactions with
  /// identical amount + category + type but different IDs across devices.
  void Function(List<DuplicateTxPair> duplicates)? onDuplicateTransactionsDetected;

  /// Canonical order-independent pair key for resolved duplicate tracking.
  static String duplicatePairKey(String idA, String idB) {
    final ids = [idA, idB]..sort();
    return '${ids[0]}|${ids[1]}';
  }

  /// Detects potential duplicate transactions across [remote] and [local].
  ///
  /// Only compares genuinely NEW remote transactions (IDs not already in
  /// [local], not in [deletedIds], and not created by this device in
  /// [sessionCreatedIds]) against unsynced local transactions (IDs not already
  /// present in [remote], and restricted to [unsyncedLocalIds] if provided).
  ///
  /// Requires tight matching:
  /// - different IDs
  /// - same `category` (and same source/destination for transfers) & same `type`
  /// - exact `amount` within `0.005`
  /// - `date` within [maxDateDiff] (default 24 hours) of each other
  /// - both transactions within [recencyWindow] (default 7 days) of [now]
  ///   so historical transactions are never re-flagged
  /// - pair not already in [resolvedPairs]
  static List<DuplicateTxPair> findPotentialDuplicates(
    List<TransactionModel> remote,
    List<TransactionModel> local, {
    Set<String> deletedIds = const {},
    Set<String> sessionCreatedIds = const {},
    Set<String>? unsyncedLocalIds,
    Set<String> resolvedPairs = const {},
    Duration maxDateDiff = const Duration(hours: 24),
    Duration recencyWindow = const Duration(days: 7),
    DateTime? now,
  }) {
    final referenceNow = now ?? DateTime.now();
    final localIds = local.map((t) => t.id).toSet();
    final remoteIds = remote.map((t) => t.id).toSet();

    // Only genuinely NEW remote transactions that were not already in local
    // and were not created by this device in this session.
    final newRemote = remote.where((r) {
      if (localIds.contains(r.id)) return false;
      if (deletedIds.contains(r.id)) return false;
      if (sessionCreatedIds.contains(r.id)) return false;
      return true;
    }).toList();

    if (newRemote.isEmpty) return const [];

    // Only unsynced local transactions not already present on the server.
    final candidateLocal = local.where((l) {
      if (remoteIds.contains(l.id)) return false;
      if (deletedIds.contains(l.id)) return false;
      if (unsyncedLocalIds != null && !unsyncedLocalIds.contains(l.id)) {
        return false;
      }
      return true;
    }).toList();

    if (candidateLocal.isEmpty) return const [];

    final pairs = <DuplicateTxPair>[];
    final seenPairKeys = <String>{};

    for (final l in candidateLocal) {
      if (referenceNow.difference(l.date).abs() > recencyWindow) continue;
      for (final r in newRemote) {
        if (l.id == r.id) continue;
        if (referenceNow.difference(r.date).abs() > recencyWindow) continue;
        if (l.type != r.type) continue;
        if (l.category != r.category) continue;
        if (l.type == TransactionType.transfer &&
            (l.sourceCategory != r.sourceCategory ||
                l.destinationCategory != r.destinationCategory)) {
          continue;
        }
        if ((l.amount - r.amount).abs() >= 0.005) continue;
        if (l.date.difference(r.date).abs() > maxDateDiff) continue;

        final key = duplicatePairKey(l.id, r.id);
        if (resolvedPairs.contains(key) || !seenPairKeys.add(key)) continue;

        pairs.add(DuplicateTxPair(localTx: l, remoteTx: r));
      }
    }
    return pairs;
  }

  /// Non-destructive union merge for transactions by ID.
  /// Preserves remote transactions not in [deletedIds], while [local] wins on ID collisions.
  static List<TransactionModel> mergeTransactions(
    List<TransactionModel> remote,
    List<TransactionModel> local,
    Set<String> deletedIds,
  ) {
    final merged = <String, TransactionModel>{};
    for (final tx in remote) {
      if (!deletedIds.contains(tx.id)) {
        merged[tx.id] = tx;
      }
    }
    for (final tx in local) {
      if (!deletedIds.contains(tx.id)) {
        merged[tx.id] = tx;
      }
    }
    return merged.values.toList();
  }

  /// Non-destructive union merge for categories by ID.
  /// Preserves remote categories not in [deletedIds], while [local] wins on ID collisions.
  static List<Category> mergeCategories(
    List<Category> remote,
    List<Category> local,
    Set<String> deletedIds,
  ) {
    final merged = <String, Category>{};
    for (final cat in remote) {
      if (!deletedIds.contains(cat.id)) {
        merged[cat.id] = cat;
      }
    }
    for (final cat in local) {
      if (!deletedIds.contains(cat.id)) {
        merged[cat.id] = cat;
      }
    }
    return merged.values.toList();
  }
  final Set<String> _dirtyBudgetMetaKeys = {};
  final Map<String, int> _budgetMetaDirtyGen = {};
  bool _userIndexDirty = false;
  bool _localCacheLoaded = false;

  @visibleForTesting
  Future<sc.RecordModel?> Function(String collection, String recordId)?
      debugGetRecordOverride;

  @visibleForTesting
  Future<sc.RecordModel> Function(
    String collection,
    String recordId,
    String textPayload,
  )? debugUpsertRecordOverride;

  @visibleForTesting
  Set<String> get debugDirtyBudgetMetaKeys => Set<String>.unmodifiable(_dirtyBudgetMetaKeys);

  @visibleForTesting
  List<Category> get debugCategories => List<Category>.unmodifiable(_categories);

  @visibleForTesting
  Map<String, int> get debugBudgetMetaUpdatedAt =>
      Map<String, int>.unmodifiable(_budgetMetaUpdatedAt);

  @visibleForTesting
  Future<void> debugInitTestSession({
    required String email,
    required String password,
    bool hasLoadedRemoteOnce = true,
  }) async {
    _resetMemoryState();
    final keys = await _deriveAccountKeys(email, password);
    _currentUserEmail = keys.email;
    _currentUserPubAddress = keys.pubAddress;
    _currentUserX25519PubHex = keys.x25519PubHex;
    _currentUserMlkem768PubB64 = keys.mlkem768PubB64;
    _identitySeed = keys.identitySeed;
    _masterDek = keys.masterDek;
    _signingKeyPair = keys.signingKeyPair;
    _x25519KeyPair = keys.x25519KeyPair;
    _mlkem768KeyPair = keys.mlkem768KeyPair;
    _pubkeyDirectoryPublished = true;
    _hasLoadedRemoteOnce = hasLoadedRemoteOnce;
    _shardedV3Ready = true;
    await _ensureDefaultBudgetDescriptor();
  }

  @visibleForTesting
  Future<void> debugSaveStateToLocalCache() => _saveStateToLocalCache();

  @visibleForTesting
  Future<bool> debugApplyBudgetMetaRecord(
    String localBudgetId,
    sc.RecordModel bmetaRec, {
    bool notifyChanges = false,
  }) async {
    final desc = _budgetsByLocalId[localBudgetId]!;
    return _applyBudgetMetaRecord(desc, bmetaRec, notifyChanges: notifyChanges);
  }

  @visibleForTesting
  Future<String> debugEncryptBudgetPayload(
    String localBudgetId,
    Map<String, dynamic> payload,
  ) async {
    final desc = _budgetsByLocalId[localBudgetId]!;
    return _encryptPayload(jsonEncode(payload), desc.budgetDek);
  }

  @visibleForTesting
  String? debugSharedBudgetKey(String localBudgetId) =>
      _budgetsByLocalId[localBudgetId]?.sharedBudgetKey;

  List<Category> _categories = [];
  List<TransactionModel> _transactions = [];
  List<Map<String, dynamic>> _rules = [];
  int _userIndexUpdatedAt = 0;
  final Map<String, int> _budgetMetaUpdatedAt = {};
  bool _hasLoadedRemoteOnce = false;
  bool _shardedV3Ready = false;
  Future<bool>? _inFlightPull;
  Future<void>? _inFlightPush;
  int _pushDepth = 0;
  int _lastPushFinishedMs = 0;

  // Real-time SSE connection state
  SseConnectionInterface? _sseConnection;
  StreamSubscription<SseRawMessage>? _sseSubscription;
  Timer? _sseReconnectTimer;
  String? _sseClientId;
  bool _sseConnected = false;
  int _sseReconnectAttempts = 0;

  static const List<String> _sseTopics = [
    '$userIndexCollection/*',
    '$budgetMetaCollection/*',
    '$txShardsCollection/*',
    '$grantsCollection/*',
  ];

  // Realtime listener callbacks for providers
  final List<void Function(RecordSubscriptionEvent event)> _categoryListeners = [];
  final List<void Function(RecordSubscriptionEvent event)> _transactionListeners = [];
  final List<void Function(RecordSubscriptionEvent event)> _releaseListeners = [];
  final List<void Function()> _metadataListeners = [];

  PocketBaseService({String? initialAuthString})
      : pb = PocketBase(legacyPbUrl);

  bool get isAuthenticated =>
      _currentUserPubAddress != null &&
      _masterDek != null &&
      _signingKeyPair != null;

  String? get currentUserId => _currentUserPubAddress;
  String? get currentUserEmail => _currentUserEmail;
  String? get currentUserX25519Pub => _currentUserX25519PubHex;
  String? get currentUserMlkem768Pub => _currentUserMlkem768PubB64;
  Uint8List? get identitySeed => _identitySeed;
  bool get hasLoadedRemoteOnce => _hasLoadedRemoteOnce;
  bool get isSyncing => _inFlightPull != null || _pushDepth > 0;
  bool get isSseConnected => _sseConnected;
  List<Category> get categories => List<Category>.unmodifiable(_categories);
  List<TransactionModel> get transactions => List<TransactionModel>.unmodifiable(_transactions);

  // QR code payload representing the current user's public identity for collaboration
  String get currentUserQrPayload {
    if (_currentUserPubAddress == null || _currentUserX25519PubHex == null) {
      return '';
    }
    return 'stiqrbudget:user:$_currentUserPubAddress:$_currentUserX25519PubHex';
  }

  String get _userIndexRecordId =>
      'uindex_${_currentUserPubAddress!.substring(0, 24)}';

  String get _pubkeyRecordId =>
      'pk_${_currentUserPubAddress!.substring(0, 24)}';

  void addMetadataListener(void Function() listener) {
    if (!_metadataListeners.contains(listener)) {
      _metadataListeners.add(listener);
    }
  }

  void removeMetadataListener(void Function() listener) {
    _metadataListeners.remove(listener);
  }

  void _notifyMetadataListeners() {
    for (final listener in List<void Function()>.from(_metadataListeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  BudgetDescriptor? getBudgetDescriptor(String localBudgetId) {
    return _budgetsByLocalId[localBudgetId];
  }

  List<BudgetDescriptor> get availableBudgets => _budgetsByLocalId.values.toList();

  String? get currentUserPubAddress => _currentUserPubAddress;

  String get _budgetsPrefKey =>
      _currentUserPubAddress != null && _currentUserPubAddress!.isNotEmpty
          ? 'budgets_list_${_currentUserPubAddress!}'
          : 'budgets_list_guest';

  bool isBudgetReadOnly(String localBudgetId) {
    final desc = _budgetsByLocalId[localBudgetId];
    return desc?.isReadOnly ?? false;
  }

  List<BudgetCollaborator> getCollaboratorsForBudget(String localBudgetId) {
    return _budgetsByLocalId[localBudgetId]?.collaborators ?? const [];
  }

  // Restore saved zero-knowledge StiQRcloud session on app startup
  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('pb_auth')) {
      await prefs.remove('pb_auth');
    }

    final rawSession = prefs.getString(_zkSessionPrefKey);
    if (rawSession == null || rawSession.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(rawSession) as Map<String, dynamic>;
      final email = (decoded['email'] as String?) ?? '';
      final pubAddress = (decoded['pubAddress'] as String?) ?? '';

      // Backward compatibility fallback: check FlutterSecureStorage first, then SharedPreferences
      String? seedB64 = await _readSecure(_secureIdentitySeedKey, prefs);
      String? dekB64 = await _readSecure(_secureMasterDekKey, prefs);

      bool migrated = false;
      if (seedB64 == null || seedB64.isEmpty) {
        seedB64 = (decoded['seed'] as String?) ?? '';
        if (seedB64.isNotEmpty) {
          await _writeSecure(_secureIdentitySeedKey, seedB64, prefs);
          migrated = true;
        }
      }

      if (dekB64 == null || dekB64.isEmpty) {
        dekB64 = (decoded['dek'] as String?) ?? '';
        if (dekB64.isNotEmpty) {
          await _writeSecure(_secureMasterDekKey, dekB64, prefs);
          migrated = true;
        }
      }

      // If migrated from SharedPreferences, scrub seeds from SharedPreferences
      if (migrated) {
        await prefs.setString(
          _zkSessionPrefKey,
          jsonEncode({
            'email': email,
            'pubAddress': pubAddress,
          }),
        );
      }

      if (email.isEmpty || seedB64.isEmpty || dekB64.isEmpty || pubAddress.isEmpty) {
        return;
      }

      final seed = Uint8List.fromList(base64Decode(seedB64));
      final dek = Uint8List.fromList(base64Decode(dekB64));
      final signingKp = await sc.StiQRcloudCrypto.keyPairFromSeed(seed);
      final x25519Kp = await _deriveX25519KeyPair(seed);
      final x25519Pub = await _extractPublicKeyHex(x25519Kp);
      final mlkem768Kp = PqeCrypto.deriveMlkem768KeyPair(seed);

      _currentUserEmail = email;
      _identitySeed = seed;
      _masterDek = dek;
      _signingKeyPair = signingKp;
      _currentUserPubAddress = pubAddress;
      _x25519KeyPair = x25519Kp;
      _currentUserX25519PubHex = x25519Pub;
      _mlkem768KeyPair = mlkem768Kp;
      _currentUserMlkem768PubB64 = mlkem768Kp.publicKeyBase64;
      _pubkeyDirectoryPublished = false;

      await _ensureDefaultBudgetDescriptor();
      await _loadStateFromLocalCache();

      _connectSse();
      unawaited(_registerPublicIdentityDirectory().catchError((_) {}));
      unawaited(_pullAllFromCloud(notifyChanges: true).catchError((_) => false));
    } catch (e) {
      print('Error restoring StiQRcloud session: $e');
    }
  }

  Future<SimpleKeyPair> _deriveX25519KeyPair(Uint8List identitySeed) async {
    final xSeedHex = sc.StiQRcloudCrypto.sha256Hex(
      utf8.encode('stiqrbudget:x25519:v1:${base64Encode(identitySeed)}'),
    );
    final xSeedBytes = _hexToBytes(xSeedHex);
    return X25519().newKeyPairFromSeed(xSeedBytes);
  }

  Future<String> _extractPublicKeyHex(SimpleKeyPair kp) async {
    final pub = await kp.extractPublicKey();
    return pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.trim().replaceAll(' ', '');
    final out = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < clean.length; i += 2) {
      out[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return out;
  }

  // Deterministically derive a 256-bit DEK for an owned budget from masterDek
  Uint8List _deriveOwnedBudgetDek(String sharedBudgetKey) {
    final hashHex = sc.StiQRcloudCrypto.sha256Hex([
      ..._masterDek!,
      ...utf8.encode(':stiqrbudget:bdek:v2:$sharedBudgetKey'),
    ]);
    return _hexToBytes(hashHex);
  }

  String _computeSharedBudgetKey(String ownerPubAddress, String canonicalBudgetId) {
    return sc.StiQRcloudCrypto.sha256Hex(
      utf8.encode('stiqrbudget:budget:$ownerPubAddress:$canonicalBudgetId'),
    ).substring(0, 24);
  }

  Future<void> _ensureDefaultBudgetDescriptor() async {
    if (!isAuthenticated) return;
    if (_budgetsByLocalId.isEmpty) {
      final sharedKey = _computeSharedBudgetKey(_currentUserPubAddress!, 'budget_1');
      final bDek = _deriveOwnedBudgetDek(sharedKey);
      final desc = BudgetDescriptor(
        localBudgetId: 'budget_1',
        name: 'My Budget',
        sharedBudgetKey: sharedKey,
        ownerPubAddress: _currentUserPubAddress!,
        budgetDek: bDek,
        role: 'owner',
      );
      _budgetsByLocalId['budget_1'] = desc;
      _localIdBySharedKey[sharedKey] = 'budget_1';
      _userIndexDirty = true;
    }
  }

  // Derive deterministic Ed25519 identity + X25519 keypair + 256-bit AES-GCM DEK from (email, password)
  Future<_DerivedAccountKeys> _deriveAccountKeys(
    String rawEmail,
    String password,
  ) async {
    final cleanEmail = rawEmail.trim().toLowerCase();
    final keyBytes = await compute(_derivePbkdf2Bytes, {
      'email': cleanEmail,
      'password': password,
    });
    final identitySeed = Uint8List.fromList(keyBytes.sublist(0, 32));
    final masterDek = Uint8List.fromList(keyBytes.sublist(32, 64));

    final signingKeyPair = await sc.StiQRcloudCrypto.keyPairFromSeed(identitySeed);
    final pubAddress = await sc.StiQRcloudCrypto.getPublicAddress(signingKeyPair);
    final x25519KeyPair = await _deriveX25519KeyPair(identitySeed);
    final x25519PubHex = await _extractPublicKeyHex(x25519KeyPair);
    final mlkem768KeyPair = PqeCrypto.deriveMlkem768KeyPair(identitySeed);
    final mlkem768PubB64 = mlkem768KeyPair.publicKeyBase64;

    final acctHash = sc.StiQRcloudCrypto.sha256Hex(
      utf8.encode('stiqrbudget:acct:$cleanEmail'),
    );
    final accountRecordId = 'acct_${acctHash.substring(0, 24)}';
    final userIndexRecordId = 'uindex_${pubAddress.substring(0, 24)}';
    final legacyVaultRecordId = 'vault_${pubAddress.substring(0, 24)}';

    return _DerivedAccountKeys(
      email: cleanEmail,
      identitySeed: identitySeed,
      masterDek: masterDek,
      signingKeyPair: signingKeyPair,
      pubAddress: pubAddress,
      x25519KeyPair: x25519KeyPair,
      x25519PubHex: x25519PubHex,
      mlkem768KeyPair: mlkem768KeyPair,
      mlkem768PubB64: mlkem768PubB64,
      accountRecordId: accountRecordId,
      userIndexRecordId: userIndexRecordId,
      legacyVaultRecordId: legacyVaultRecordId,
    );
  }

  Future<void> _activateAndPersistSession(_DerivedAccountKeys keys) async {
    _currentUserEmail = keys.email;
    _identitySeed = keys.identitySeed;
    _masterDek = keys.masterDek;
    _signingKeyPair = keys.signingKeyPair;
    _currentUserPubAddress = keys.pubAddress;
    _x25519KeyPair = keys.x25519KeyPair;
    _currentUserX25519PubHex = keys.x25519PubHex;
    _mlkem768KeyPair = keys.mlkem768KeyPair;
    _currentUserMlkem768PubB64 = keys.mlkem768PubB64;
    _pubkeyDirectoryPublished = false;

    final prefs = await SharedPreferences.getInstance();
    // Securely store identity seed and master DEK
    await _writeSecure(
      _secureIdentitySeedKey,
      base64Encode(keys.identitySeed),
      prefs,
    );
    await _writeSecure(
      _secureMasterDekKey,
      base64Encode(keys.masterDek),
      prefs,
    );

    await prefs.remove('pb_auth');
    await prefs.setString(
      _zkSessionPrefKey,
      jsonEncode({
        'email': keys.email,
        'pubAddress': keys.pubAddress,
      }),
    );

    await _ensureDefaultBudgetDescriptor();
    unawaited(_registerPublicIdentityDirectory().catchError((_) {}));
  }

  Future<void> _registerPublicIdentityDirectory() async {
    if (!isAuthenticated || _currentUserX25519PubHex == null) return;
    try {
      final payload = jsonEncode({
        'pubAddress': _currentUserPubAddress,
        'x25519Pub': _currentUserX25519PubHex,
        if (_currentUserMlkem768PubB64 != null)
          'mlkem768PubKey': _currentUserMlkem768PubB64,
        'kemScheme': PqeCrypto.hybridKemScheme,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _upsertStiQRcloudRecord(
        pubkeysCollection,
        _pubkeyRecordId,
        payload,
      );
      _pubkeyDirectoryPublished = true;
    } catch (_) {}
  }

  // Execute an operation against StiQRcloud nodes with automatic failover,
  // strict per-request timeouts, and exponential backoff with jitter on transient errors.
  Future<T> _withStiQRcloud<T>(
    Future<T> Function(sc.StiQRcloudClient client) action, {
    SimpleKeyPair? keyPairOverride,
    Duration timeout = const Duration(seconds: 8),
    int maxRetries = 2,
  }) async {
    final kp = keyPairOverride ?? _signingKeyPair;
    Object? lastError;
    final random = Random();

    for (final nodeUrl in stiqrCloudNodes) {
      final isLanNode = !nodeUrl.startsWith('https://');
      if (kIsWeb && isLanNode) {
        continue;
      }
      // Give LAN fallback a tiny timeout and zero retries so external users never hang
      final effectiveTimeout =
          isLanNode ? const Duration(milliseconds: 1500) : timeout;
      final effectiveRetries = isLanNode ? 0 : maxRetries;

      final client = sc.StiQRcloudClient(
        baseUrl: nodeUrl,
        keyPair: kp,
      );
      try {
        int attempt = 0;
        while (true) {
          try {
            return await action(client).timeout(effectiveTimeout);
          } on sc.StiQRcloudApiException catch (e) {
            // Non-retryable client errors
            if (e.statusCode == 404 ||
                e.statusCode == 400 ||
                e.statusCode == 401 ||
                e.statusCode == 403) {
              rethrow;
            }
            // 429 Too Many Requests or 5xx server errors qualify for retry
            if (attempt < effectiveRetries) {
              attempt++;
              final baseDelayMs = 400 * (1 << (attempt - 1)); // 400ms, 800ms
              final jitterMs = random.nextInt(200);
              await Future.delayed(Duration(milliseconds: baseDelayMs + jitterMs));
              continue;
            }
            lastError = e;
            break;
          } catch (e) {
            // Network drops, socket exceptions, timeouts
            if (attempt < effectiveRetries) {
              attempt++;
              final baseDelayMs = 400 * (1 << (attempt - 1));
              final jitterMs = random.nextInt(200);
              await Future.delayed(Duration(milliseconds: baseDelayMs + jitterMs));
              continue;
            }
            lastError = e;
            break;
          }
        }
      } finally {
        client.close();
      }
    }
    throw lastError ?? Exception('Unable to reach StiQRcloud network');
  }

  // Gracefully test /api/health against cloud nodes before reporting sync failure
  Future<bool> checkCloudHealth() async {
    for (final nodeUrl in stiqrCloudNodes) {
      final isLanNode = !nodeUrl.startsWith('https://');
      if (kIsWeb && isLanNode) {
        continue;
      }
      try {
        final uri = Uri.parse('$nodeUrl/api/health');
        final response = await http.get(uri).timeout(
              isLanNode
                  ? const Duration(milliseconds: 1500)
                  : const Duration(seconds: 4),
            );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  Future<sc.RecordModel?> _tryGetStiQRcloudRecord(
    String collection,
    String recordId, {
    SimpleKeyPair? keyPairOverride,
    Duration timeout = const Duration(seconds: 8),
    int maxRetries = 2,
  }) async {
    if (debugGetRecordOverride != null) {
      return debugGetRecordOverride!(collection, recordId);
    }
    try {
      return await _withStiQRcloud(
        (client) => client.collection(collection).getOne(recordId),
        keyPairOverride: keyPairOverride,
        timeout: timeout,
        maxRetries: maxRetries,
      );
    } on sc.StiQRcloudApiException catch (e) {
      if (e.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> _tryDeleteStiQRcloudRecord(
    String collection,
    String recordId, {
    SimpleKeyPair? keyPairOverride,
  }) async {
    try {
      await _withStiQRcloud(
        (client) => client.collection(collection).delete(recordId),
        keyPairOverride: keyPairOverride,
      ).timeout(const Duration(seconds: 6));
    } catch (_) {
      // Best-effort delete: ignore 404s, offline errors, or timeouts so account deletion always completes.
    }
  }

  Future<sc.RecordModel> _upsertStiQRcloudRecord(
    String collection,
    String recordId,
    String textPayload, {
    SimpleKeyPair? keyPairOverride,
  }) async {
    if (debugUpsertRecordOverride != null) {
      return debugUpsertRecordOverride!(collection, recordId, textPayload);
    }
    final existing = await _tryGetStiQRcloudRecord(
      collection,
      recordId,
      keyPairOverride: keyPairOverride,
    );
    if (existing != null) {
      return await _withStiQRcloud(
        (client) => client.collection(collection).update(
              recordId,
              {'text': textPayload},
            ),
        keyPairOverride: keyPairOverride,
      );
    } else {
      return await _withStiQRcloud(
        (client) => client.collection(collection).create(
              {'text': textPayload},
              id: recordId,
            ),
        keyPairOverride: keyPairOverride,
      );
    }
  }

  Future<String> _encryptPayload(String plaintext, Uint8List dek) async {
    final env = await sc.StiQRcloudCrypto.encryptText(plaintext, dek);
    return env.encode();
  }

  Future<String> _decryptPayload(String encodedText, Uint8List dek) async {
    String rawEnvelope = encodedText.trim();
    if (rawEnvelope.startsWith('{') && rawEnvelope.endsWith('}')) {
      try {
        final wrapper = jsonDecode(rawEnvelope) as Map<String, dynamic>;
        if (wrapper['ciphertext'] is String) {
          rawEnvelope = wrapper['ciphertext'] as String;
        }
      } catch (_) {}
    }
    final env = sc.EncryptedEnvelope.tryParse(rawEnvelope);
    if (env == null) {
      throw Exception('Invalid encrypted envelope format');
    }
    return sc.StiQRcloudCrypto.decryptText(env, dek);
  }

  // Wrap encrypted ciphertext with StiQRcloud ACL metadata (ownerPublicKey + editors)
  // so StiQRcloud's UpdateRecordWithAuth allows Full-Edit collaborators to write while blocking View-Only users.
  String _wrapAclRecordText({
    required String ownerPubAddress,
    required List<String> editorPubAddresses,
    required String ciphertext,
  }) {
    return jsonEncode({
      'ownerPublicKey': ownerPubAddress,
      'editors': editorPubAddresses,
      'ciphertext': ciphertext,
    });
  }

  // --- Sign Up / Login / PocketBase One-Time Migration ---

  Future<void> signUp(String email, String password) async {
    final keys = await _deriveAccountKeys(email, password);

    final existingAcct = await _tryGetStiQRcloudRecord(
      accountsCollection,
      keys.accountRecordId,
      keyPairOverride: keys.signingKeyPair,
      timeout: const Duration(seconds: 6),
      maxRetries: 1,
    );
    if (existingAcct != null) {
      throw Exception('An account with this email already exists.');
    }

    _resetMemoryState();
    await _activateAndPersistSession(keys);
    _hasLoadedRemoteOnce = true;
    _markAllOwnedBudgetsAndShardsDirty();
    await _saveStateToLocalCache();
    _connectSse();

    // Push account verifier and initial vault in the background so sign-up is instant
    unawaited(() async {
      try {
        await _uploadAccountVerifier(keys, migratedFromPb: true);
        await syncVaultToCloud();
      } catch (e) {
        print('Background sync after signUp failed (will retry): $e');
      }
    }());
  }

  Future<void> login(String email, String password) async {
    final keys = await _deriveAccountKeys(email, password);

    final existingAcct = await _tryGetStiQRcloudRecord(
      accountsCollection,
      keys.accountRecordId,
      keyPairOverride: keys.signingKeyPair,
      timeout: const Duration(seconds: 6),
      maxRetries: 1,
    );

    if (existingAcct != null) {
      Map<String, dynamic> verifierMap;
      try {
        final decryptedVerifier = await _decryptPayload(
          (existingAcct['text'] ?? '').toString(),
          keys.masterDek,
        );
        verifierMap = jsonDecode(decryptedVerifier) as Map<String, dynamic>;
      } catch (_) {
        throw Exception('Invalid email or password.');
      }

      final bool migratedFromPb = verifierMap['migratedFromPb'] == true;

      // Activate session & load local cache immediately so user enters DashboardView right away
      _resetMemoryState();
      await _activateAndPersistSession(keys);
      await _loadStateFromLocalCache();
      _connectSse();

      // Pull full cloud state (and handle any legacy migration) in the background
      unawaited(
        _postLoginBackgroundSync(
          email: email,
          password: password,
          keys: keys,
          migratedFromPb: migratedFromPb,
        ).catchError((_) {}),
      );
      return;
    }

    // First login on StiQRcloud: authenticate with PocketBase once, grab all data, sync in background
    await _migrateFromPocketBaseAndUpload(email, password, keys);
  }

  Future<void> _postLoginBackgroundSync({
    required String email,
    required String password,
    required _DerivedAccountKeys keys,
    required bool migratedFromPb,
  }) async {
    if (!isAuthenticated || _currentUserPubAddress != keys.pubAddress) return;
    try {
      await _pullAllFromCloud(notifyChanges: true);
      if (!isAuthenticated || _currentUserPubAddress != keys.pubAddress) return;

      // If this account had not yet migrated from PocketBase, attempt background migration
      if (!migratedFromPb && _categories.where((c) => !c.isUnallocated).isEmpty) {
        try {
          await _migrateFromPocketBaseAndUpload(email, password, keys);
          return;
        } catch (_) {}
      }

      await _saveStateToLocalCache();
      _notifyMetadataListeners();
    } catch (e) {
      print('Background post-login sync error: $e');
    }
  }

  Future<void> _importMonolithicVaultAndShard(
    Map<String, dynamic> vaultMap, {
    bool mergeExistingTransactions = false,
  }) async {
    final rawCategories = (vaultMap['categories'] as List<dynamic>?) ?? [];
    final importedCats = rawCategories.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      map['user'] = _currentUserPubAddress ?? (map['user'] ?? '');
      return Category.fromJson(map);
    }).toList();

    final rawTransactions = (vaultMap['transactions'] as List<dynamic>?) ?? [];
    final importedTxs = rawTransactions.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      map['user'] = _currentUserPubAddress ?? (map['user'] ?? '');
      return TransactionModel.fromJson(map);
    }).toList();

    if ((mergeExistingTransactions || _transactions.isNotEmpty) &&
        _transactions.isNotEmpty) {
      _transactions = mergeTransactions(importedTxs, _transactions, _deletedTxIds)
        ..sort((a, b) => b.date.compareTo(a.date));
    } else {
      _transactions = importedTxs..sort((a, b) => b.date.compareTo(a.date));
    }

    final mergedCats = _categories.isNotEmpty
        ? mergeCategories(importedCats, _categories, _deletedCatIds)
        : importedCats;
    _categories = _deduplicateUnallocatedCategories(mergedCats);

    final rawRules = (vaultMap['rules'] as List<dynamic>?) ?? [];
    _rules = rawRules.map((item) => Map<String, dynamic>.from(item as Map)).toList();

    final prefs = await SharedPreferences.getInstance();
    if (vaultMap['budgets'] is List) {
      await prefs.setString(_budgetsPrefKey, jsonEncode(vaultMap['budgets']));
    }
    if (vaultMap['categoryOrders'] is Map) {
      final ordersMap = Map<String, dynamic>.from(vaultMap['categoryOrders'] as Map);
      for (final entry in ordersMap.entries) {
        if (entry.value is List) {
          final orderList = (entry.value as List).map((e) => e.toString()).toList();
          await prefs.setStringList('category_order_${entry.key}', orderList);
        }
      }
    }
    if (vaultMap['expectedMonthlyIncome'] is num) {
      await prefs.setDouble(
        'expected_monthly_income',
        (vaultMap['expectedMonthlyIncome'] as num).toDouble(),
      );
    }
    if (vaultMap['paychecksPerMonth'] is num) {
      await prefs.setInt(
        'paychecks_per_month',
        (vaultMap['paychecksPerMonth'] as num).toInt(),
      );
    }
    await _discoverBudgetsFromCategories(_categories);
    await _ensureDefaultBudgetDescriptor();
    _shardedV3Ready = true;
    _markAllOwnedBudgetsAndShardsDirty();
  }

  List<Category> _deduplicateUnallocatedCategories(List<Category> input) {
    final referencedCatIds = <String>{};
    for (final tx in _transactions) {
      if (tx.category != null) referencedCatIds.add(tx.category!);
      if (tx.sourceCategory != null) referencedCatIds.add(tx.sourceCategory!);
      if (tx.destinationCategory != null) referencedCatIds.add(tx.destinationCategory!);
    }

    final unallocatedByBudget = <String, List<Category>>{};
    for (final c in input) {
      if (c.isUnallocated) {
        unallocatedByBudget.putIfAbsent(c.budgetId, () => <Category>[]).add(c);
      }
    }

    final keepUnallocatedIds = <String>{};
    for (final entry in unallocatedByBudget.entries) {
      final candidates = entry.value;
      if (candidates.length == 1) {
        keepUnallocatedIds.add(candidates.first.id);
      } else {
        candidates.sort((a, b) {
          final aRef = referencedCatIds.contains(a.id) ? 1 : 0;
          final bRef = referencedCatIds.contains(b.id) ? 1 : 0;
          if (aRef != bRef) return bRef.compareTo(aRef);
          return b.balance.abs().compareTo(a.balance.abs());
        });
        keepUnallocatedIds.add(candidates.first.id);
      }
    }

    return input.where((c) => !c.isUnallocated || keepUnallocatedIds.contains(c.id)).toList();
  }

  Future<void> _migrateFromPocketBaseAndUpload(
    String rawEmail,
    String password,
    _DerivedAccountKeys keys,
  ) async {
    final tempPb = PocketBase(legacyPbUrl);
    try {
      try {
        await tempPb
            .collection('users')
            .authWithPassword(
              rawEmail.trim(),
              password,
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        if (rawEmail.trim() != keys.email) {
          await tempPb
              .collection('users')
              .authWithPassword(
                keys.email,
                password,
              )
              .timeout(const Duration(seconds: 8));
        } else {
          rethrow;
        }
      }
    } catch (_) {
      throw Exception('Invalid email or password.');
    }

    final pbUserId = tempPb.authStore.record?.id;
    if (pbUserId == null || pbUserId.isEmpty) {
      throw Exception('Failed to read user ID from PocketBase.');
    }

    final pbCategoryRecords = await tempPb.collection('categories').getFullList(
          filter: 'user = "$pbUserId"',
          sort: 'name',
        );
    final migratedCategories = pbCategoryRecords.map((rec) {
      final json = rec.toJson();
      json['user'] = keys.pubAddress;
      return Category.fromJson(json);
    }).toList();

    final pbTxRecords = await tempPb.collection('transactions').getFullList(
          filter: 'user = "$pbUserId"',
          sort: '-date',
        );
    final migratedTransactions = pbTxRecords.map((rec) {
      final json = rec.toJson();
      json['user'] = keys.pubAddress;
      return TransactionModel.fromJson(json);
    }).toList();

    final List<Map<String, dynamic>> migratedRules = [];
    try {
      final pbRuleRecords = await tempPb.collection('rules').getFullList(
            filter: 'user = "$pbUserId"',
          );
      for (final rec in pbRuleRecords) {
        final rJson = rec.toJson();
        migratedRules.add({
          'id': rec.id,
          'pattern': (rJson['pattern'] ?? '').toString(),
          'category': (rJson['category'] ?? '').toString(),
          'user': keys.pubAddress,
        });
      }
    } catch (_) {}

    tempPb.authStore.clear();

    // Preserve any local in-memory envelopes/transactions/rules created since login
    // if migration was triggered in the background by _postLoginBackgroundSync().
    final sameUserActive = _currentUserPubAddress == keys.pubAddress;
    final existingLocalCats =
        sameUserActive ? List<Category>.from(_categories) : <Category>[];
    final existingLocalTxs = sameUserActive
        ? List<TransactionModel>.from(_transactions)
        : <TransactionModel>[];
    final existingLocalRules = sameUserActive
        ? List<Map<String, dynamic>>.from(_rules)
        : <Map<String, dynamic>>[];
    final existingDeletedCatIds =
        sameUserActive ? Set<String>.from(_deletedCatIds) : <String>{};
    final existingDeletedTxIds =
        sameUserActive ? Set<String>.from(_deletedTxIds) : <String>{};

    _resetMemoryState();
    await _activateAndPersistSession(keys);
    _deletedCatIds.addAll(existingDeletedCatIds);
    _deletedTxIds.addAll(existingDeletedTxIds);
    final combinedCats = existingLocalCats.isNotEmpty
        ? mergeCategories(migratedCategories, existingLocalCats, _deletedCatIds)
        : migratedCategories;
    _categories = _deduplicateUnallocatedCategories(combinedCats);
    _transactions = existingLocalTxs.isNotEmpty
        ? (mergeTransactions(migratedTransactions, existingLocalTxs, _deletedTxIds)
          ..sort((a, b) => b.date.compareTo(a.date)))
        : migratedTransactions;
    if (existingLocalRules.isNotEmpty) {
      final mergedRulesMap = <String, Map<String, dynamic>>{};
      for (final r in migratedRules) {
        mergedRulesMap[(r['id'] ?? '${r['category']}_${r['type']}').toString()] = r;
      }
      for (final r in existingLocalRules) {
        mergedRulesMap[(r['id'] ?? '${r['category']}_${r['type']}').toString()] = r;
      }
      _rules = mergedRulesMap.values.toList();
    } else {
      _rules = migratedRules;
    }
    _localCacheLoaded = true;
    _hasLoadedRemoteOnce = true;
    _shardedV3Ready = true;

    await _discoverBudgetsFromCategories(_categories);
    await _ensureDefaultBudgetDescriptor();
    _markAllOwnedBudgetsAndShardsDirty();

    await _saveStateToLocalCache();
    _connectSse();
    _notifyMetadataListeners();

    // Upload migrated vault & verifier in the background so login completes immediately
    unawaited(() async {
      try {
        await syncVaultToCloud();
        await _uploadAccountVerifier(keys, migratedFromPb: true);
      } catch (e) {
        print('Background upload after PocketBase migration failed: $e');
      }
    }());
  }

  Future<void> _uploadAccountVerifier(
    _DerivedAccountKeys keys, {
    required bool migratedFromPb,
  }) async {
    final verifierJson = jsonEncode({
      'v': 3,
      'pubAddress': keys.pubAddress,
      'x25519Pub': keys.x25519PubHex,
      'mlkem768PubKey': keys.mlkem768PubB64,
      'emailHash': sc.StiQRcloudCrypto.sha256Hex(utf8.encode(keys.email)),
      'migratedFromPb': migratedFromPb,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final encryptedVerifier = await _encryptPayload(verifierJson, keys.masterDek);

    await _upsertStiQRcloudRecord(
      accountsCollection,
      keys.accountRecordId,
      encryptedVerifier,
      keyPairOverride: keys.signingKeyPair,
    );
  }

  void _resetMemoryState() {
    _budgetsByLocalId.clear();
    _localIdBySharedKey.clear();
    _loadedShardRevisions.clear();
    _dirtyMonthsBySharedKey.clear();
    _dirtyBudgetMetaKeys.clear();
    _budgetMetaDirtyGen.clear();
    _userIndexDirty = false;
    _localCacheLoaded = false;
    _categories = [];
    _transactions = [];
    _rules = [];
    _userIndexUpdatedAt = 0;
    _budgetMetaUpdatedAt.clear();
    _hasLoadedRemoteOnce = false;
    _shardedV3Ready = false;
    _inFlightPull = null;
    _inFlightPush = null;
    _pushDepth = 0;
    _upgradedHybridGrantIds.clear();
    _deletedTxIds.clear();
    _deletedCatIds.clear();
    _sessionCreatedTxIds.clear();
    _unsyncedLocalTxIds.clear();
    _resolvedDuplicatePairs.clear();
  }

  /// Permanently purges the authenticated user's owned StiQRcloud records
  /// (best-effort per record), removes all local user-scoped SharedPreferences
  /// and secure storage keys, and signs out.
  Future<void> deleteAccount() async {
    stopBackgroundSync();
    _disconnectSse();

    final pub = _currentUserPubAddress;
    final email = _currentUserEmail;
    final signingKp = _signingKeyPair;
    final ownedBudgets = _budgetsByLocalId.values.where((b) => b.isOwner).toList();

    // 1. Best-effort cloud purge of all owned StiQRcloud records using signed delete requests
    if (isAuthenticated && pub != null && signingKp != null) {
      final deleteFutures = <Future<void>>[];

      // User index, public key directory, and legacy vault
      deleteFutures.add(_tryDeleteStiQRcloudRecord(
        userIndexCollection,
        _userIndexRecordId,
        keyPairOverride: signingKp,
      ));
      deleteFutures.add(_tryDeleteStiQRcloudRecord(
        pubkeysCollection,
        _pubkeyRecordId,
        keyPairOverride: signingKp,
      ));
      deleteFutures.add(_tryDeleteStiQRcloudRecord(
        legacyVaultCollection,
        'vault_${pub.substring(0, 24)}',
        keyPairOverride: signingKp,
      ));

      // Account record (derived from normalized email)
      if (email != null && email.trim().isNotEmpty) {
        final cleanEmail = email.trim().toLowerCase();
        final acctHash = sc.StiQRcloudCrypto.sha256Hex(
          utf8.encode('stiqrbudget:acct:$cleanEmail'),
        );
        deleteFutures.add(_tryDeleteStiQRcloudRecord(
          accountsCollection,
          'acct_${acctHash.substring(0, 24)}',
          keyPairOverride: signingKp,
        ));
      }

      // Owned budgets: metadata, transaction shards, and collaborator grants
      for (final desc in ownedBudgets) {
        final sharedKey = desc.sharedBudgetKey;
        deleteFutures.add(_tryDeleteStiQRcloudRecord(
          budgetMetaCollection,
          'bmeta_$sharedKey',
          keyPairOverride: signingKp,
        ));

        final months = <String>{
          ...(_loadedShardRevisions[sharedKey]?.keys ?? const <String>[]),
          ...(_dirtyMonthsBySharedKey[sharedKey] ?? const <String>{}),
          ..._transactionsForBudget(desc.localBudgetId)
              .map((tx) => _monthKeyForDate(tx.date)),
        };
        for (final month in months) {
          deleteFutures.add(_tryDeleteStiQRcloudRecord(
            txShardsCollection,
            'btx_${sharedKey}_$month',
            keyPairOverride: signingKp,
          ));
        }

        for (final collab in desc.collaborators) {
          final grantIdHash = sc.StiQRcloudCrypto.sha256Hex(
            utf8.encode('grant:$sharedKey:${collab.pubAddress}'),
          ).substring(0, 24);
          deleteFutures.add(_tryDeleteStiQRcloudRecord(
            grantsCollection,
            'grant_$grantIdHash',
            keyPairOverride: signingKp,
          ));
        }
      }

      await Future.wait(deleteFutures);
    }

    // 2. Purge all local user-scoped SharedPreferences & secure storage keys
    try {
      final prefs = await SharedPreferences.getInstance();
      await _deleteSecure(_secureIdentitySeedKey, prefs);
      await _deleteSecure(_secureMasterDekKey, prefs);

      final keysToRemove = <String>{
        _zkSessionPrefKey,
        'pb_auth',
        'budgets_list',
        'active_budget_id',
        'budgets_list_guest',
        'active_budget_id_guest',
        'last_undo_action',
        'expected_monthly_income',
        'paychecks_per_month',
      };

      if (pub != null && pub.isNotEmpty) {
        keysToRemove.add('budgets_list_$pub');
        keysToRemove.add('active_budget_id_$pub');
        keysToRemove.add('$_localCachePrefix$pub');
        keysToRemove.add('stiqrbudget_vault_cache_$pub');
      }

      for (final key in prefs.getKeys()) {
        if (key.startsWith('zk_fallback_') ||
            key.startsWith('expected_monthly_income_') ||
            key.startsWith('paychecks_per_month_') ||
            key.startsWith('category_order_') ||
            key.startsWith(_localCachePrefix) ||
            key.startsWith('stiqrbudget_vault_cache_') ||
            (pub != null && pub.isNotEmpty && key.contains(pub))) {
          keysToRemove.add(key);
        }
      }

      for (final key in keysToRemove) {
        await prefs.remove(key);
      }
    } catch (_) {}

    // 3. Finish by clearing session & in-memory state
    logout();
  }

  void logout() {
    _disconnectSse();
    _currentUserEmail = null;
    _currentUserPubAddress = null;
    _currentUserX25519PubHex = null;
    _currentUserMlkem768PubB64 = null;
    _identitySeed = null;
    _masterDek = null;
    _signingKeyPair = null;
    _x25519KeyPair = null;
    _mlkem768KeyPair = null;
    _pubkeyDirectoryPublished = false;
    _budgetsByLocalId.clear();
    _localIdBySharedKey.clear();
    _categories.clear();
    _transactions.clear();
    _resetMemoryState();
    pb.authStore.clear();

    SharedPreferences.getInstance().then((prefs) {
      _deleteSecure(_secureIdentitySeedKey, prefs).ignore();
      _deleteSecure(_secureMasterDekKey, prefs).ignore();
      prefs.remove(_zkSessionPrefKey);
      prefs.remove('pb_auth');
      prefs.remove('budgets_list');
      prefs.remove('active_budget_id');
    });
  }

  // --- Monthly Sharding Helpers ---

  String _monthKeyForDate(DateTime date) {
    final utc = date.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  String _budgetIdForTransaction(TransactionModel tx) {
    final catMap = {for (final c in _categories) c.id: c};
    if (tx.type == TransactionType.transfer) {
      final src = tx.sourceCategory != null ? catMap[tx.sourceCategory!] : null;
      if (src != null) return src.budgetId;
      final dst = tx.destinationCategory != null ? catMap[tx.destinationCategory!] : null;
      if (dst != null) return dst.budgetId;
    } else if (tx.category != null) {
      final cat = catMap[tx.category!];
      if (cat != null) return cat.budgetId;
    }
    return '_inbox_';
  }

  List<TransactionModel> _transactionsForBudget(String localBudgetId) {
    final catIds = _categories
        .where((c) => c.budgetId == localBudgetId)
        .map((c) => c.id)
        .toSet();
    return _transactions.where((tx) {
      if (tx.type == TransactionType.transfer) {
        return catIds.contains(tx.sourceCategory) ||
            catIds.contains(tx.destinationCategory);
      }
      if (tx.category != null) {
        return catIds.contains(tx.category);
      }
      return false;
    }).toList();
  }

  List<TransactionModel> _inboxTransactions() {
    return _transactions
        .where((tx) => tx.type != TransactionType.transfer && tx.category == null)
        .toList();
  }

  void _addDirtyBudgetMetaKey(String sharedKey) {
    _dirtyBudgetMetaKeys.add(sharedKey);
    _budgetMetaDirtyGen[sharedKey] = (_budgetMetaDirtyGen[sharedKey] ?? 0) + 1;
  }

  void _markBudgetMetaDirty(String localBudgetId) {
    final desc = _budgetsByLocalId[localBudgetId];
    if (desc != null && desc.canEdit) {
      _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
    }
  }

  void _markTransactionDirty(TransactionModel tx) {
    final bId = _budgetIdForTransaction(tx);
    if (bId == '_inbox_') {
      _userIndexDirty = true;
      return;
    }
    final desc = _budgetsByLocalId[bId];
    if (desc != null && desc.canEdit) {
      final monthKey = _monthKeyForDate(tx.date);
      _dirtyMonthsBySharedKey
          .putIfAbsent(desc.sharedBudgetKey, () => <String>{})
          .add(monthKey);
      _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
    }
  }

  void _markAllOwnedBudgetsAndShardsDirty() {
    _userIndexDirty = true;
    for (final desc in _budgetsByLocalId.values) {
      if (!desc.canEdit) continue;
      _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
      final budgetTxs = _transactionsForBudget(desc.localBudgetId);
      final months = _dirtyMonthsBySharedKey.putIfAbsent(
        desc.sharedBudgetKey,
        () => <String>{},
      );
      for (final tx in budgetTxs) {
        months.add(_monthKeyForDate(tx.date));
      }
    }
  }

  // --- Pushing Dirty Shards & Meta to StiQRcloud ---

  /// Marks a duplicate transaction pair as resolved/dismissed so it will never
  /// be prompted again on subsequent syncs or app restarts.
  Future<void> markDuplicatePairResolved(String idA, String idB) async {
    final key = duplicatePairKey(idA, idB);
    if (_resolvedDuplicatePairs.add(key)) {
      await _saveStateToLocalCache();
    }
  }

  /// Resolves a duplicate pair by deleting [pair.remoteTx], marking it in
  /// `_deletedTxIds`, marking the pair resolved, and syncing immediately so
  /// the duplicate never resurrects.
  Future<void> resolveDuplicateKeepOnlyOne(DuplicateTxPair pair) async {
    final key = duplicatePairKey(pair.localTx.id, pair.remoteTx.id);
    _resolvedDuplicatePairs.add(key);
    // Ensure the remote transaction's month is marked dirty even if not yet in _transactions
    _markTransactionDirty(pair.remoteTx);
    await deleteTransaction(pair.remoteTx.id, syncImmediately: true);
    await _saveStateToLocalCache();
  }

  /// Exposes duplicate checking for sync merge paths and unit tests.
  @visibleForTesting
  List<DuplicateTxPair> checkAndNotifyDuplicates(
    List<TransactionModel> remote,
    List<TransactionModel> local, {
    DateTime? now,
  }) {
    final pairs = findPotentialDuplicates(
      remote,
      local,
      deletedIds: _deletedTxIds,
      sessionCreatedIds: _sessionCreatedTxIds,
      unsyncedLocalIds: _unsyncedLocalTxIds.isEmpty ? null : _unsyncedLocalTxIds,
      resolvedPairs: _resolvedDuplicatePairs,
      now: now,
    );
    final fresh = <DuplicateTxPair>[];
    for (final p in pairs) {
      final key = duplicatePairKey(p.localTx.id, p.remoteTx.id);
      if (_resolvedDuplicatePairs.add(key)) {
        fresh.add(p);
      }
    }
    if (fresh.isNotEmpty) {
      unawaited(_saveStateToLocalCache());
      onDuplicateTransactionsDetected?.call(fresh);
    }
    return fresh;
  }

  void _notifyIfDuplicates(
    List<TransactionModel> remote,
    List<TransactionModel> local,
  ) {
    checkAndNotifyDuplicates(remote, local);
  }

  void markBudgetMetaDirty(String localBudgetId) =>
      _markBudgetMetaDirty(localBudgetId);

  Future<void> syncVaultToCloud() async {
    if (!isAuthenticated) return;

    // Wait for any in-flight pull before pushing so we never overwrite cloud data with partial local state
    if (_inFlightPull != null) {
      await _inFlightPull;
    }
    if (!_hasLoadedRemoteOnce) {
      await _pullAllFromCloud(notifyChanges: false);
    }

    await _ensureDefaultBudgetDescriptor();
    await _saveStateToLocalCache();
    if (!_pubkeyDirectoryPublished) {
      unawaited(_registerPublicIdentityDirectory());
    }

    // Serialize pushes so two concurrent calls never clear each other's dirty sets
    while (_inFlightPush != null) {
      await _inFlightPush;
    }

    final pushFuture = _pushDirtyStateInternal();
    _inFlightPush = pushFuture;
    try {
      await pushFuture;
    } catch (e) {
      // Check cloud node health gracefully before declaring offline/failure
      final healthy = await checkCloudHealth();
      print('Cloud push failed (health=$healthy, queued locally for next sync): $e');
      // Save state to local cache so offline mutations persist across app restarts
      await _saveStateToLocalCache();
    } finally {
      if (identical(_inFlightPush, pushFuture)) {
        _inFlightPush = null;
      }
    }
  }

  Future<void> _pushDirtyStateInternal() async {
    if (!isAuthenticated) return;
    _pushDepth++;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();

      // Ensure any budget metadata changes (rename/add budget, income settings) mark userIndex dirty
      if (_dirtyBudgetMetaKeys.isEmpty && _dirtyMonthsBySharedKey.isEmpty) {
        _userIndexDirty = true;
        for (final desc in _budgetsByLocalId.values) {
          if (desc.canEdit) {
            _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
          }
        }
      }

      // Snapshot dirty months so mutations during network awaits are not lost
      final snapshotMonths = <String, Set<String>>{
        for (final entry in _dirtyMonthsBySharedKey.entries)
          entry.key: Set<String>.from(entry.value),
      };

      // 1. Upload dirty monthly transaction shards per budget
      for (final entry in snapshotMonths.entries) {
        final sharedKey = entry.key;
        final dirtyMonths = entry.value;
        final localBudgetId = _localIdBySharedKey[sharedKey];
        if (localBudgetId == null) continue;
        final desc = _budgetsByLocalId[localBudgetId];
        if (desc == null || !desc.canEdit) continue;

        final budgetTxs = _transactionsForBudget(localBudgetId);
        final editorPubs = desc.collaborators
            .where((c) => c.canEdit)
            .map((c) => c.pubAddress)
            .toList();

        for (final month in dirtyMonths) {
          final localMonthTxs = budgetTxs
              .where((tx) => _monthKeyForDate(tx.date) == month)
              .toList();
          final shardRecordId = 'btx_${sharedKey}_$month';

          // Non-destructive merge: pull latest remote shard first so we never
          // overwrite transactions added by collaborators since our last pull.
          List<TransactionModel> mergedMonthTxs = localMonthTxs;
          try {
            final remoteShard = await _tryGetStiQRcloudRecord(
              txShardsCollection,
              shardRecordId,
            );
            if (remoteShard != null) {
              final remoteDec = await _decryptPayload(
                (remoteShard['text'] ?? '').toString(),
                desc.budgetDek,
              );
              final remoteMap = jsonDecode(remoteDec) as Map<String, dynamic>;
              final rawRemoteTxs =
                  (remoteMap['transactions'] as List<dynamic>?) ?? [];
              final remoteMonthTxs = rawRemoteTxs
                  .map((e) => TransactionModel.fromJson(
                      Map<String, dynamic>.from(e as Map)))
                  .toList();
              mergedMonthTxs = mergeTransactions(
                remoteMonthTxs,
                localMonthTxs,
                _deletedTxIds,
              );
              _notifyIfDuplicates(remoteMonthTxs, localMonthTxs);
              // Keep local _transactions in sync with any newly discovered remote txs
              final localIds = _transactions.map((t) => t.id).toSet();
              for (final rtx in remoteMonthTxs) {
                if (!localIds.contains(rtx.id) &&
                    !_deletedTxIds.contains(rtx.id)) {
                  _transactions.add(rtx);
                  localIds.add(rtx.id);
                }
              }
            }
          } catch (e) {
            print('Note: could not pre-merge remote tx shard $shardRecordId: $e');
          }

          final shardPayload = jsonEncode({
            'v': 2,
            'sharedBudgetKey': sharedKey,
            'month': month,
            'updatedAt': nowMs,
            'transactions': mergedMonthTxs.map((t) => t.toJson()).toList(),
          });
          final encryptedShard = await _encryptPayload(shardPayload, desc.budgetDek);
          final wrappedText = _wrapAclRecordText(
            ownerPubAddress: desc.ownerPubAddress,
            editorPubAddresses: editorPubs,
            ciphertext: encryptedShard,
          );
          await _upsertStiQRcloudRecord(
            txShardsCollection,
            shardRecordId,
            wrappedText,
          );
          for (final tx in mergedMonthTxs) {
            _unsyncedLocalTxIds.remove(tx.id);
          }
          _loadedShardRevisions
              .putIfAbsent(sharedKey, () => <String, int>{})[month] = nowMs;
          _dirtyMonthsBySharedKey[sharedKey]?.remove(month);
        }
        if (_dirtyMonthsBySharedKey[sharedKey]?.isEmpty ?? false) {
          _dirtyMonthsBySharedKey.remove(sharedKey);
        }
      }

      // 2. Upload dirty budget meta records (categories, rules, collaborators, shardRevisions)
      final snapshotMetaKeys = Set<String>.from(_dirtyBudgetMetaKeys);
      for (final sharedKey in snapshotMetaKeys) {
        final localBudgetId = _localIdBySharedKey[sharedKey];
        if (localBudgetId == null) continue;
        final desc = _budgetsByLocalId[localBudgetId];
        if (desc == null || !desc.canEdit) continue;

        // Snapshot dirty generation before capturing categories and awaiting network calls
        final genAtStart = _budgetMetaDirtyGen[sharedKey] ?? 0;

        // Collect all months that exist for this budget so shardRevisions is complete
        final budgetTxs = _transactionsForBudget(localBudgetId);
        final revMap = _loadedShardRevisions.putIfAbsent(
          sharedKey,
          () => <String, int>{},
        );
        final activeMonths = budgetTxs.map((t) => _monthKeyForDate(t.date)).toSet();
        for (final m in activeMonths) {
          revMap.putIfAbsent(m, () => nowMs);
        }

        final localBudgetCats = _categories
            .where((c) => c.budgetId == localBudgetId)
            .toList();

        // Non-destructive merge: pull latest remote bmeta before pushing
        List<Category> mergedCats = localBudgetCats;
        List<Map<String, dynamic>> remoteRules = [];
        try {
          final remoteMeta = await _tryGetStiQRcloudRecord(
            budgetMetaCollection,
            'bmeta_$sharedKey',
          );
          if (remoteMeta != null) {
            final remoteDec = await _decryptPayload(
              (remoteMeta['text'] ?? '').toString(),
              desc.budgetDek,
            );
            final remoteMap = jsonDecode(remoteDec) as Map<String, dynamic>;
            final rawRemoteCats =
                (remoteMap['categories'] as List<dynamic>?) ?? [];
            final remoteCats = rawRemoteCats
                .map((item) => Category.fromJson(
                        Map<String, dynamic>.from(item as Map))
                    .copyWith(budgetId: localBudgetId))
                .toList();
            mergedCats = mergeCategories(
              remoteCats,
              localBudgetCats,
              _deletedCatIds,
            );
            // Keep local _categories in sync with any newly discovered remote cats
            final localCatIds = _categories.map((c) => c.id).toSet();
            for (final rc in remoteCats) {
              if (!localCatIds.contains(rc.id) &&
                  !_deletedCatIds.contains(rc.id)) {
                _categories.add(rc);
                localCatIds.add(rc.id);
              }
            }

            final rawRemoteRules =
                (remoteMap['rules'] as List<dynamic>?) ?? [];
            remoteRules = rawRemoteRules
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList();

            if (remoteMap['shardRevisions'] is Map) {
              final rRevs = Map<String, dynamic>.from(
                  remoteMap['shardRevisions'] as Map);
              for (final rEntry in rRevs.entries) {
                final rVal = (rEntry.value as num?)?.toInt() ?? 0;
                final lVal = revMap[rEntry.key] ?? 0;
                if (rVal > lVal) {
                  revMap[rEntry.key] = rVal;
                }
              }
            }
          }
        } catch (e) {
          print('Note: could not pre-merge remote bmeta_$sharedKey: $e');
        }

        final budgetCats = mergedCats.map((c) {
          final json = c.toJson();
          // Store stripped category name inside budget meta so owner and collaborator localBudgetIds map cleanly
          json['name'] = c.name;
          return json;
        }).toList();

        final catIds = mergedCats.map((c) => c.id).toSet();
        final localBudgetRules = _rules
            .where((r) => catIds.contains(r['category']))
            .toList();
        final mergedRulesMap = <String, Map<String, dynamic>>{};
        for (final r in remoteRules) {
          final key = (r['id'] ?? '${r['category']}_${r['type']}').toString();
          mergedRulesMap[key] = r;
        }
        for (final r in localBudgetRules) {
          final key = (r['id'] ?? '${r['category']}_${r['type']}').toString();
          mergedRulesMap[key] = r;
        }
        final budgetRules = mergedRulesMap.values.toList();

        final orderList =
            prefs.getStringList('category_order_$localBudgetId') ?? <String>[];
        final budgetExpectedIncome =
            prefs.getDouble('expected_monthly_income_$localBudgetId') ??
                prefs.getDouble('expected_monthly_income') ??
                5000.0;
        final budgetPaychecksPerMonth =
            prefs.getInt('paychecks_per_month_$localBudgetId') ??
                prefs.getInt('paychecks_per_month') ??
                2;

        final editorPubs = desc.collaborators
            .where((c) => c.canEdit)
            .map((c) => c.pubAddress)
            .toList();

        final metaPayload = jsonEncode({
          'v': 2,
          'sharedBudgetKey': sharedKey,
          'budgetName': desc.name,
          'ownerPubAddress': desc.ownerPubAddress,
          'updatedAt': nowMs,
          'expectedMonthlyIncome': budgetExpectedIncome,
          'paychecksPerMonth': budgetPaychecksPerMonth,
          'categories': budgetCats,
          'rules': budgetRules,
          'categoryOrder': orderList,
          'collaborators': desc.collaborators.map((c) => c.toJson()).toList(),
          'shardRevisions': revMap,
        });

        final encryptedMeta = await _encryptPayload(metaPayload, desc.budgetDek);
        final wrappedMeta = _wrapAclRecordText(
          ownerPubAddress: desc.ownerPubAddress,
          editorPubAddresses: editorPubs,
          ciphertext: encryptedMeta,
        );

        await _upsertStiQRcloudRecord(
          budgetMetaCollection,
          'bmeta_$sharedKey',
          wrappedMeta,
        );
        _budgetMetaUpdatedAt[sharedKey] = nowMs;
        if ((_budgetMetaDirtyGen[sharedKey] ?? 0) == genAtStart) {
          _dirtyBudgetMetaKeys.remove(sharedKey);
        }
      }

      // 3. Upload user personal index if dirty
      if (_userIndexDirty) {
        final ownedList = _budgetsByLocalId.values
            .where((d) => d.isOwner)
            .map((d) => {
                  'id': d.localBudgetId,
                  'name': d.name,
                  'sharedBudgetKey': d.sharedBudgetKey,
                  'budgetDekB64': base64Encode(d.budgetDek),
                })
            .toList();

        final expectedMonthlyIncome =
            prefs.getDouble('expected_monthly_income') ?? 5000.0;
        final paychecksPerMonth = prefs.getInt('paychecks_per_month') ?? 2;
        final inboxTxs = _inboxTransactions().map((t) => t.toJson()).toList();

        final userIndexPayload = jsonEncode({
          'v': 2,
          'shardedSchemaVersion': 3,
          'updatedAt': nowMs,
          'user': _currentUserPubAddress,
          'ownedBudgets': ownedList,
          'expectedMonthlyIncome': expectedMonthlyIncome,
          'paychecksPerMonth': paychecksPerMonth,
          'inboxTransactions': inboxTxs,
        });

        final encryptedIndex = await _encryptPayload(
          userIndexPayload,
          _masterDek!,
        );
        await _upsertStiQRcloudRecord(
          userIndexCollection,
          _userIndexRecordId,
          encryptedIndex,
        );
        _userIndexUpdatedAt = nowMs;
        _shardedV3Ready = true;
        _userIndexDirty = false;
      }
    } catch (e) {
      print('Warning: Failed to sync sharded budget data to StiQRcloud: $e');
    } finally {
      _pushDepth--;
      _lastPushFinishedMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  // --- Pulling & Merging Sharded Data from StiQRcloud ---

  Future<bool> _pullAllFromCloud({required bool notifyChanges}) async {
    if (!isAuthenticated) return false;

    // If a pull is already in flight, await it so callers (like fetchCategories) get the loaded data!
    if (_inFlightPull != null) {
      final res = await _inFlightPull!;
      if (notifyChanges && res) {
        _notifyMetadataListeners();
      }
      return res;
    }

    final pullFuture = _doPullAllFromCloud(notifyChanges: notifyChanges);
    _inFlightPull = pullFuture;
    try {
      return await pullFuture;
    } finally {
      if (identical(_inFlightPull, pullFuture)) {
        _inFlightPull = null;
      }
    }
  }

  Future<bool> _doPullAllFromCloud({required bool notifyChanges}) async {
    try {
      bool anyChanged = false;

      // 1. Pull user's personal index (owned budgets, income settings, inbox transactions)
      final uindexRecord = await _tryGetStiQRcloudRecord(
        userIndexCollection,
        _userIndexRecordId,
      );
      if (uindexRecord != null) {
        final changed = await _applyUserIndexRecord(
          uindexRecord,
          notifyChanges: notifyChanges,
        );
        if (changed) anyChanged = true;
      }

      // 2. Discover any budgets shared with this user via stiqrbudget_grants
      final grantsChanged = await _discoverSharedBudgetsFromGrants();
      if (grantsChanged) anyChanged = true;

      // 3. For every owned + shared budget, pull its bmeta_<sharedKey> and any updated monthly shards
      for (final desc in List<BudgetDescriptor>.from(_budgetsByLocalId.values)) {
        final bmetaRec = await _tryGetStiQRcloudRecord(
          budgetMetaCollection,
          'bmeta_${desc.sharedBudgetKey}',
        );
        if (bmetaRec != null) {
          final changed = await _applyBudgetMetaRecord(
            desc,
            bmetaRec,
            notifyChanges: notifyChanges,
          );
          if (changed) anyChanged = true;
        }
      }

      // 4. Auto-recover / migrate from v1.0.3 monolithic stiqrbudget_vault if shardedSchemaVersion < 3
      //    or if non-unallocated envelopes were wiped by the earlier v1.0.4 race condition!
      final realCategoryCount = _categories.where((c) => !c.isUnallocated).length;
      if (!_shardedV3Ready || realCategoryCount == 0) {
        final legacyRecord = await _tryGetStiQRcloudRecord(
          legacyVaultCollection,
          'vault_${_currentUserPubAddress!.substring(0, 24)}',
        );
        if (legacyRecord != null) {
          try {
            final decryptedStr = await _decryptPayload(
              (legacyRecord['text'] ?? '').toString(),
              _masterDek!,
            );
            final vaultMap = jsonDecode(decryptedStr) as Map<String, dynamic>;
            final legacyRawCats = (vaultMap['categories'] as List<dynamic>?) ?? [];
            if (legacyRawCats.isNotEmpty) {
              await _importMonolithicVaultAndShard(
                vaultMap,
                mergeExistingTransactions: true,
              );
              _hasLoadedRemoteOnce = true;
              await _pushDirtyStateInternal();
              anyChanged = true;
              for (final c in _categories) {
                _emitCategoryEvent('create', c);
              }
              for (final t in _transactions) {
                _emitTransactionEvent('create', t);
              }
            }
          } catch (e) {
            print('Note checking legacy vault for recovery: $e');
          }
        }
      }

      _categories = _deduplicateUnallocatedCategories(_categories);
      _hasLoadedRemoteOnce = true;

      // Zero-action Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519) auto-upgrade:
      // 1. Ensure our ML-KEM-768 public key is published in stiqrbudget_pubkeys.
      // 2. Silently upgrade any owned legacy X25519-only grants whose collaborator
      //    has published an ML-KEM-768 public key.
      if (!_pubkeyDirectoryPublished) {
        unawaited(_registerPublicIdentityDirectory().catchError((_) {}));
      }
      unawaited(_upgradeLegacyOwnedGrantsToHybrid().catchError((_) {}));

      await _syncBudgetsListToPrefs(notifyListeners: false);
      await _saveStateToLocalCache();
      if (notifyChanges || anyChanged) {
        _notifyMetadataListeners();
      }
      return anyChanged;
    } catch (e) {
      print('Error pulling sharded data from StiQRcloud: $e');
      return false;
    }
  }

  Future<bool> _applyUserIndexRecord(
    sc.RecordModel uindexRecord, {
    required bool notifyChanges,
  }) async {
    try {
      final decryptedStr = await _decryptPayload(
        (uindexRecord['text'] ?? '').toString(),
        _masterDek!,
      );
      final map = jsonDecode(decryptedStr) as Map<String, dynamic>;
      final schemaVer = (map['shardedSchemaVersion'] as num?)?.toInt() ?? 0;
      if (schemaVer >= 3) {
        _shardedV3Ready = true;
      }
      final remoteUpdatedAt = (map['updatedAt'] as num?)?.toInt() ?? 0;
      if (_hasLoadedRemoteOnce && remoteUpdatedAt <= _userIndexUpdatedAt) {
        return false;
      }
      _userIndexUpdatedAt = remoteUpdatedAt;

      final prefs = await SharedPreferences.getInstance();
      bool metadataChanged = false;

      if (map['ownedBudgets'] is List) {
        final ownedList = map['ownedBudgets'] as List<dynamic>;
        for (final item in ownedList) {
          final bMap = Map<String, dynamic>.from(item as Map);
          final bId = (bMap['id'] ?? 'budget_1').toString();
          final bName = (bMap['name'] ?? 'My Budget').toString();
          final sharedKey = (bMap['sharedBudgetKey'] ??
                  _computeSharedBudgetKey(_currentUserPubAddress!, bId))
              .toString();
          final dekB64 = (bMap['budgetDekB64'] ?? '').toString();
          final dek = dekB64.isNotEmpty
              ? Uint8List.fromList(base64Decode(dekB64))
              : _deriveOwnedBudgetDek(sharedKey);

          final existing = _budgetsByLocalId[bId];
          _budgetsByLocalId[bId] = BudgetDescriptor(
            localBudgetId: bId,
            name: bName,
            sharedBudgetKey: sharedKey,
            ownerPubAddress: _currentUserPubAddress!,
            budgetDek: dek,
            role: 'owner',
            collaborators: existing?.collaborators ?? const [],
          );
          _localIdBySharedKey[sharedKey] = bId;
        }
      }

      if (map['expectedMonthlyIncome'] is num) {
        final income = (map['expectedMonthlyIncome'] as num).toDouble();
        if (prefs.getDouble('expected_monthly_income') != income) {
          await prefs.setDouble('expected_monthly_income', income);
          metadataChanged = true;
        }
      }

      if (map['paychecksPerMonth'] is num) {
        final paychecks = (map['paychecksPerMonth'] as num).toInt();
        if (prefs.getInt('paychecks_per_month') != paychecks) {
          await prefs.setInt('paychecks_per_month', paychecks);
          metadataChanged = true;
        }
      }

      if (map['inboxTransactions'] is List) {
        final rawInbox = map['inboxTransactions'] as List<dynamic>;
        final newInbox = rawInbox
            .map((e) => TransactionModel.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        final nonInbox = _transactions
            .where((tx) => !(tx.type != TransactionType.transfer && tx.category == null))
            .toList();
        _replaceTransactionsAndDiff(
          [...nonInbox, ...newInbox],
          notifyListeners: notifyChanges,
        );
      }

      if (notifyChanges && metadataChanged) {
        _notifyMetadataListeners();
      }
      return true;
    } catch (e) {
      print('Error applying user index record: $e');
      return false;
    }
  }

  Future<bool> _applyBudgetMetaRecord(
    BudgetDescriptor desc,
    sc.RecordModel bmetaRec, {
    required bool notifyChanges,
  }) async {
    try {
      final decryptedStr = await _decryptPayload(
        (bmetaRec['text'] ?? '').toString(),
        desc.budgetDek,
      );
      final metaMap = jsonDecode(decryptedStr) as Map<String, dynamic>;
      final remoteUpdatedAt = (metaMap['updatedAt'] as num?)?.toInt() ?? 0;
      final prevUpdatedAt = _budgetMetaUpdatedAt[desc.sharedBudgetKey] ?? 0;
      if (remoteUpdatedAt > 0 &&
          prevUpdatedAt > 0 &&
          remoteUpdatedAt < prevUpdatedAt) {
        return false;
      }

      // Parse collaborators & budget name
      final remoteName = (metaMap['budgetName'] ?? desc.name).toString();
      final rawCollabs = (metaMap['collaborators'] as List<dynamic>?) ?? [];
      final collabs = rawCollabs
          .map((e) => BudgetCollaborator.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();

      final updatedDesc = desc.copyWith(
        name: remoteName,
        collaborators: collabs,
      );
      _budgetsByLocalId[desc.localBudgetId] = updatedDesc;

      // Parse categories for this budget
      final rawCats = (metaMap['categories'] as List<dynamic>?) ?? [];
      final incomingBudgetCats = rawCats.map((item) {
        final cMap = Map<String, dynamic>.from(item as Map);
        final parsed = Category.fromJson(cMap);
        return parsed.copyWith(budgetId: desc.localBudgetId);
      }).toList();

      final otherBudgetCats = _categories
          .where((c) => c.budgetId != desc.localBudgetId)
          .toList();
      final localBudgetCats = _categories
          .where((c) => c.budgetId == desc.localBudgetId)
          .toList();
      final mergedBudgetCats = _dirtyBudgetMetaKeys.contains(desc.sharedBudgetKey)
          ? mergeCategories(incomingBudgetCats, localBudgetCats, _deletedCatIds)
          : incomingBudgetCats
              .where((c) => !_deletedCatIds.contains(c.id))
              .toList();
      _replaceCategoriesAndDiff(
        [...otherBudgetCats, ...mergedBudgetCats],
        notifyListeners: notifyChanges,
      );

      // Parse rules for this budget
      final rawRules = (metaMap['rules'] as List<dynamic>?) ?? [];
      final incomingRules = rawRules
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      final thisBudgetCatIds = incomingBudgetCats.map((c) => c.id).toSet();
      final otherRules = _rules
          .where((r) => !thisBudgetCatIds.contains(r['category']))
          .toList();
      _rules = [...otherRules, ...incomingRules];

      // Category order & per-budget income settings
      final prefs = await SharedPreferences.getInstance();
      if (metaMap['categoryOrder'] is List) {
        final orderList = (metaMap['categoryOrder'] as List)
            .map((e) => e.toString())
            .toList();
        await prefs.setStringList(
          'category_order_${desc.localBudgetId}',
          orderList,
        );
      }
      if (metaMap['expectedMonthlyIncome'] is num) {
        final income = (metaMap['expectedMonthlyIncome'] as num).toDouble();
        final key = 'expected_monthly_income_${desc.localBudgetId}';
        if (prefs.getDouble(key) != income) {
          await prefs.setDouble(key, income);
        }
      }
      if (metaMap['paychecksPerMonth'] is num) {
        final paychecks = (metaMap['paychecksPerMonth'] as num).toInt();
        final key = 'paychecks_per_month_${desc.localBudgetId}';
        if (prefs.getInt(key) != paychecks) {
          await prefs.setInt(key, paychecks);
        }
      }

      // Check monthly transaction shard revisions and ONLY fetch months that changed!
      final localRevs = _loadedShardRevisions.putIfAbsent(
        desc.sharedBudgetKey,
        () => <String, int>{},
      );
      final List<TransactionModel> updatedBudgetTxs = [];
      final existingBudgetTxs = _transactionsForBudget(desc.localBudgetId);
      bool anyShardFetched = false;

      if (metaMap['shardRevisions'] is Map) {
        final remoteRevs = Map<String, dynamic>.from(metaMap['shardRevisions'] as Map);
        for (final entry in remoteRevs.entries) {
          final month = entry.key;
          final remoteRev = (entry.value as num?)?.toInt() ?? 0;
          final localRev = localRevs[month] ?? 0;

          if (remoteRev > localRev || !_hasLoadedRemoteOnce) {
            final shardRec = await _tryGetStiQRcloudRecord(
              txShardsCollection,
              'btx_${desc.sharedBudgetKey}_$month',
            );
            if (shardRec != null) {
              final shardDecStr = await _decryptPayload(
                (shardRec['text'] ?? '').toString(),
                desc.budgetDek,
              );
              final shardMap = jsonDecode(shardDecStr) as Map<String, dynamic>;
              final rawShardTxs = (shardMap['transactions'] as List<dynamic>?) ?? [];
              final monthTxs = rawShardTxs
                  .map((e) => TransactionModel.fromJson(Map<String, dynamic>.from(e as Map)))
                  .toList();
              final isMonthDirty =
                  _dirtyMonthsBySharedKey[desc.sharedBudgetKey]?.contains(month) ??
                      false;
              if (isMonthDirty) {
                final localMonthTxs = existingBudgetTxs
                    .where((t) => _monthKeyForDate(t.date) == month)
                    .toList();
                updatedBudgetTxs.addAll(
                  mergeTransactions(monthTxs, localMonthTxs, _deletedTxIds),
                );
                _notifyIfDuplicates(monthTxs, localMonthTxs);
              } else {
                updatedBudgetTxs.addAll(
                  monthTxs.where((t) => !_deletedTxIds.contains(t.id)),
                );
              }
              localRevs[month] = remoteRev;
              anyShardFetched = true;
            } else {
              updatedBudgetTxs.addAll(
                existingBudgetTxs.where((t) => _monthKeyForDate(t.date) == month),
              );
            }
          } else {
            updatedBudgetTxs.addAll(
              existingBudgetTxs.where((t) => _monthKeyForDate(t.date) == month),
            );
          }
        }
      }

      if (anyShardFetched) {
        final otherTxs = _transactions.where((tx) {
          if (tx.type == TransactionType.transfer) {
            return !thisBudgetCatIds.contains(tx.sourceCategory) &&
                !thisBudgetCatIds.contains(tx.destinationCategory);
          }
          if (tx.category != null) {
            return !thisBudgetCatIds.contains(tx.category);
          }
          return true; // Keep inbox transactions
        }).toList();

        _replaceTransactionsAndDiff(
          [...otherTxs, ...updatedBudgetTxs],
          notifyListeners: notifyChanges,
        );
      }

      if (remoteUpdatedAt > prevUpdatedAt) {
        _budgetMetaUpdatedAt[desc.sharedBudgetKey] = remoteUpdatedAt;
      }
      if (notifyChanges && remoteUpdatedAt > prevUpdatedAt) {
        _notifyMetadataListeners();
      }
      return remoteUpdatedAt > prevUpdatedAt || anyShardFetched;
    } catch (e) {
      print('Error applying budget meta record (${desc.sharedBudgetKey}): $e');
      return false;
    }
  }

  void _replaceCategoriesAndDiff(
    List<Category> newCategories, {
    required bool notifyListeners,
  }) {
    final oldMap = {for (final c in _categories) c.id: c};
    final newMap = {for (final c in newCategories) c.id: c};
    _categories = newCategories;

    if (!notifyListeners) return;

    for (final cat in newCategories) {
      final prev = oldMap[cat.id];
      if (prev == null) {
        _emitCategoryEvent('create', cat);
      } else if (jsonEncode(prev.toJson()) != jsonEncode(cat.toJson())) {
        _emitCategoryEvent('update', cat);
      }
    }
    for (final oldCat in oldMap.values) {
      if (!newMap.containsKey(oldCat.id)) {
        _emitCategoryEvent('delete', oldCat);
      }
    }
  }

  void _replaceTransactionsAndDiff(
    List<TransactionModel> newTransactions, {
    required bool notifyListeners,
  }) {
    final dedupedMap = <String, TransactionModel>{};
    for (final tx in newTransactions) {
      dedupedMap[tx.id] = tx;
    }
    final sortedNew = dedupedMap.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final oldMap = {for (final t in _transactions) t.id: t};
    _transactions = sortedNew;

    if (!notifyListeners) return;

    for (final tx in sortedNew) {
      final prev = oldMap[tx.id];
      if (prev == null) {
        _emitTransactionEvent('create', tx);
      } else if (jsonEncode(prev.toJson()) != jsonEncode(tx.toJson())) {
        _emitTransactionEvent('update', tx);
      }
    }
    for (final oldTx in oldMap.values) {
      if (!dedupedMap.containsKey(oldTx.id)) {
        _emitTransactionEvent('delete', oldTx);
      }
    }
  }

  // --- Collaborator Grant Encryption (Hybrid ML-KEM-768 + X25519 + AES-256-GCM) ---

  Future<Uint8List?> _lookupCollaboratorMlkem768PubKey(
    String collabPubAddress,
  ) async {
    if (collabPubAddress.length < 24) return null;
    try {
      final pkRec = await _tryGetStiQRcloudRecord(
        pubkeysCollection,
        'pk_${collabPubAddress.substring(0, 24)}',
      );
      if (pkRec == null) return null;
      final map =
          jsonDecode((pkRec['text'] ?? '{}').toString()) as Map<String, dynamic>;
      return PqeCrypto.tryDecodeMlkem768PublicKey(
        map['mlkem768PubKey']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Zero-action background upgrade: for every owned shared budget grant still
  /// using legacy X25519-only wrapping, check if the collaborator has published
  /// an ML-KEM-768 public key and silently re-wrap the grant to
  /// `hybrid-mlkem768-x25519`.
  Future<void> _upgradeLegacyOwnedGrantsToHybrid() async {
    if (!isAuthenticated ||
        _x25519KeyPair == null ||
        _currentUserPubAddress == null ||
        _currentUserX25519PubHex == null) {
      return;
    }

    try {
      for (final desc in List<BudgetDescriptor>.from(_budgetsByLocalId.values)) {
        if (!desc.isOwner || desc.collaborators.isEmpty) continue;

        for (final collab in desc.collaborators) {
          final grantIdHash = sc.StiQRcloudCrypto.sha256Hex(
            utf8.encode('grant:${desc.sharedBudgetKey}:${collab.pubAddress}'),
          ).substring(0, 24);
          final grantRecordId = 'grant_$grantIdHash';

          if (_upgradedHybridGrantIds.contains(grantRecordId)) continue;

          final existingRec = await _tryGetStiQRcloudRecord(
            grantsCollection,
            grantRecordId,
          );
          if (existingRec == null) continue;

          Map<String, dynamic> existingOuter;
          try {
            existingOuter = jsonDecode((existingRec['text'] ?? '{}').toString())
                as Map<String, dynamic>;
          } catch (_) {
            continue;
          }

          if (PqeCrypto.isHybridGrant(existingOuter)) {
            _upgradedHybridGrantIds.add(grantRecordId);
            continue;
          }

          final upgradedOuter =
              await PqeCrypto.upgradeLegacyGrantRecordIfEligible(
            existingGrantOuter: existingOuter,
            ownerPubAddress: _currentUserPubAddress!,
            ownerX25519KeyPair: _x25519KeyPair!,
            ownerX25519PubHex: _currentUserX25519PubHex!,
            collaboratorX25519PubHex: collab.x25519Pub,
            budgetName: desc.name,
            budgetDek: desc.budgetDek,
            lookupCollaboratorMlkem768PubKey: _lookupCollaboratorMlkem768PubKey,
          );

          if (upgradedOuter != null) {
            await _upsertStiQRcloudRecord(
              grantsCollection,
              grantRecordId,
              jsonEncode(upgradedOuter),
            );
            _upgradedHybridGrantIds.add(grantRecordId);
          }
        }
      }
    } catch (e) {
      print('Note auto-upgrading legacy collaborator grants to PQE hybrid: $e');
    }
  }

  // Parse a scanned QR code or pasted collaborator key string:
  // Supports:
  // - "stiqrbudget:user:<pubAddress>:<x25519PubHex>"
  // - Raw 64-char hex pubAddress (looks up x25519PubHex & mlkem768PubKey in stiqrbudget_pubkeys)
  Future<Map<String, String>> resolveCollaboratorIdentity(String rawInput) async {
    final trimmed = rawInput.trim();
    String pubAddress = '';
    String x25519Pub = '';
    String mlkem768PubKey = '';

    if (trimmed.startsWith('stiqrbudget:user:')) {
      final parts = trimmed.substring('stiqrbudget:user:'.length).split(':');
      if (parts.isNotEmpty) pubAddress = parts[0].trim().toLowerCase();
      if (parts.length >= 2) x25519Pub = parts[1].trim().toLowerCase();
    } else if (trimmed.startsWith('stiqrnotes:user:')) {
      pubAddress = trimmed.substring('stiqrnotes:user:'.length).trim().toLowerCase();
    } else {
      pubAddress = trimmed.toLowerCase();
    }

    final hexRegex = RegExp(r'^[0-9a-f]{64}$');
    if (!hexRegex.hasMatch(pubAddress)) {
      throw Exception('Invalid collaborator QR code or public key.');
    }

    if (pubAddress == _currentUserPubAddress) {
      throw Exception('You cannot add your own account as a collaborator.');
    }

    // Look up public key directory to retrieve mlkem768PubKey (and x25519Pub if missing)
    final pkRec = await _tryGetStiQRcloudRecord(
      pubkeysCollection,
      'pk_${pubAddress.substring(0, 24)}',
    );
    if (pkRec != null) {
      try {
        final map = jsonDecode((pkRec['text'] ?? '{}').toString()) as Map<String, dynamic>;
        if (!hexRegex.hasMatch(x25519Pub)) {
          x25519Pub = (map['x25519Pub'] ?? '').toString().toLowerCase();
        }
        mlkem768PubKey = (map['mlkem768PubKey'] ?? '').toString().trim();
      } catch (_) {}
    }

    if (!hexRegex.hasMatch(x25519Pub)) {
      throw Exception(
        'Could not resolve encryption key for this user. Please scan their StiqrBudget QR code from Settings.',
      );
    }

    return {
      'pubAddress': pubAddress,
      'x25519Pub': x25519Pub,
      'mlkem768PubKey': mlkem768PubKey,
    };
  }

  // Add or update a collaborator for a specific budget (e.g. the currently active budget)
  Future<BudgetCollaborator> addCollaboratorToBudget({
    required String localBudgetId,
    required String qrOrPubKeyInput,
    required String role, // 'edit' | 'view'
    String label = '',
  }) async {
    await _ensureDefaultBudgetDescriptor();
    final desc = _budgetsByLocalId[localBudgetId];
    if (desc == null) {
      throw Exception('Budget not found.');
    }
    if (!desc.isOwner) {
      throw Exception('Only the budget owner can manage collaborators.');
    }

    final resolved = await resolveCollaboratorIdentity(qrOrPubKeyInput);
    final collabPub = resolved['pubAddress']!;
    final collabX25519 = resolved['x25519Pub']!;
    final collabMlkemPub = PqeCrypto.tryDecodeMlkem768PublicKey(
      resolved['mlkem768PubKey'],
    );
    final cleanRole = role == 'view' ? 'view' : 'edit';
    final cleanLabel = label.trim().isNotEmpty
        ? label.trim()
        : '${collabPub.substring(0, 6)}...${collabPub.substring(collabPub.length - 4)}';

    final newCollab = BudgetCollaborator(
      pubAddress: collabPub,
      x25519Pub: collabX25519,
      label: cleanLabel,
      role: cleanRole,
      addedAt: DateTime.now().toUtc().toIso8601String(),
    );

    final updatedCollabs = [
      ...desc.collaborators.where((c) => c.pubAddress != collabPub),
      newCollab,
    ];
    _budgetsByLocalId[localBudgetId] = desc.copyWith(collaborators: updatedCollabs);

    // 1. Wrap the budget's 256-bit DEK using Hybrid ML-KEM-768 + X25519 + AES-256-GCM
    //    if the collaborator has published mlkem768PubKey, else fall back to legacy X25519.
    final grantOuterMap = await PqeCrypto.buildGrantOuterRecord(
      ownerPubAddress: _currentUserPubAddress!,
      ownerX25519KeyPair: _x25519KeyPair!,
      ownerX25519PubHex: _currentUserX25519PubHex!,
      collaboratorPubAddress: collabPub,
      collaboratorX25519PubHex: collabX25519,
      sharedBudgetKey: desc.sharedBudgetKey,
      budgetName: desc.name,
      budgetDek: desc.budgetDek,
      role: cleanRole,
      collaboratorMlkem768PubKey: collabMlkemPub,
    );

    final grantIdHash = sc.StiQRcloudCrypto.sha256Hex(
      utf8.encode('grant:${desc.sharedBudgetKey}:$collabPub'),
    ).substring(0, 24);
    final grantRecordId = 'grant_$grantIdHash';

    await _upsertStiQRcloudRecord(
      grantsCollection,
      grantRecordId,
      jsonEncode(grantOuterMap),
    );
    if (PqeCrypto.isHybridGrant(grantOuterMap)) {
      _upgradedHybridGrantIds.add(grantRecordId);
    }

    // 2. Mark budget meta and all of its monthly shards dirty so their ACL "editors" list updates on StiQRcloud
    _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
    final budgetTxs = _transactionsForBudget(localBudgetId);
    final months = _dirtyMonthsBySharedKey.putIfAbsent(
      desc.sharedBudgetKey,
      () => <String>{},
    );
    for (final tx in budgetTxs) {
      months.add(_monthKeyForDate(tx.date));
    }

    await syncVaultToCloud();
    _notifyMetadataListeners();
    return newCollab;
  }

  // Update a collaborator's role ('edit' vs 'view')
  Future<void> updateCollaboratorRole({
    required String localBudgetId,
    required String collaboratorPubAddress,
    required String newRole,
  }) async {
    final desc = _budgetsByLocalId[localBudgetId];
    if (desc == null || !desc.isOwner) return;
    final existing = desc.collaborators
        .where((c) => c.pubAddress == collaboratorPubAddress)
        .toList();
    if (existing.isEmpty) return;

    final target = existing.first;
    await addCollaboratorToBudget(
      localBudgetId: localBudgetId,
      qrOrPubKeyInput: 'stiqrbudget:user:${target.pubAddress}:${target.x25519Pub}',
      role: newRole,
      label: target.label,
    );
  }

  // Remove a collaborator from a budget
  Future<void> removeCollaboratorFromBudget({
    required String localBudgetId,
    required String collaboratorPubAddress,
  }) async {
    final desc = _budgetsByLocalId[localBudgetId];
    if (desc == null || !desc.isOwner) return;

    final updatedCollabs = desc.collaborators
        .where((c) => c.pubAddress != collaboratorPubAddress)
        .toList();
    _budgetsByLocalId[localBudgetId] = desc.copyWith(collaborators: updatedCollabs);

    final grantIdHash = sc.StiQRcloudCrypto.sha256Hex(
      utf8.encode('grant:${desc.sharedBudgetKey}:$collaboratorPubAddress'),
    ).substring(0, 24);
    final grantRecordId = 'grant_$grantIdHash';

    // Mark grant as revoked so collaborator's client immediately drops access
    final revokedJson = jsonEncode({
      'ownerPublicKey': _currentUserPubAddress,
      'collaboratorPubKey': collaboratorPubAddress,
      'sharedBudgetKey': desc.sharedBudgetKey,
      'revoked': true,
    });
    await _upsertStiQRcloudRecord(
      grantsCollection,
      grantRecordId,
      revokedJson,
    );

    // Re-upload budget meta & shards with updated "editors" ACL
    _addDirtyBudgetMetaKey(desc.sharedBudgetKey);
    final budgetTxs = _transactionsForBudget(localBudgetId);
    final months = _dirtyMonthsBySharedKey.putIfAbsent(
      desc.sharedBudgetKey,
      () => <String>{},
    );
    for (final tx in budgetTxs) {
      months.add(_monthKeyForDate(tx.date));
    }

    await syncVaultToCloud();
    _notifyMetadataListeners();
  }

  // Discover budgets shared with the current user from stiqrbudget_grants
  Future<bool> _discoverSharedBudgetsFromGrants() async {
    if (!isAuthenticated || _x25519KeyPair == null) return false;
    try {
      final listRes = await _withStiQRcloud(
        (client) => client.collection(grantsCollection).getList(perPage: 200),
      );

      bool changed = false;
      final activeSharedKeys = <String>{};

      for (final item in listRes.items) {
        final rawText = (item['text'] ?? '').toString();
        if (rawText.isEmpty) continue;
        Map<String, dynamic> outer;
        try {
          outer = jsonDecode(rawText) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final collabPub = (outer['collaboratorPubKey'] ?? '').toString();
        if (collabPub != _currentUserPubAddress) continue;

        final sharedKey = (outer['sharedBudgetKey'] ?? '').toString();
        final isRevoked = outer['revoked'] == true;
        if (isRevoked || sharedKey.isEmpty) {
          continue;
        }

        final ownerX25519Pub = (outer['ownerX25519Pub'] ?? '').toString();
        final wrappedKey = (outer['wrappedKey'] ?? '').toString();
        if (ownerX25519Pub.isEmpty || wrappedKey.isEmpty) continue;

        try {
          final decryptedGrantStr = await PqeCrypto.unwrapGrantOuter(
            grantOuter: outer,
            myX25519KeyPair: _x25519KeyPair!,
            myMlkem768KeyPair: _mlkem768KeyPair,
          );
          final grantMap = jsonDecode(decryptedGrantStr) as Map<String, dynamic>;

          final budgetName = (grantMap['budgetName'] ?? 'Shared Budget').toString();
          final ownerPub = (grantMap['ownerPubAddress'] ?? '').toString();
          final budgetDekB64 = (grantMap['budgetDekB64'] ?? '').toString();
          final role = ( outer['role'] ?? grantMap['role'] ?? 'edit').toString() == 'view'
              ? 'view'
              : 'edit';

          if (budgetDekB64.isEmpty || ownerPub.isEmpty) continue;
          final budgetDek = Uint8List.fromList(base64Decode(budgetDekB64));
          final localBudgetId = 'budget_shared_$sharedKey';

          activeSharedKeys.add(sharedKey);
          final existing = _budgetsByLocalId[localBudgetId];
          if (existing == null || existing.role != role || existing.name != budgetName) {
            _budgetsByLocalId[localBudgetId] = BudgetDescriptor(
              localBudgetId: localBudgetId,
              name: budgetName,
              sharedBudgetKey: sharedKey,
              ownerPubAddress: ownerPub,
              budgetDek: budgetDek,
              role: role,
              collaborators: existing?.collaborators ?? const [],
            );
            _localIdBySharedKey[sharedKey] = localBudgetId;
            changed = true;
          }
        } catch (e) {
          print('Failed to unwrap shared budget grant $sharedKey: $e');
        }
      }

      // Remove any previously shared budgets that were revoked
      final revokedLocalIds = _budgetsByLocalId.values
          .where((d) => d.isShared && !activeSharedKeys.contains(d.sharedBudgetKey))
          .map((d) => d.localBudgetId)
          .toList();

      for (final revId in revokedLocalIds) {
        final removed = _budgetsByLocalId.remove(revId);
        if (removed != null) {
          _localIdBySharedKey.remove(removed.sharedBudgetKey);
          _categories = _categories.where((c) => c.budgetId != revId).toList();
          changed = true;
        }
      }

      return changed;
    } catch (e) {
      print('Note checking shared budget grants: $e');
      return false;
    }
  }

  // --- Real-Time Server-Sent Events (SSE) Engine ---

  void _connectSse() {
    if (!isAuthenticated) return;
    _sseReconnectTimer?.cancel();

    final primaryNode = stiqrCloudNodes.first;
    final uri = Uri.parse('$primaryNode/api/realtime');

    try {
      _sseSubscription?.cancel();
      _sseConnection?.close();
      _sseConnection = getPlatformSseConnection();

      for (final topic in _sseTopics) {
        _sseConnection!.subscribeTopic(topic);
      }

      final stream = _sseConnection!.connect(uri);
      _sseSubscription = stream.listen(
        _onSseMessage,
        onError: (_) => _scheduleSseReconnect(),
        onDone: _scheduleSseReconnect,
        cancelOnError: false,
      );
    } catch (_) {
      _scheduleSseReconnect();
    }
  }

  void _scheduleSseReconnect() {
    _sseConnected = false;
    _sseClientId = null;
    if (!isAuthenticated) return;
    if (_sseReconnectTimer != null && _sseReconnectTimer!.isActive) return;

    final delaySec = (_sseReconnectAttempts < 4) ? (1 << _sseReconnectAttempts) : 10;
    _sseReconnectAttempts++;
    _sseReconnectTimer = Timer(Duration(seconds: delaySec), _connectSse);
  }

  void _disconnectSse() {
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = null;
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _sseConnection?.close();
    _sseConnection = null;
    _sseConnected = false;
    _sseClientId = null;
  }

  Future<void> _submitSseSubscriptions() async {
    final cId = _sseClientId;
    if (cId == null || cId.isEmpty || !isAuthenticated) return;

    final primaryNode = stiqrCloudNodes.first;
    final uri = Uri.parse('$primaryNode/api/realtime');
    try {
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'clientId': cId,
              'subscriptions': _sseTopics,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> _onSseMessage(SseRawMessage msg) async {
    if (!isAuthenticated) return;

    if (msg.event == 'PB_CONNECT') {
      try {
        final data = jsonDecode(msg.data) as Map<String, dynamic>;
        _sseClientId = data['clientId']?.toString();
        _sseConnected = true;
        _sseReconnectAttempts = 0;
        await _submitSseSubscriptions();
      } catch (_) {}
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_pushDepth > 0 || (nowMs - _lastPushFinishedMs) < 1500) return;

    try {
      final eventPayload = jsonDecode(msg.data) as Map<String, dynamic>;
      final recordMap = eventPayload['record'] as Map<String, dynamic>?;
      if (recordMap == null) return;

      final recModel = sc.RecordModel.fromJson(recordMap);
      final recId = recModel.id;
      final col = recModel.collection;

      if (col == userIndexCollection && recId == _userIndexRecordId) {
        final changed = await _applyUserIndexRecord(recModel, notifyChanges: true);
        if (changed) {
          await _syncBudgetsListToPrefs(notifyListeners: true);
          await _saveStateToLocalCache();
          _notifyMetadataListeners();
        }
      } else if (col == budgetMetaCollection && recId.startsWith('bmeta_')) {
        final sharedKey = recId.substring('bmeta_'.length);
        final localBudgetId = _localIdBySharedKey[sharedKey];
        if (localBudgetId != null) {
          final desc = _budgetsByLocalId[localBudgetId];
          if (desc != null) {
            final changed = await _applyBudgetMetaRecord(
              desc,
              recModel,
              notifyChanges: true,
            );
            if (changed) {
              await _syncBudgetsListToPrefs(notifyListeners: true);
              await _saveStateToLocalCache();
              _notifyMetadataListeners();
            }
          }
        }
      } else if (col == grantsCollection) {
        final rawText = (recModel['text'] ?? '').toString();
        if (rawText.contains(_currentUserPubAddress!)) {
          final changed = await _discoverSharedBudgetsFromGrants();
          if (changed) {
            await _pullAllFromCloud(notifyChanges: true);
          }
        }
      }
    } catch (_) {}
  }

  // --- Local Cache & SharedPreferences Sync ---

  Future<void> _syncBudgetsListToPrefs({required bool notifyListeners}) async {
    final prefs = await SharedPreferences.getInstance();
    final budgetsJsonList = _budgetsByLocalId.values
        .map((d) => {
              'id': d.localBudgetId,
              'name': d.isShared
                  ? (d.isReadOnly ? '${d.name} (View-Only)' : '${d.name} (Shared)')
                  : d.name,
            })
        .toList();
    if (budgetsJsonList.isEmpty) {
      budgetsJsonList.add({'id': 'budget_1', 'name': 'My Budget'});
    }
    final encoded = jsonEncode(budgetsJsonList);
    if (prefs.getString(_budgetsPrefKey) != encoded) {
      await prefs.setString(_budgetsPrefKey, encoded);
      if (notifyListeners) {
        _notifyMetadataListeners();
      }
    }
  }

  Future<void> registerOrRenameLocalBudget(String localBudgetId, String name) async {
    if (!isAuthenticated) return;
    final existing = _budgetsByLocalId[localBudgetId];
    if (existing != null) {
      final cleanName = name
          .replaceAll(' (Shared)', '')
          .replaceAll(' (View-Only)', '')
          .trim();
      _budgetsByLocalId[localBudgetId] = existing.copyWith(name: cleanName);
    } else if (!localBudgetId.startsWith('budget_shared_')) {
      final sharedKey = _computeSharedBudgetKey(_currentUserPubAddress!, localBudgetId);
      final dek = _deriveOwnedBudgetDek(sharedKey);
      _budgetsByLocalId[localBudgetId] = BudgetDescriptor(
        localBudgetId: localBudgetId,
        name: name,
        sharedBudgetKey: sharedKey,
        ownerPubAddress: _currentUserPubAddress!,
        budgetDek: dek,
        role: 'owner',
      );
      _localIdBySharedKey[sharedKey] = localBudgetId;
    }
    _userIndexDirty = true;
    _markBudgetMetaDirty(localBudgetId);
    unawaited(syncVaultToCloud().catchError((_) {}));
  }

  Future<void> _discoverBudgetsFromCategories(List<Category> categories) async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> budgets = [
      {'id': 'budget_1', 'name': 'My Budget'}
    ];
    final savedStr = prefs.getString(_budgetsPrefKey);
    if (savedStr != null && savedStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedStr) as List<dynamic>;
        budgets = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }

    final existingIds = budgets.map((b) => b['id'] as String).toSet();
    bool changed = false;
    for (final cat in categories) {
      if (!existingIds.contains(cat.budgetId)) {
        budgets.add({
          'id': cat.budgetId,
          'name': cat.budgetId == 'budget_1' ? 'My Budget' : 'Linked Budget',
        });
        existingIds.add(cat.budgetId);
        changed = true;
      }
    }

    if (changed || savedStr == null) {
      await prefs.setString(_budgetsPrefKey, jsonEncode(budgets));
    }
  }

  Future<void> deleteBudget(String localBudgetId) async {
    final removed = _budgetsByLocalId.remove(localBudgetId);
    if (removed != null) {
      _localIdBySharedKey.remove(removed.sharedBudgetKey);
    }

    final removedCatIds = _categories
        .where((c) => c.budgetId == localBudgetId)
        .map((c) => c.id)
        .toSet();
    _categories.removeWhere((c) => c.budgetId == localBudgetId);
    _transactions.removeWhere((t) =>
        (t.sourceCategory != null && removedCatIds.contains(t.sourceCategory)) ||
        (t.destinationCategory != null && removedCatIds.contains(t.destinationCategory)));

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('category_order_$localBudgetId');

    _userIndexDirty = true;
    await _syncBudgetsListToPrefs(notifyListeners: true);
    if (isAuthenticated) {
      unawaited(syncVaultToCloud().catchError((_) {}));
    }
  }

  Future<void> _saveStateToLocalCache() async {
    if (!isAuthenticated) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachePayload = jsonEncode({
        'v': 2,
        'categories': _categories.map((c) => c.toJson()).toList(),
        'transactions': _transactions.map((t) => t.toJson()).toList(),
        'rules': _rules,
        'shardRevisions': _loadedShardRevisions,
        'deletedTxIds': _deletedTxIds.toList(),
        'resolvedDuplicatePairs': _resolvedDuplicatePairs.toList(),
      });
      await prefs.setString(
        '$_localCachePrefix$_currentUserPubAddress',
        cachePayload,
      );
    } catch (_) {}
  }

  Future<bool> _loadStateFromLocalCache() async {
    if (!isAuthenticated) return false;
    _localCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      String? cachedStr = prefs.getString('$_localCachePrefix$_currentUserPubAddress');
      if (cachedStr == null || cachedStr.isEmpty) {
        cachedStr = prefs.getString('stiqrbudget_vault_cache_$_currentUserPubAddress');
      }
      if (cachedStr == null || cachedStr.isEmpty) return false;

      final map = jsonDecode(cachedStr) as Map<String, dynamic>;
      if (map['deletedTxIds'] is List) {
        _deletedTxIds.addAll(
          (map['deletedTxIds'] as List<dynamic>).map((e) => e.toString()),
        );
      }
      if (map['resolvedDuplicatePairs'] is List) {
        _resolvedDuplicatePairs.addAll(
          (map['resolvedDuplicatePairs'] as List<dynamic>)
              .map((e) => e.toString()),
        );
      }
      final rawCats = (map['categories'] as List<dynamic>?) ?? [];
      final cachedCats = _deduplicateUnallocatedCategories(
        rawCats
            .map((item) => Category.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
      );
      if (_categories.isEmpty && _dirtyBudgetMetaKeys.isEmpty) {
        _categories = cachedCats;
      } else if (cachedCats.isNotEmpty) {
        _categories = _deduplicateUnallocatedCategories(
          mergeCategories(cachedCats, _categories, _deletedCatIds),
        );
      }

      final rawTxs = (map['transactions'] as List<dynamic>?) ?? [];
      final cachedTxs = rawTxs
          .map((item) => TransactionModel.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      if (_transactions.isEmpty && _dirtyMonthsBySharedKey.isEmpty) {
        _transactions = cachedTxs..sort((a, b) => b.date.compareTo(a.date));
      } else if (cachedTxs.isNotEmpty) {
        _transactions = mergeTransactions(cachedTxs, _transactions, _deletedTxIds)
          ..sort((a, b) => b.date.compareTo(a.date));
      }

      final rawRules = (map['rules'] as List<dynamic>?) ?? [];
      final cachedRules =
          rawRules.map((item) => Map<String, dynamic>.from(item as Map)).toList();
      if (_rules.isEmpty) {
        _rules = cachedRules;
      }

      if (map['shardRevisions'] is Map) {
        final rawRevs = map['shardRevisions'] as Map<String, dynamic>;
        for (final entry in rawRevs.entries) {
          if (entry.value is Map) {
            final monthMap = Map<String, dynamic>.from(entry.value as Map);
            final inner = _loadedShardRevisions.putIfAbsent(
              entry.key,
              () => <String, int>{},
            );
            for (final mEntry in monthMap.entries) {
              if (mEntry.value is num) {
                final cachedRev = (mEntry.value as num).toInt();
                if (cachedRev > (inner[mEntry.key] ?? 0)) {
                  inner[mEntry.key] = cachedRev;
                }
              }
            }
          }
        }
      }

      await _discoverBudgetsFromCategories(_categories);
      await _ensureDefaultBudgetDescriptor();
      if (_categories.isNotEmpty || _transactions.isNotEmpty) {
        _hasLoadedRemoteOnce = true;
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  String _generateRecordId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(15, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  String generateRecordId() => _generateRecordId();

  void _emitCategoryEvent(String action, Category category) {
    final json = category.toJson();
    json['id'] = category.id;
    json['user'] = currentUserId ?? '';
    final event = RecordSubscriptionEvent(
      action: action,
      record: RecordModel.fromJson(json),
    );
    for (final cb in List<void Function(RecordSubscriptionEvent)>.from(_categoryListeners)) {
      try {
        cb(event);
      } catch (_) {}
    }
  }

  void _emitTransactionEvent(String action, TransactionModel tx) {
    final json = tx.toJson();
    json['id'] = tx.id;
    json['user'] = currentUserId ?? '';
    final event = RecordSubscriptionEvent(
      action: action,
      record: RecordModel.fromJson(json),
    );
    for (final cb in List<void Function(RecordSubscriptionEvent)>.from(_transactionListeners)) {
      try {
        cb(event);
      } catch (_) {}
    }
  }

  Future<bool> pullFromCloud({bool notifyChanges = true}) async {
    return _pullAllFromCloud(notifyChanges: notifyChanges);
  }

  // --- Category Operations ---

  Future<List<Category>> fetchCategories() async {
    if (!isAuthenticated) return [];

    if (!_localCacheLoaded && _categories.isEmpty) {
      await _loadStateFromLocalCache();
    }

    if (!_hasLoadedRemoteOnce) {
      final pulled = await _pullAllFromCloud(notifyChanges: false);
      _hasLoadedRemoteOnce = true;
      if (!pulled && !_localCacheLoaded && _categories.isEmpty) {
        await _loadStateFromLocalCache();
      }
    } else {
      unawaited(_pullAllFromCloud(notifyChanges: true));
    }

    final sorted = List<Category>.from(_categories)
      ..sort((a, b) => a.name.compareTo(b.name));
    return sorted;
  }

  Future<Category> createCategory(
    Category category, {
    bool syncImmediately = true,
  }) async {
    await _ensureDefaultBudgetDescriptor();
    if (isBudgetReadOnly(category.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    // Never create a duplicate Unallocated category for a budget that already has one
    if (category.isUnallocated) {
      final existingUnallocated = _categories
          .where((c) => c.budgetId == category.budgetId && c.isUnallocated)
          .toList();
      if (existingUnallocated.isNotEmpty) {
        return existingUnallocated.first;
      }
    }

    final newId = category.id.isNotEmpty ? category.id : _generateRecordId();
    final safeBalanceCents = (category.balance * 100).round();
    final created = category.copyWith(
      id: newId,
      balance: safeBalanceCents < 0 ? 0.0 : safeBalanceCents / 100.0,
      user: currentUserId ?? '',
    );

    _categories = [
      ..._categories.where((c) => c.id != newId),
      created,
    ];

    _localCacheLoaded = true;
    _markBudgetMetaDirty(created.budgetId);
    _emitCategoryEvent('create', created);
    unawaited(_saveStateToLocalCache().catchError((_) {}));
    if (syncImmediately) {
      await syncVaultToCloud();
    }
    return created;
  }

  Future<Category> updateCategory(
    Category category, {
    bool syncImmediately = true,
  }) async {
    await _ensureDefaultBudgetDescriptor();
    if (isBudgetReadOnly(category.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    final safeBalanceCents = (category.balance * 100).round();
    final updated = category.copyWith(
      balance: safeBalanceCents < 0 ? 0.0 : safeBalanceCents / 100.0,
      user: currentUserId ?? category.user,
    );

    bool found = false;
    _categories = _categories.map((c) {
      if (c.id == updated.id) {
        found = true;
        return updated;
      }
      return c;
    }).toList();

    if (!found) {
      _categories = [..._categories, updated];
    }

    _localCacheLoaded = true;
    _markBudgetMetaDirty(updated.budgetId);
    _emitCategoryEvent('update', updated);
    unawaited(_saveStateToLocalCache().catchError((_) {}));
    if (syncImmediately) {
      await syncVaultToCloud();
    }
    return updated;
  }

  Future<void> deleteCategory(
    String id, {
    bool syncImmediately = true,
  }) async {
    Category? removed;
    for (final c in _categories) {
      if (c.id == id) {
        removed = c;
        break;
      }
    }
    if (removed != null && isBudgetReadOnly(removed.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    _deletedCatIds.add(id);
    _categories = _categories.where((c) => c.id != id).toList();
    _localCacheLoaded = true;
    if (removed != null) {
      _markBudgetMetaDirty(removed.budgetId);
      _emitCategoryEvent('delete', removed);
    }
    unawaited(_saveStateToLocalCache().catchError((_) {}));
    if (syncImmediately) {
      await syncVaultToCloud();
    }
  }

  Future<void> subscribeCategories(
    void Function(RecordSubscriptionEvent event) callback,
  ) async {
    if (!_categoryListeners.contains(callback)) {
      _categoryListeners.add(callback);
    }
  }

  Future<void> unsubscribeCategories() async {
    _categoryListeners.clear();
  }

  // --- Transaction Operations ---

  Future<List<TransactionModel>> fetchTransactions() async {
    if (!isAuthenticated) return [];

    if (!_localCacheLoaded && _transactions.isEmpty) {
      await _loadStateFromLocalCache();
    }

    if (!_hasLoadedRemoteOnce) {
      final pulled = await _pullAllFromCloud(notifyChanges: false);
      _hasLoadedRemoteOnce = true;
      if (!pulled && !_localCacheLoaded && _transactions.isEmpty) {
        await _loadStateFromLocalCache();
      }
    } else {
      unawaited(_pullAllFromCloud(notifyChanges: true));
    }

    final sorted = List<TransactionModel>.from(_transactions)
      ..sort((a, b) => b.date.compareTo(a.date));
    return sorted;
  }

  TransactionModel? getTransactionById(String id) {
    for (final tx in _transactions) {
      if (tx.id == id) return tx;
    }
    return null;
  }

  Future<TransactionModel> createTransaction(
    TransactionModel transaction, {
    bool syncImmediately = true,
  }) async {
    final targetBudgetId = _budgetIdForTransaction(transaction);
    if (targetBudgetId != '_inbox_' && isBudgetReadOnly(targetBudgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    final newId = transaction.id.isNotEmpty ? transaction.id : _generateRecordId();
    final created = transaction.copyWith(
      id: newId,
      user: currentUserId ?? '',
    );

    _sessionCreatedTxIds.add(newId);
    _unsyncedLocalTxIds.add(newId);
    _transactions = [
      created,
      ..._transactions.where((t) => t.id != newId),
    ]..sort((a, b) => b.date.compareTo(a.date));

    _markTransactionDirty(created);
    _emitTransactionEvent('create', created);
    if (syncImmediately) {
      await syncVaultToCloud();
    }
    return created;
  }

  Future<TransactionModel> updateTransaction(
    TransactionModel transaction, {
    bool clearCategory = false,
    bool syncImmediately = true,
  }) async {
    final prev = getTransactionById(transaction.id);
    if (prev != null) {
      _markTransactionDirty(prev);
    }

    final updated = TransactionModel(
      id: transaction.id,
      description: transaction.description,
      amount: transaction.amount,
      type: transaction.type,
      category: clearCategory ? null : transaction.category,
      sourceCategory: transaction.sourceCategory,
      destinationCategory: transaction.destinationCategory,
      date: transaction.date,
      user: currentUserId ?? transaction.user,
    );

    final targetBudgetId = _budgetIdForTransaction(updated);
    if (targetBudgetId != '_inbox_' && isBudgetReadOnly(targetBudgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    bool found = false;
    _transactions = _transactions.map((t) {
      if (t.id == updated.id) {
        found = true;
        return updated;
      }
      return t;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    if (!found) {
      _transactions = [updated, ..._transactions]
        ..sort((a, b) => b.date.compareTo(a.date));
    }

    _markTransactionDirty(updated);
    _emitTransactionEvent('update', updated);
    if (syncImmediately) {
      await syncVaultToCloud();
    }
    return updated;
  }

  Future<void> deleteTransaction(
    String id, {
    bool syncImmediately = true,
  }) async {
    TransactionModel? removed;
    for (final t in _transactions) {
      if (t.id == id) {
        removed = t;
        break;
      }
    }
    if (removed != null) {
      final bId = _budgetIdForTransaction(removed);
      if (bId != '_inbox_' && isBudgetReadOnly(bId)) {
        throw Exception('This shared budget is View-Only.');
      }
      _markTransactionDirty(removed);
    }

    _deletedTxIds.add(id);
    _unsyncedLocalTxIds.remove(id);
    _transactions = _transactions.where((t) => t.id != id).toList();
    if (removed != null) {
      _emitTransactionEvent('delete', removed);
    }
    if (syncImmediately) {
      await syncVaultToCloud();
    }
  }

  Future<void> subscribeTransactions(
    void Function(RecordSubscriptionEvent event) callback,
  ) async {
    if (!_transactionListeners.contains(callback)) {
      _transactionListeners.add(callback);
    }
  }

  Future<void> unsubscribeTransactions() async {
    _transactionListeners.clear();
  }

  // --- Auto-Categorization Rules Operations ---

  Future<String> createRule({
    required String pattern,
    required String categoryId,
    bool syncImmediately = true,
  }) async {
    final id = _generateRecordId();
    _rules = [
      ..._rules,
      {
        'id': id,
        'pattern': pattern.trim().toLowerCase(),
        'category': categoryId,
        'user': currentUserId ?? '',
      }
    ];
    final cat = _categories.where((c) => c.id == categoryId).toList();
    if (cat.isNotEmpty) {
      _markBudgetMetaDirty(cat.first.budgetId);
    }
    if (syncImmediately) {
      await syncVaultToCloud();
    }
    return id;
  }

  Future<void> deleteRule(
    String id, {
    bool syncImmediately = true,
  }) async {
    final existing = _rules.where((r) => r['id'] == id).toList();
    if (existing.isNotEmpty) {
      final catId = existing.first['category'];
      final cat = _categories.where((c) => c.id == catId).toList();
      if (cat.isNotEmpty) {
        _markBudgetMetaDirty(cat.first.budgetId);
      }
    }
    _rules = _rules.where((r) => r['id'] != id).toList();
    if (syncImmediately) {
      await syncVaultToCloud();
    }
  }

  // --- Transactional/Multi-Step Budget Actions ---

  Future<TransactionModel> logExpense(
    TransactionModel transaction,
    Category category, {
    bool syncImmediately = true,
  }) async {
    final currentCat = _categories.firstWhere(
      (c) => c.id == category.id,
      orElse: () => category,
    );
    if (isBudgetReadOnly(currentCat.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }
    final catCents = (currentCat.balance * 100).round();
    final deltaCents = (transaction.amount * 100).round();
    final newCents = catCents + deltaCents;
    if (newCents < 0) {
      throw Exception('Category has insufficient funds');
    }

    final created = await createTransaction(
      transaction,
      syncImmediately: false,
    );

    final updatedCategory = currentCat.copyWith(
      balance: newCents / 100.0,
    );
    await updateCategory(
      updatedCategory,
      syncImmediately: syncImmediately,
    );
    return created;
  }

  Future<TransactionModel> logTransfer(
    TransactionModel transaction,
    Category source,
    Category destination, {
    bool syncImmediately = true,
  }) async {
    final currentSource = _categories.firstWhere(
      (c) => c.id == source.id,
      orElse: () => source,
    );
    final currentDest = _categories.firstWhere(
      (c) => c.id == destination.id,
      orElse: () => destination,
    );
    if (isBudgetReadOnly(currentSource.budgetId) || isBudgetReadOnly(currentDest.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }
    final amountCents = (transaction.amount.abs() * 100).round();
    final sourceCents = (currentSource.balance * 100).round();
    final destCents = (currentDest.balance * 100).round();

    if (sourceCents < amountCents) {
      throw Exception('Source category has insufficient funds');
    }

    final created = await createTransaction(
      transaction,
      syncImmediately: false,
    );

    await updateCategory(
      currentSource.copyWith(balance: (sourceCents - amountCents) / 100.0),
      syncImmediately: false,
    );

    await updateCategory(
      currentDest.copyWith(balance: (destCents + amountCents) / 100.0),
      syncImmediately: syncImmediately,
    );

    return created;
  }

  Future<List<TransactionModel>> logIncomeAndDistribute(
    TransactionModel incomeTx,
    Category unallocatedCategory,
    List<Map<String, dynamic>> distributions, {
    bool syncImmediately = true,
  }) async {
    final freshUnalloc = _categories.firstWhere(
      (c) => c.id == unallocatedCategory.id,
      orElse: () => unallocatedCategory,
    );
    if (isBudgetReadOnly(freshUnalloc.budgetId)) {
      throw Exception('This shared budget is View-Only.');
    }

    // Pre-validate that total distributions never leave unallocated negative
    final startUnallocCents =
        (freshUnalloc.balance * 100).round() + (incomeTx.amount * 100).round();
    int totalDistCents = 0;
    for (final dist in distributions) {
      final targetCat = dist['category'] as Category;
      final amt = (dist['amount'] as num).toDouble();
      if (amt <= 0 || targetCat.isUnallocated) continue;
      totalDistCents += (amt * 100).round();
    }
    if (startUnallocCents < totalDistCents) {
      throw Exception('Distributions exceed available unallocated funds');
    }

    final List<TransactionModel> createdTransactions = [];

    final createdIncome = await createTransaction(
      incomeTx,
      syncImmediately: false,
    );
    createdTransactions.add(createdIncome);

    var currentUnallocatedCents = startUnallocCents;
    var currentUnallocated = freshUnalloc.copyWith(
      balance: currentUnallocatedCents / 100.0,
    );
    currentUnallocated = await updateCategory(
      currentUnallocated,
      syncImmediately: false,
    );

    for (final dist in distributions) {
      final rawTargetCat = dist['category'] as Category;
      final targetCat = _categories.firstWhere(
        (c) => c.id == rawTargetCat.id,
        orElse: () => rawTargetCat,
      );
      final amount = (dist['amount'] as num).toDouble();
      final amountCents = (amount * 100).round();
      if (amountCents <= 0) continue;
      if (targetCat.isUnallocated) continue;

      final transferTx = TransactionModel(
        id: (dist['id'] as String?) ?? '',
        description: 'Allocated from: ${incomeTx.description}',
        amount: amountCents / 100.0,
        type: TransactionType.transfer,
        sourceCategory: currentUnallocated.id,
        destinationCategory: targetCat.id,
        date: incomeTx.date,
        user: currentUserId ?? incomeTx.user,
      );

      final createdTransfer = await createTransaction(
        transferTx,
        syncImmediately: false,
      );
      createdTransactions.add(createdTransfer);

      final newTargetCents = (targetCat.balance * 100).round() + amountCents;
      await updateCategory(
        targetCat.copyWith(balance: newTargetCents / 100.0),
        syncImmediately: false,
      );

      currentUnallocatedCents -= amountCents;
      currentUnallocated = currentUnallocated.copyWith(
        balance: currentUnallocatedCents < 0 ? 0.0 : currentUnallocatedCents / 100.0,
      );
    }

    await updateCategory(
      currentUnallocated,
      syncImmediately: syncImmediately,
    );

    return createdTransactions;
  }

  // --- App Release & Version Operations (Served from StiQRhub) ---

  Future<List<AppRelease>> fetchReleases() async {
    final prefs = await SharedPreferences.getInstance();
    const cacheKey = 'cached_app_releases_stiqrhub';

    for (final hubUrl in stiqrHubNodes) {
      final isLanNode = !hubUrl.startsWith('https://');
      // Never hit plain-HTTP LAN IPs from an HTTPS web app (avoids Mixed Content & Private Network CORS errors)
      if (kIsWeb && isLanNode) {
        continue;
      }
      try {
        final uri = Uri.parse('$hubUrl/api/projects/stiqrbudget/releases');
        final response = await http.get(uri).timeout(
              isLanNode
                  ? const Duration(milliseconds: 1500)
                  : const Duration(seconds: 5),
            );
        if (response.statusCode == 200) {
          final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
          final apkItems = decoded.where((item) {
            final map = item as Map<String, dynamic>;
            final filename = (map['artifact_filename'] ?? '').toString().toLowerCase();
            final version = (map['version'] ?? '').toString().toLowerCase();
            if (filename.endsWith('.zip') || version.contains('-web')) {
              return false;
            }
            return true;
          }).toList();

          if (apkItems.isNotEmpty) {
            final releases = apkItems.asMap().entries.map((entry) {
              final map = Map<String, dynamic>.from(entry.value as Map);
              return AppRelease.fromStiQRhubJson(
                map,
                hubUrl,
                forceLatest: entry.key == 0,
              );
            }).toList();

            final jsonList = releases.map((r) => r.toJson()).toList();
            await prefs.setString(cacheKey, jsonEncode(jsonList));
            return releases;
          }
        }
      } catch (e) {
        print('Could not fetch app releases from StiQRhub ($hubUrl): $e');
      }
    }

    // Fallback: PocketBase app_releases (https://api.stiqrnotes.com)
    try {
      final records = await pb.collection('app_releases').getFullList(
        sort: '-created',
      );
      if (records.isNotEmpty) {
        final releases = records.asMap().entries.map((entry) {
          final release = AppRelease.fromRecord(entry.value, pb);
          if (entry.key == 0 && !release.isLatest) {
            return release.copyWith(isLatest: true);
          }
          return release;
        }).toList();

        final jsonList = releases.map((r) => r.toJson()).toList();
        await prefs.setString(cacheKey, jsonEncode(jsonList));
        return releases;
      }
    } catch (e) {
      print('Could not fetch app releases from PocketBase fallback: $e');
    }

    final cachedData = prefs.getString(cacheKey);
    if (cachedData != null) {
      try {
        final List<dynamic> decoded = jsonDecode(cachedData) as List<dynamic>;
        return decoded
            .map((item) => AppRelease.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
      } catch (_) {}
    }

    return [
      AppRelease(
        id: 'initial_release',
        version: 'v1.0.4',
        releaseDate: DateTime.now(),
        apkFileName: 'app-release.apk',
        apkUrl: '',
        changelog:
            'StiqrBudget with Zero-Knowledge StiQRcloud E2EE Sync, Monthly Sharding, SSE & QR Collaborators.',
        fileSize: 'v1.0.4',
        isLatest: true,
        isFallback: true,
      ),
    ];
  }

  Future<void> subscribeReleases(
    void Function(RecordSubscriptionEvent event) callback,
  ) async {
    if (!_releaseListeners.contains(callback)) {
      _releaseListeners.add(callback);
    }
  }

  Future<void> unsubscribeReleases() async {
    _releaseListeners.clear();
  }
}
