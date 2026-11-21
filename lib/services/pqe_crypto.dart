import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pqcrypto/pqcrypto.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;

/// Deterministically derived FIPS 203 ML-KEM-768 keypair.
class Mlkem768KeyPair {
  final Uint8List publicKey;
  final Uint8List secretKey;

  const Mlkem768KeyPair({
    required this.publicKey,
    required this.secretKey,
  });

  String get publicKeyBase64 => base64Encode(publicKey);
}

/// Result of wrapping a collaborator grant with Hybrid ML-KEM-768 + X25519 + AES-256-GCM.
class HybridWrappedGrant {
  final String kemScheme;
  final String mlkemCiphertextBase64;
  final String wrappedKey;

  const HybridWrappedGrant({
    required this.kemScheme,
    required this.mlkemCiphertextBase64,
    required this.wrappedKey,
  });
}

/// Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519 + AES-256-GCM) helper
/// for deterministic key derivation, collaborator grant wrapping/unwrapping,
/// backward compatibility with legacy X25519-only grants, and automatic
/// zero-action grant upgrades on sync.
class PqeCrypto {
  static const String hybridKemScheme = 'hybrid-mlkem768-x25519';
  static const String legacyKemScheme = 'x25519-only';
  static const String _mlkemKeygenDomain = 'stiqrbudget:mlkem768:v1';
  static const String _hybridWrapDomain = 'stiqrbudget:hybrid-wrap:v1';

  static int get mlkem768PublicKeyBytes => PqcKem.kyber768.params.publicKeyBytes;
  static int get mlkem768SecretKeyBytes => PqcKem.kyber768.params.secretKeyBytes;
  static int get mlkem768CiphertextBytes =>
      PqcKem.kyber768.params.ciphertextBytes;

  /// Deterministically derive a user's FIPS 203 ML-KEM-768 keypair from their
  /// 32-byte [identitySeed] using domain-separated SHA-256 expansion into the
  /// 64-byte `(d || z)` seed for `ML-KEM.KeyGen_internal(d, z)`.
  static Mlkem768KeyPair deriveMlkem768KeyPair(Uint8List identitySeed) {
    if (identitySeed.length != 32) {
      throw ArgumentError(
        'identitySeed must be 32 bytes, got ${identitySeed.length}',
      );
    }

    final d = Uint8List.fromList(
      crypto.sha256.convert([
        ...utf8.encode('$_mlkemKeygenDomain:d:'),
        ...identitySeed,
      ]).bytes,
    );
    final z = Uint8List.fromList(
      crypto.sha256.convert([
        ...utf8.encode('$_mlkemKeygenDomain:z:'),
        ...identitySeed,
      ]).bytes,
    );

    final seed64 = Uint8List(64)
      ..setAll(0, d)
      ..setAll(32, z);

    final (pk, sk) = PqcKem.kyber768.generateKeyPair(seed64);
    return Mlkem768KeyPair(publicKey: pk, secretKey: sk);
  }

  /// Parse and validate a base64-encoded (or hex-encoded) ML-KEM-768 public key.
  /// Returns `null` if [encoded] is null, empty, or malformed.
  static Uint8List? tryDecodeMlkem768PublicKey(String? encoded) {
    if (encoded == null) return null;
    final trimmed = encoded.trim();
    if (trimmed.isEmpty) return null;

    Uint8List? bytes;
    try {
      bytes = Uint8List.fromList(base64Decode(trimmed));
    } catch (_) {
      // Fallback: check if hex-encoded
      if (trimmed.length == mlkem768PublicKeyBytes * 2 &&
          RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) {
        bytes = hexToBytes(trimmed);
      }
    }

    if (bytes == null || bytes.length != mlkem768PublicKeyBytes) {
      return null;
    }
    return bytes;
  }

