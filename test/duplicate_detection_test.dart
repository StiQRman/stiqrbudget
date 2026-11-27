import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:budget_app/models/transaction_model.dart';
import 'package:budget_app/services/pocketbase_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Duplicate transaction detection (v1.0.25 regression tests)', () {
    final now = DateTime(2026, 11, 27, 14, 0);

    TransactionModel makeTx({
      required String id,
      required double amount,
      String? category = 'cat_coffee',
      TransactionType type = TransactionType.expense,
      DateTime? date,
      String description = 'Coffee',
    }) {
      return TransactionModel(
        id: id,
        amount: amount,
        category: category,
        type: type,
        user: 'test_user',
        date: date ?? now,
        description: description,
      );
    }

    test('single device logging & syncing NEVER triggers onDuplicateTransactionsDetected', () async {
      final pb = PocketBaseService();
      final detected = <List<DuplicateTxPair>>[];
      pb.onDuplicateTransactionsDetected = (pairs) => detected.add(pairs);

      // User logs a $5 expense on a single device
      final tx1 = await pb.createTransaction(
        makeTx(id: 'tx_single_1', amount: -5.00, date: now),
        syncImmediately: false,
      );

      // Push pre-merge when remote is empty
      pb.checkAndNotifyDuplicates([], [tx1], now: now);
      expect(detected, isEmpty);

      // Subsequent pull/push where remote now contains tx1 (this device's own tx)
      pb.checkAndNotifyDuplicates([tx1], [tx1], now: now);
      expect(detected, isEmpty);

      // User intentionally logs a SECOND $5 expense later the same day on the SAME device
      final tx2 = await pb.createTransaction(
        makeTx(
          id: 'tx_single_2',
          amount: -5.00,
          date: now.add(const Duration(hours: 2)),
          description: 'Afternoon coffee',
        ),
        syncImmediately: false,
      );

      // Remote has tx1 (which is ALREADY in local!) and local has [tx1, tx2]
      pb.checkAndNotifyDuplicates([tx1], [tx1, tx2], now: now.add(const Duration(hours: 2)));
      expect(detected, isEmpty);

      // Next background sync where both remote and local have [tx1, tx2]
      pb.checkAndNotifyDuplicates([tx1, tx2], [tx1, tx2], now: now.add(const Duration(hours: 2)));
      expect(detected, isEmpty);
    });

    test('historical \$5 transaction in same category does NOT falsely trigger on new tx or background sync', () async {
      final pb = PocketBaseService();
      final detected = <List<DuplicateTxPair>>[];
      pb.onDuplicateTransactionsDetected = (pairs) => detected.add(pairs);

      // Old $5 transactions from 10 days ago already synced to cloud & local
      final oldTxA = makeTx(
        id: 'tx_old_5_a',
        amount: -5.00,
        date: now.subtract(const Duration(days: 10)),
        description: 'Old \$5 coffee A',
      );
      final oldTxB = makeTx(
        id: 'tx_old_5_b',
        amount: -5.00,
        date: now.subtract(const Duration(days: 10)),
        description: 'Old \$5 coffee B',
      );

      // User logs a brand-new $5 expense today on this device
      final todayTx = await pb.createTransaction(
        makeTx(
          id: 'tx_today_5',
          amount: -5.00,
          date: now,
          description: 'Today \$5 coffee',
        ),
        syncImmediately: false,
      );

      // Remote has the historical $5 txs; local has historical + todayTx
      pb.checkAndNotifyDuplicates(
        [oldTxA, oldTxB],
        [oldTxA, oldTxB, todayTx],
        now: now,
      );
      expect(detected, isEmpty);

      // Even if an old historical $5 tx from 10 days ago arrived fresh from remote,
      // recency + 24h date window must prevent flagging it
      final veryOldRemoteTx = makeTx(
        id: 'tx_remote_ancient_5',
        amount: -5.00,
        date: now.subtract(const Duration(days: 12)),
        description: 'Ancient \$5',
      );
      pb.checkAndNotifyDuplicates(
        [oldTxA, veryOldRemoteTx],
        [oldTxA, todayTx],
        now: now,
      );
      expect(detected, isEmpty);
    });

    test('two different devices logging exact same amount + category on same day triggers ONCE, and Keep Both never re-prompts', () async {
      final pb = PocketBaseService();
      final detected = <List<DuplicateTxPair>>[];
      pb.onDuplicateTransactionsDetected = (pairs) => detected.add(pairs);

      // Device A logs $12.50 locally (unsynced)
      final deviceATx = await pb.createTransaction(
        makeTx(
          id: 'tx_dev_a',
          amount: -12.50,
          category: 'cat_dining',
          date: now,
          description: 'Lunch (Device A)',
        ),
        syncImmediately: false,
      );

      // Device B concurrently pushed $12.50 in same category within 24h
      final deviceBTx = makeTx(
        id: 'tx_dev_b',
        amount: -12.50,
        category: 'cat_dining',
        date: now.add(const Duration(minutes: 15)),
        description: 'Lunch (Device B)',
      );

      // First merge detects the genuine cross-device duplicate ONCE
      final firstPass = pb.checkAndNotifyDuplicates(
        [deviceBTx],
        [deviceATx],
        now: now.add(const Duration(minutes: 20)),
      );
      expect(firstPass.length, 1);
      expect(firstPass.first.localTx.id, 'tx_dev_a');
      expect(firstPass.first.remoteTx.id, 'tx_dev_b');
      expect(detected.length, 1);

      // User chooses "Keep Both"
      await pb.markDuplicatePairResolved(deviceATx.id, deviceBTx.id);

      // Subsequent 45-second background syncs must NEVER prompt again
      final secondPass = pb.checkAndNotifyDuplicates(
        [deviceBTx],
        [deviceATx],
        now: now.add(const Duration(minutes: 21)),
      );
      expect(secondPass, isEmpty);
      expect(detected.length, 1);
    });

    test('Keep Only One deletes the remote duplicate cleanly and prevents resurrection', () async {
      final pb = PocketBaseService();
      final detected = <List<DuplicateTxPair>>[];
      pb.onDuplicateTransactionsDetected = (pairs) => detected.add(pairs);

      final localTx = await pb.createTransaction(
        makeTx(id: 'tx_keep', amount: -25.00, category: 'cat_gas', date: now),
        syncImmediately: false,
      );
      final remoteTx = makeTx(
        id: 'tx_dup_remote',
        amount: -25.00,
        category: 'cat_gas',
        date: now.add(const Duration(minutes: 5)),
      );

      final pairs = pb.checkAndNotifyDuplicates(
        [remoteTx],
        [localTx],
        now: now.add(const Duration(minutes: 10)),
      );
      expect(pairs.length, 1);

      // User taps "Keep Only One"
      await pb.resolveDuplicateKeepOnlyOne(pairs.first);

      // Remote duplicate must not be in local transactions
      expect(pb.transactions.any((t) => t.id == 'tx_dup_remote'), isFalse);
      expect(pb.transactions.any((t) => t.id == 'tx_keep'), isTrue);

      // Even if remote still sends tx_dup_remote before push completes, it is ignored
      final nextPairs = pb.checkAndNotifyDuplicates(
        [remoteTx],
        [localTx],
        now: now.add(const Duration(minutes: 11)),
      );
      expect(nextPairs, isEmpty);
    });

    test('tight matching ignores different amounts, categories, or dates > 24h apart', () {
      final localTx = makeTx(
        id: 'tx_l',
        amount: -10.00,
        category: 'cat_groceries',
        date: now,
      );

      // Different amount (diff >= 0.005)
      final diffAmount = makeTx(
        id: 'tx_r1',
        amount: -10.01,
        category: 'cat_groceries',
        date: now,
      );
      // Different category
      final diffCat = makeTx(
        id: 'tx_r2',
        amount: -10.00,
        category: 'cat_dining',
        date: now,
      );
      // More than 24 hours apart
      final diffDate = makeTx(
        id: 'tx_r3',
        amount: -10.00,
        category: 'cat_groceries',
        date: now.subtract(const Duration(hours: 25)),
      );

      final pairs = PocketBaseService.findPotentialDuplicates(
        [diffAmount, diffCat, diffDate],
        [localTx],
        now: now,
      );
      expect(pairs, isEmpty);
    });
  });
}
