import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;
import 'package:budget_app/services/pqe_crypto.dart';

Future<String> _x25519PubHex(SimpleKeyPair kp) async {
  final pub = await kp.extractPublicKey();
  return pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

void main() {
  group('Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519 + AES-256-GCM)', () {
    test('1. Deterministic ML-KEM-768 keygen from 32-byte identitySeed', () {
      final seedA = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF));
      final seedB = Uint8List.fromList(List<int>.generate(32, (i) => (i * 11 + 5) & 0xFF));

      final kpDevice1 = PqeCrypto.deriveMlkem768KeyPair(seedA);
      final kpDevice2 = PqeCrypto.deriveMlkem768KeyPair(seedA);
      final kpOtherUser = PqeCrypto.deriveMlkem768KeyPair(seedB);

      // Exact FIPS 203 ML-KEM-768 sizes
      expect(kpDevice1.publicKey.length, equals(1184));
      expect(kpDevice1.secretKey.length, equals(2400));

      // Identical across devices logging in with the same identitySeed
      expect(kpDevice1.publicKey, equals(kpDevice2.publicKey));
      expect(kpDevice1.secretKey, equals(kpDevice2.secretKey));
      expect(kpDevice1.publicKeyBase64, equals(kpDevice2.publicKeyBase64));

      // Distinct across different users
      expect(kpDevice1.publicKey, isNot(equals(kpOtherUser.publicKey)));
      expect(kpDevice1.secretKey, isNot(equals(kpOtherUser.secretKey)));

      // Public key parser validates base64 and rejects malformed values
      expect(
        PqeCrypto.tryDecodeMlkem768PublicKey(kpDevice1.publicKeyBase64),
        equals(kpDevice1.publicKey),
      );
      expect(PqeCrypto.tryDecodeMlkem768PublicKey(''), isNull);
      expect(PqeCrypto.tryDecodeMlkem768PublicKey('not-valid-base64!!!'), isNull);
      expect(PqeCrypto.tryDecodeMlkem768PublicKey(base64Encode([1, 2, 3])), isNull);
    });

    test('2. Hybrid ML-KEM-768 + X25519 + AES-256-GCM grant wrap/unwrap roundtrip', () async {
      final ownerSeed = Uint8List.fromList(List<int>.filled(32, 0x11));
      final collabSeed = Uint8List.fromList(List<int>.filled(32, 0x22));
      final attackerSeed = Uint8List.fromList(List<int>.filled(32, 0x33));

      final x25519 = X25519();
      final ownerX25519 = await x25519.newKeyPairFromSeed(ownerSeed);
      final collabX25519 = await x25519.newKeyPairFromSeed(collabSeed);
      final attackerX25519 = await x25519.newKeyPairFromSeed(attackerSeed);

      final ownerX25519Hex = await _x25519PubHex(ownerX25519);
      final collabX25519Hex = await _x25519PubHex(collabX25519);

      final collabMlkem = PqeCrypto.deriveMlkem768KeyPair(collabSeed);
      final attackerMlkem = PqeCrypto.deriveMlkem768KeyPair(attackerSeed);

      final budgetDek = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      const sharedBudgetKey = 'budget_hybrid_test_001';

      final grantOuter = await PqeCrypto.buildGrantOuterRecord(
        ownerPubAddress: 'a' * 64,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorPubAddress: 'b' * 64,
        collaboratorX25519PubHex: collabX25519Hex,
        sharedBudgetKey: sharedBudgetKey,
        budgetName: 'Family PQE Budget',
        budgetDek: budgetDek,
        role: 'edit',
        collaboratorMlkem768PubKey: collabMlkem.publicKey,
      );

      expect(grantOuter['kemScheme'], equals('hybrid-mlkem768-x25519'));
      expect(PqeCrypto.isHybridGrant(grantOuter), isTrue);

      final ctBytes = base64Decode(grantOuter['mlkemCiphertext'] as String);
      expect(ctBytes.length, equals(PqeCrypto.mlkem768CiphertextBytes)); // 1088 bytes
      expect((grantOuter['wrappedKey'] as String).startsWith('tc:enc:v1:'), isTrue);
      expect((grantOuter['wrappedKey'] as String).contains('Family PQE Budget'), isFalse);

      // Collaborator unwraps with their deterministic ML-KEM-768 + X25519 keys
      final decryptedStr = await PqeCrypto.unwrapGrantOuter(
        grantOuter: grantOuter,
        myX25519KeyPair: collabX25519,
        myMlkem768KeyPair: collabMlkem,
      );
      final grantMap = jsonDecode(decryptedStr) as Map<String, dynamic>;
      expect(grantMap['budgetName'], equals('Family PQE Budget'));
      expect(grantMap['sharedBudgetKey'], equals(sharedBudgetKey));
      expect(base64Decode(grantMap['budgetDekB64'] as String), equals(budgetDek));
      expect(grantMap['role'], equals('edit'));

      // Wrong ML-KEM keypair fails even if X25519 keypair is compromised (post-quantum security!)
      await expectLater(
        () => PqeCrypto.unwrapGrantOuter(
          grantOuter: grantOuter,
          myX25519KeyPair: collabX25519,
          myMlkem768KeyPair: attackerMlkem,
        ),
        throwsA(isA<sc.StiQRcloudCryptoException>()),
      );

      // Wrong X25519 keypair fails even if ML-KEM keypair is matched (classical security!)
      await expectLater(
        () => PqeCrypto.unwrapGrantOuter(
          grantOuter: grantOuter,
          myX25519KeyPair: attackerX25519,
          myMlkem768KeyPair: collabMlkem,
        ),
        throwsA(isA<sc.StiQRcloudCryptoException>()),
      );
    });

    test('3. Backward compatibility with legacy X25519-only grants', () async {
      final x25519 = X25519();
      final ownerX25519 = await x25519.newKeyPairFromSeed(List<int>.filled(32, 0x44));
      final collabX25519 = await x25519.newKeyPairFromSeed(List<int>.filled(32, 0x55));
      final ownerX25519Hex = await _x25519PubHex(ownerX25519);
      final collabX25519Hex = await _x25519PubHex(collabX25519);

      final budgetDek = Uint8List.fromList(List<int>.generate(32, (i) => i + 10));
      const sharedBudgetKey = 'budget_legacy_x25519_001';

      // Build a legacy X25519-only grant (no collaboratorMlkem768PubKey)
      final legacyOuter = await PqeCrypto.buildGrantOuterRecord(
        ownerPubAddress: 'c' * 64,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorPubAddress: 'd' * 64,
        collaboratorX25519PubHex: collabX25519Hex,
        sharedBudgetKey: sharedBudgetKey,
        budgetName: 'Legacy Shared Budget',
        budgetDek: budgetDek,
        role: 'view',
        collaboratorMlkem768PubKey: null,
      );

      expect(legacyOuter.containsKey('kemScheme'), isFalse);
      expect(legacyOuter.containsKey('mlkemCiphertext'), isFalse);
      expect(PqeCrypto.isHybridGrant(legacyOuter), isFalse);

      // New client (even with ML-KEM keypair present) cleanly unwraps legacy X25519 grant
      final collabMlkem = PqeCrypto.deriveMlkem768KeyPair(
        Uint8List.fromList(List<int>.filled(32, 0x55)),
      );
      final decryptedStr = await PqeCrypto.unwrapGrantOuter(
        grantOuter: legacyOuter,
        myX25519KeyPair: collabX25519,
        myMlkem768KeyPair: collabMlkem,
      );
      final grantMap = jsonDecode(decryptedStr) as Map<String, dynamic>;
      expect(grantMap['budgetName'], equals('Legacy Shared Budget'));
      expect(base64Decode(grantMap['budgetDekB64'] as String), equals(budgetDek));
      expect(grantMap['role'], equals('view'));
    });

    test('4. Automatic zero-action upgrade of legacy grants to hybrid-mlkem768-x25519 on sync', () async {
      final ownerSeed = Uint8List.fromList(List<int>.filled(32, 0x66));
      final collabSeed = Uint8List.fromList(List<int>.filled(32, 0x77));

      final x25519 = X25519();
      final ownerX25519 = await x25519.newKeyPairFromSeed(ownerSeed);
      final collabX25519 = await x25519.newKeyPairFromSeed(collabSeed);
      final ownerX25519Hex = await _x25519PubHex(ownerX25519);
      final collabX25519Hex = await _x25519PubHex(collabX25519);
      final collabMlkem = PqeCrypto.deriveMlkem768KeyPair(collabSeed);

      final budgetDek = Uint8List.fromList(List<int>.generate(32, (i) => (i * 3) & 0xFF));
      const sharedBudgetKey = 'budget_autoupgrade_001';
      final ownerPub = 'e' * 64;
      final collabPub = 'f' * 64;

      // Step A: Initial legacy grant (collaborator had not upgraded yet)
      final legacyOuter = await PqeCrypto.buildGrantOuterRecord(
        ownerPubAddress: ownerPub,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorPubAddress: collabPub,
        collaboratorX25519PubHex: collabX25519Hex,
        sharedBudgetKey: sharedBudgetKey,
        budgetName: 'Household Budget',
        budgetDek: budgetDek,
        role: 'edit',
        collaboratorMlkem768PubKey: null,
      );
      expect(PqeCrypto.isHybridGrant(legacyOuter), isFalse);

      // Step B: Sync while collaborator still has NO mlkem768PubKey in pubkeys directory
      final simulatedPubkeysDirectory = <String, String>{};
      final noUpgradeYet = await PqeCrypto.upgradeLegacyGrantRecordIfEligible(
        existingGrantOuter: legacyOuter,
        ownerPubAddress: ownerPub,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorX25519PubHex: collabX25519Hex,
        budgetName: 'Household Budget',
        budgetDek: budgetDek,
        lookupCollaboratorMlkem768PubKey: (pub) async =>
            PqeCrypto.tryDecodeMlkem768PublicKey(simulatedPubkeysDirectory[pub]),
      );
      expect(noUpgradeYet, isNull);

      // Step C: Collaborator logs in / syncs on v1.0.21 -> publishes mlkem768PubKey
      simulatedPubkeysDirectory[collabPub] = collabMlkem.publicKeyBase64;

      // Step D: Owner's next sync silently upgrades legacy grant to hybrid-mlkem768-x25519
      final upgradedOuter = await PqeCrypto.upgradeLegacyGrantRecordIfEligible(
        existingGrantOuter: legacyOuter,
        ownerPubAddress: ownerPub,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorX25519PubHex: collabX25519Hex,
        budgetName: 'Household Budget',
        budgetDek: budgetDek,
        lookupCollaboratorMlkem768PubKey: (pub) async =>
            PqeCrypto.tryDecodeMlkem768PublicKey(simulatedPubkeysDirectory[pub]),
      );
      expect(upgradedOuter, isNotNull);
      expect(upgradedOuter!['kemScheme'], equals('hybrid-mlkem768-x25519'));
      expect(PqeCrypto.isHybridGrant(upgradedOuter), isTrue);

      // Step E: Collaborator seamlessly unwraps the upgraded hybrid grant and recovers exact DEK
      final decryptedStr = await PqeCrypto.unwrapGrantOuter(
        grantOuter: upgradedOuter,
        myX25519KeyPair: collabX25519,
        myMlkem768KeyPair: collabMlkem,
      );
      final grantMap = jsonDecode(decryptedStr) as Map<String, dynamic>;
      expect(grantMap['budgetName'], equals('Household Budget'));
      expect(base64Decode(grantMap['budgetDekB64'] as String), equals(budgetDek));

      // Step F: Subsequent sync sees grant is already hybrid and returns null (no redundant write)
      final secondPass = await PqeCrypto.upgradeLegacyGrantRecordIfEligible(
        existingGrantOuter: upgradedOuter,
        ownerPubAddress: ownerPub,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorX25519PubHex: collabX25519Hex,
        budgetName: 'Household Budget',
        budgetDek: budgetDek,
        lookupCollaboratorMlkem768PubKey: (pub) async =>
            PqeCrypto.tryDecodeMlkem768PublicKey(simulatedPubkeysDirectory[pub]),
      );
      expect(secondPass, isNull);

      // Step G: Revoked grants are never upgraded
      final revokedOuter = {...legacyOuter, 'revoked': true};
      final revokedResult = await PqeCrypto.upgradeLegacyGrantRecordIfEligible(
        existingGrantOuter: revokedOuter,
        ownerPubAddress: ownerPub,
        ownerX25519KeyPair: ownerX25519,
        ownerX25519PubHex: ownerX25519Hex,
        collaboratorX25519PubHex: collabX25519Hex,
        budgetName: 'Household Budget',
        budgetDek: budgetDek,
        lookupCollaboratorMlkem768PubKey: (pub) async =>
            PqeCrypto.tryDecodeMlkem768PublicKey(simulatedPubkeysDirectory[pub]),
      );
      expect(revokedResult, isNull);
    });
  });
}