  /// Derive the 256-bit AES-GCM wrapping key by combining the ML-KEM-768 shared
  /// secret [ssPq] and X25519 ECDH shared secret [ssX25519]:
  /// `SHA-256("stiqrbudget:hybrid-wrap:v1" || ss_pq || ss_x25519)`.
  static Uint8List deriveHybridWrapKey({
    required Uint8List ssPq,
    required Uint8List ssX25519,
  }) {
    final digest = crypto.sha256.convert([
      ...utf8.encode(_hybridWrapDomain),
      ...ssPq,
      ...ssX25519,
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  /// Legacy X25519-only shared grant key derivation (kept 100% compatible with
  /// pre-v1.0.21 collaborator grants).
  static Future<Uint8List> deriveLegacyX25519GrantKey({
    required SimpleKeyPair myX25519KeyPair,
    required String peerX25519PubHex,
    required String sharedBudgetKey,
  }) async {
    final ssX25519 = await computeX25519SharedSecret(
      myX25519KeyPair: myX25519KeyPair,
      peerX25519PubHex: peerX25519PubHex,
    );
    final digest = crypto.sha256.convert([
      ...ssX25519,
      ...utf8.encode(':stiqrbudget:grant:v2:$sharedBudgetKey'),
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  static Future<Uint8List> computeX25519SharedSecret({
    required SimpleKeyPair myX25519KeyPair,
    required String peerX25519PubHex,
  }) async {
    final peerPub = SimplePublicKey(
      hexToBytes(peerX25519PubHex),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await X25519().sharedSecretKey(
      keyPair: myX25519KeyPair,
      remotePublicKey: peerPub,
    );
    return Uint8List.fromList(await sharedSecret.extractBytes());
  }

  /// Wrap [grantPlaintext] using Hybrid ML-KEM-768 + X25519 + AES-256-GCM.
  static Future<HybridWrappedGrant> wrapGrantHybrid({
    required String grantPlaintext,
    required SimpleKeyPair myX25519KeyPair,
    required String peerX25519PubHex,
    required Uint8List peerMlkem768PubKey,
  }) async {
    final (mlkemCt, ssPq) = PqcKem.kyber768.encapsulate(peerMlkem768PubKey);
    final ssX25519 = await computeX25519SharedSecret(
      myX25519KeyPair: myX25519KeyPair,
      peerX25519PubHex: peerX25519PubHex,
    );
    final wrapKey = deriveHybridWrapKey(ssPq: ssPq, ssX25519: ssX25519);
    final env = await sc.StiQRcloudCrypto.encryptText(grantPlaintext, wrapKey);

    return HybridWrappedGrant(
      kemScheme: hybridKemScheme,
      mlkemCiphertextBase64: base64Encode(mlkemCt),
      wrappedKey: env.encode(),
    );
  }

  /// Wrap [grantPlaintext] using legacy X25519-only + AES-256-GCM (fallback when
  /// a collaborator has not yet published an ML-KEM-768 public key).
  static Future<String> wrapGrantLegacyX25519({
    required String grantPlaintext,
    required SimpleKeyPair myX25519KeyPair,
    required String peerX25519PubHex,
    required String sharedBudgetKey,
  }) async {
    final wrapKey = await deriveLegacyX25519GrantKey(
      myX25519KeyPair: myX25519KeyPair,
      peerX25519PubHex: peerX25519PubHex,
      sharedBudgetKey: sharedBudgetKey,
    );
    final env = await sc.StiQRcloudCrypto.encryptText(grantPlaintext, wrapKey);
    return env.encode();
  }

  /// Unwrap a collaborator grant outer JSON map, automatically supporting both
  /// `hybrid-mlkem768-x25519` and legacy X25519-only grants.
  static Future<String> unwrapGrantOuter({
    required Map<String, dynamic> grantOuter,
    required SimpleKeyPair myX25519KeyPair,
    Mlkem768KeyPair? myMlkem768KeyPair,
  }) async {
    final ownerX25519Pub = (grantOuter['ownerX25519Pub'] ?? '').toString();
    final wrappedKey = (grantOuter['wrappedKey'] ?? '').toString();
    final sharedKey = (grantOuter['sharedBudgetKey'] ?? '').toString();
    final kemScheme = (grantOuter['kemScheme'] ?? '').toString();
    final mlkemCtB64 = (grantOuter['mlkemCiphertext'] ?? '').toString();

    if (ownerX25519Pub.isEmpty || wrappedKey.isEmpty) {
      throw const FormatException('Grant record is missing required fields.');
    }

    Uint8List wrapDek;
    if (kemScheme == hybridKemScheme && mlkemCtB64.isNotEmpty) {
      if (myMlkem768KeyPair == null) {
        throw StateError(
          'ML-KEM-768 keypair is required to unwrap hybrid grant.',
        );
      }
      final ct = Uint8List.fromList(base64Decode(mlkemCtB64));
      final ssPq = PqcKem.kyber768.decapsulate(
        myMlkem768KeyPair.secretKey,
        ct,
      );
      final ssX25519 = await computeX25519SharedSecret(
        myX25519KeyPair: myX25519KeyPair,
        peerX25519PubHex: ownerX25519Pub,
      );
      wrapDek = deriveHybridWrapKey(ssPq: ssPq, ssX25519: ssX25519);
    } else {
      wrapDek = await deriveLegacyX25519GrantKey(
        myX25519KeyPair: myX25519KeyPair,
        peerX25519PubHex: ownerX25519Pub,
        sharedBudgetKey: sharedKey,
      );
    }

    final env = sc.EncryptedEnvelope.tryParse(wrappedKey);
    if (env == null) {
      throw const FormatException('Invalid encrypted grant envelope.');
    }
    return sc.StiQRcloudCrypto.decryptText(env, wrapDek);
  }

  /// Build an outer grant JSON map, automatically using `hybrid-mlkem768-x25519`
  /// when [collaboratorMlkem768PubKey] is available or falling back to legacy
  /// X25519-only wrapping when absent.
  static Future<Map<String, dynamic>> buildGrantOuterRecord({
    required String ownerPubAddress,
    required SimpleKeyPair ownerX25519KeyPair,
    required String ownerX25519PubHex,
    required String collaboratorPubAddress,
    required String collaboratorX25519PubHex,
    required String sharedBudgetKey,
    required String budgetName,
    required Uint8List budgetDek,
    required String role,
    Uint8List? collaboratorMlkem768PubKey,
  }) async {
    final cleanRole = role == 'view' ? 'view' : 'edit';
    final grantPlaintext = jsonEncode({
      'v': collaboratorMlkem768PubKey != null ? 3 : 2,
      'sharedBudgetKey': sharedBudgetKey,
      'budgetName': budgetName,
      'ownerPubAddress': ownerPubAddress,
      'budgetDekB64': base64Encode(budgetDek),
      'role': cleanRole,
    });

    if (collaboratorMlkem768PubKey != null) {
      final wrapped = await wrapGrantHybrid(
        grantPlaintext: grantPlaintext,
        myX25519KeyPair: ownerX25519KeyPair,
        peerX25519PubHex: collaboratorX25519PubHex,
        peerMlkem768PubKey: collaboratorMlkem768PubKey,
      );
      return {
        'ownerPublicKey': ownerPubAddress,
        'ownerX25519Pub': ownerX25519PubHex,
        'collaboratorPubKey': collaboratorPubAddress,
        'sharedBudgetKey': sharedBudgetKey,
        'role': cleanRole,
        'revoked': false,
        'kemScheme': wrapped.kemScheme,
        'mlkemCiphertext': wrapped.mlkemCiphertextBase64,
        'wrappedKey': wrapped.wrappedKey,
      };
    } else {
      final wrappedKey = await wrapGrantLegacyX25519(
        grantPlaintext: grantPlaintext,
        myX25519KeyPair: ownerX25519KeyPair,
        peerX25519PubHex: collaboratorX25519PubHex,
        sharedBudgetKey: sharedBudgetKey,
      );
      return {
        'ownerPublicKey': ownerPubAddress,
        'ownerX25519Pub': ownerX25519PubHex,
        'collaboratorPubKey': collaboratorPubAddress,
        'sharedBudgetKey': sharedBudgetKey,
        'role': cleanRole,
        'revoked': false,
        'wrappedKey': wrappedKey,
      };
    }
  }

  /// Returns `true` if [grantOuter] is already wrapped with
  /// `hybrid-mlkem768-x25519`.
  static bool isHybridGrant(Map<String, dynamic> grantOuter) {
    final scheme = (grantOuter['kemScheme'] ?? '').toString();
    final ct = (grantOuter['mlkemCiphertext'] ?? '').toString();
    return scheme == hybridKemScheme && ct.isNotEmpty;
  }

  /// Inspect an existing owned grant record and, if it is still using legacy
  /// X25519-only wrapping and the collaborator has published a valid
  /// `mlkem768PubKey`, return the upgraded `hybrid-mlkem768-x25519` outer
  /// grant record. Returns `null` if no upgrade is needed or possible.
  static Future<Map<String, dynamic>?> upgradeLegacyGrantRecordIfEligible({
    required Map<String, dynamic> existingGrantOuter,
    required String ownerPubAddress,
    required SimpleKeyPair ownerX25519KeyPair,
    required String ownerX25519PubHex,
    required String collaboratorX25519PubHex,
    required String budgetName,
    required Uint8List budgetDek,
    required Future<Uint8List?> Function(String collaboratorPubAddress)
        lookupCollaboratorMlkem768PubKey,
  }) async {
    if (existingGrantOuter['revoked'] == true) return null;
    if (isHybridGrant(existingGrantOuter)) return null;

    final collabPub =
        (existingGrantOuter['collaboratorPubKey'] ?? '').toString();
    final sharedKey =
        (existingGrantOuter['sharedBudgetKey'] ?? '').toString();
    final role = (existingGrantOuter['role'] ?? 'edit').toString();
    if (collabPub.isEmpty || sharedKey.isEmpty) return null;

    final peerMlkemPub = await lookupCollaboratorMlkem768PubKey(collabPub);
    if (peerMlkemPub == null) return null;

    return buildGrantOuterRecord(
      ownerPubAddress: ownerPubAddress,
      ownerX25519KeyPair: ownerX25519KeyPair,
      ownerX25519PubHex: ownerX25519PubHex,
      collaboratorPubAddress: collabPub,
      collaboratorX25519PubHex: collaboratorX25519PubHex,
      sharedBudgetKey: sharedKey,
      budgetName: budgetName,
      budgetDek: budgetDek,
      role: role,
      collaboratorMlkem768PubKey: peerMlkemPub,
    );
  }

  static Uint8List hexToBytes(String hex) {
    final clean = hex.trim().replaceAll(' ', '');
    final out = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < clean.length; i += 2) {
      out[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return out;
  }
}
