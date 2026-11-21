import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;
import 'package:budget_app/models/category.dart';
import 'package:budget_app/models/transaction_model.dart';

Future<Map<String, dynamic>> deriveZkKeys(String rawEmail, String password) async {
  final cleanEmail = rawEmail.trim().toLowerCase();
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
  final keyBytes = Uint8List.fromList(await secretKey.extractBytes());
  final identitySeed = Uint8List.fromList(keyBytes.sublist(0, 32));
  final masterDek = Uint8List.fromList(keyBytes.sublist(32, 64));
  final keyPair = await sc.StiQRcloudCrypto.keyPairFromSeed(identitySeed);
  final pubAddress = await sc.StiQRcloudCrypto.getPublicAddress(keyPair);
  final acctHash = sc.StiQRcloudCrypto.sha256Hex(
    utf8.encode('stiqrbudget:acct:$cleanEmail'),
  );
  return {
    'pubAddress': pubAddress,
    'masterDek': masterDek,
    'accountRecordId': 'acct_${acctHash.substring(0, 24)}',
    'vaultRecordId': 'vault_${pubAddress.substring(0, 24)}',
  };
}

void main() {
  group('StiQRcloud Zero-Knowledge Auth & E2EE Vault Tests', () {
    test('Same login credentials on multiple devices derive identical keys without exposing email or password', () async {
      final device1 = await deriveZkKeys('User@Example.com ', 'MySecretPass!123');
      final device2 = await deriveZkKeys('user@example.com', 'MySecretPass!123');

      expect(device1['pubAddress'], equals(device2['pubAddress']));
      expect(device1['accountRecordId'], equals(device2['accountRecordId']));
      expect(device1['vaultRecordId'], equals(device2['vaultRecordId']));
      expect(device1['masterDek'], equals(device2['masterDek']));

      // Ensure accountRecordId and vaultRecordId do not contain plaintext email or password
      expect(device1['accountRecordId'].toString().contains('user'), isFalse);
      expect(device1['accountRecordId'].toString().contains('example'), isFalse);
      expect(device1['vaultRecordId'].toString().contains('user'), isFalse);
    });

    test('Encrypted vault hides all plaintext and decrypts across devices with same login', () async {
      final device1 = await deriveZkKeys('test@stiqrbudget.com', 'CorrectHorseBatteryStaple');
      final device2 = await deriveZkKeys('test@stiqrbudget.com', 'CorrectHorseBatteryStaple');
      final wrongDevice = await deriveZkKeys('test@stiqrbudget.com', 'WrongPassword');

      final dek1 = device1['masterDek'] as Uint8List;
      final dek2 = device2['masterDek'] as Uint8List;
      final wrongDek = wrongDevice['masterDek'] as Uint8List;

      final cat = Category(
        id: 'cat_groceries_1',
        name: 'Groceries Secret',
        balance: 425.50,
        colorHex: '#10B981',
        iconName: 'shopping_cart',
        allocationType: AllocationType.monthlyTarget,
        allocationValue: 600.0,
        user: device1['pubAddress'] as String,
      );

      final tx = TransactionModel(
        id: 'tx_market_1',
        description: 'Whole Foods Market',
        amount: -84.25,
        type: TransactionType.expense,
        category: cat.id,
        date: DateTime.utc(2026, 10, 30, 12, 0),
        user: device1['pubAddress'] as String,
      );

      final vaultJson = jsonEncode({
        'v': 1,
        'categories': [cat.toJson()],
        'transactions': [tx.toJson()],
        'rules': [
          {'id': 'rule_1', 'pattern': 'whole foods', 'category': cat.id}
        ],
      });

      final env = await sc.StiQRcloudCrypto.encryptText(vaultJson, dek1);
      final encodedCiphertext = env.encode();

      // Verify ciphertext is E2EE formatted and exposes zero plaintext
      expect(encodedCiphertext.startsWith('tc:enc:v1:'), isTrue);
      expect(encodedCiphertext.contains('Groceries Secret'), isFalse);
      expect(encodedCiphertext.contains('Whole Foods Market'), isFalse);
      expect(encodedCiphertext.contains('425.5'), isFalse);

      // Decrypt on Device 2 using derived DEK
      final parsedEnv = sc.EncryptedEnvelope.tryParse(encodedCiphertext)!;
      final decryptedStr = await sc.StiQRcloudCrypto.decryptText(parsedEnv, dek2);
      final decodedVault = jsonDecode(decryptedStr) as Map<String, dynamic>;

      final restoredCat = Category.fromJson(
        Map<String, dynamic>.from((decodedVault['categories'] as List).first as Map),
      );
      final restoredTx = TransactionModel.fromJson(
        Map<String, dynamic>.from((decodedVault['transactions'] as List).first as Map),
      );

      expect(restoredCat.id, equals('cat_groceries_1'));
      expect(restoredCat.name, equals('Groceries Secret'));
      expect(restoredCat.balance, equals(425.50));
      expect(restoredTx.id, equals('tx_market_1'));
      expect(restoredTx.description, equals('Whole Foods Market'));
      expect(restoredTx.amount, equals(-84.25));

      // Verify wrong password fails decryption
      expect(
        () => sc.StiQRcloudCrypto.decryptText(parsedEnv, wrongDek),
        throwsA(isA<sc.StiQRcloudCryptoException>()),
      );
    });

    test('X25519 collaborator grant unwraps only the shared budget DEK and keeps private budgets isolated', () async {
      final x25519 = X25519();
      final ownerX25519 = await x25519.newKeyPairFromSeed(List<int>.filled(32, 7));
      final collabX25519 = await x25519.newKeyPairFromSeed(List<int>.filled(32, 19));

      final ownerPub = await ownerX25519.extractPublicKey();
      final collabPub = await collabX25519.extractPublicKey();

      final sharedSecretOwner = await x25519.sharedSecretKey(
        keyPair: ownerX25519,
        remotePublicKey: collabPub,
      );
      final sharedSecretCollab = await x25519.sharedSecretKey(
        keyPair: collabX25519,
        remotePublicKey: ownerPub,
      );

      final ownerSecretBytes = await sharedSecretOwner.extractBytes();
      final collabSecretBytes = await sharedSecretCollab.extractBytes();
      expect(ownerSecretBytes, equals(collabSecretBytes));

      // Shared budget DEK vs Private budget DEK
      final sharedBudgetDek = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final privateBudgetDek = Uint8List.fromList(List<int>.generate(32, (i) => i + 100));

      final wrapKey = Uint8List.fromList(ownerSecretBytes);
      final wrappedGrantEnv = await sc.StiQRcloudCrypto.encryptText(
        jsonEncode({
          'budgetName': 'Household Shared',
          'budgetDekB64': base64Encode(sharedBudgetDek),
          'role': 'edit',
        }),
        wrapKey,
      );

      // Collaborator unwraps sharedBudgetDek
      final unwrappedStr = await sc.StiQRcloudCrypto.decryptText(
        wrappedGrantEnv,
        Uint8List.fromList(collabSecretBytes),
      );
      final grantData = jsonDecode(unwrappedStr) as Map<String, dynamic>;
      final collabRecoveredDek = Uint8List.fromList(
        base64Decode(grantData['budgetDekB64'] as String),
      );

      expect(collabRecoveredDek, equals(sharedBudgetDek));

      // Encrypt a monthly shard for shared budget and one for private budget
      final sharedShardEnv = await sc.StiQRcloudCrypto.encryptText(
        '{"month":"2026-10","transactions":[{"description":"Shared Rent"}]}',
        sharedBudgetDek,
      );
      final privateShardEnv = await sc.StiQRcloudCrypto.encryptText(
        '{"month":"2026-10","transactions":[{"description":"Private Gift"}]}',
        privateBudgetDek,
      );

      final decryptedSharedShard = await sc.StiQRcloudCrypto.decryptText(
        sharedShardEnv,
        collabRecoveredDek,
      );
      expect(decryptedSharedShard.contains('Shared Rent'), isTrue);

      // Collaborator cannot decrypt private budget shard
      expect(
        () => sc.StiQRcloudCrypto.decryptText(privateShardEnv, collabRecoveredDek),
        throwsA(isA<sc.StiQRcloudCryptoException>()),
      );
    });
  });
}
