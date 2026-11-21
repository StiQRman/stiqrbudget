import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stiqrcloud/stiqrcloud.dart' as sc;
import 'package:budget_app/models/category.dart';
import 'package:budget_app/services/pocketbase_service.dart';

Category _makeCat(
  String id,
  String name, {
  double balance = 0.0,
  String budgetId = 'budget_1',
}) {
  return Category(
    id: id,
    name: name,
    balance: balance,
    allocationType: AllocationType.values.first,
    allocationValue: 0.0,
    colorHex: '#10B981',
    iconName: 'category',
    user: 'test_user',
    budgetId: budgetId,
  );
}

sc.RecordModel _makeRecord(String collection, String id, String text) {
  return sc.RecordModel(
    id: id,
    collection: collection,
    data: {'text': text},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Envelope persistence regression tests', () {
    test(
      '0-transaction account: creating an envelope then calling fetchTransactions() + pullFromCloud() does not wipe the envelope',
      () async {
        SharedPreferences.setMockInitialValues({});
        final service = PocketBaseService();

        final cloudStore = <String, sc.RecordModel>{};
        service.debugGetRecordOverride = (collection, recordId) async {
          return cloudStore['$collection/$recordId'];
        };
        service.debugUpsertRecordOverride = (collection, recordId, textPayload) async {
          final rec = _makeRecord(collection, recordId, textPayload);
          cloudStore['$collection/$recordId'] = rec;
          return rec;
        };

        await service.debugInitTestSession(
          email: 'newuser@stiqrbudget.test',
          password: 'StrongTestPassword!1',
          hasLoadedRemoteOnce: true,
        );

        // Seed an older local cache containing only the Unallocated envelope (0 transactions)
        final unallocated = _makeCat('cat_unalloc', 'Unallocated');
        await service.createCategory(unallocated, syncImmediately: false);
        await service.debugSaveStateToLocalCache();

        // Simulate remote cloud also having only Unallocated (older timestamp)
        final sharedKey = service.debugSharedBudgetKey('budget_1')!;
        final initialEncryptedMeta = await service.debugEncryptBudgetPayload('budget_1', {
          'v': 2,
          'sharedBudgetKey': sharedKey,
          'budgetName': 'My Budget',
          'ownerPubAddress': service.currentUserId,
          'updatedAt': DateTime.now().millisecondsSinceEpoch - 5000,
          'categories': [unallocated.toJson()],
          'rules': <Map<String, dynamic>>[],
          'collaborators': <Map<String, dynamic>>[],
          'shardRevisions': <String, int>{},
        });
        cloudStore['${PocketBaseService.budgetMetaCollection}/bmeta_$sharedKey'] =
            _makeRecord(
          PocketBaseService.budgetMetaCollection,
          'bmeta_$sharedKey',
          initialEncryptedMeta,
        );

        // User creates a brand new envelope while account still has 0 transactions
        final groceries = _makeCat('cat_groceries', 'Groceries', balance: 250.0);
        await service.createCategory(groceries, syncImmediately: false);

        // Immediately trigger fetchTransactions() (which previously called _loadStateFromLocalCache()
        // because _transactions.isEmpty!) and pullFromCloud()
        final txs = await service.fetchTransactions();
        expect(txs, isEmpty);

        await service.pullFromCloud(notifyChanges: false);

        final cats = await service.fetchCategories();
        final catIds = cats.map((c) => c.id).toSet();
        expect(catIds, contains('cat_groceries'));
        expect(catIds, contains('cat_unalloc'));
      },
    );

    test(
      'mid-push race: creating Envelope B while Push #1 (Envelope A) is in flight preserves dirty flag and merges both envelopes',
      () async {
        SharedPreferences.setMockInitialValues({});
        final service = PocketBaseService();

        final cloudStore = <String, sc.RecordModel>{};
        final push1Started = Completer<void>();
        final releasePush1 = Completer<void>();
        int bmetaUpsertCount = 0;

        service.debugGetRecordOverride = (collection, recordId) async {
          return cloudStore['$collection/$recordId'];
        };
        service.debugUpsertRecordOverride = (collection, recordId, textPayload) async {
          if (collection == PocketBaseService.budgetMetaCollection) {
            bmetaUpsertCount++;
            if (bmetaUpsertCount == 1) {
              push1Started.complete();
              await releasePush1.future;
            }
          }
          final rec = _makeRecord(collection, recordId, textPayload);
          cloudStore['$collection/$recordId'] = rec;
          return rec;
        };

        await service.debugInitTestSession(
          email: 'race@stiqrbudget.test',
          password: 'StrongTestPassword!2',
          hasLoadedRemoteOnce: true,
        );
        final sharedKey = service.debugSharedBudgetKey('budget_1')!;

        // Create Envelope A and start Push #1 (which pauses mid-network on bmeta upsert)
        final envA = _makeCat('cat_env_a', 'Envelope A');
        final push1Future = service.createCategory(envA, syncImmediately: true);
        await push1Started.future;

        // While Push #1 is in flight, create Envelope B locally (without awaiting its push yet)
        final envB = _makeCat('cat_env_b', 'Envelope B');
        await service.createCategory(envB, syncImmediately: false);

        // Release Push #1 (which only uploaded Envelope A)
        releasePush1.complete();
        await push1Future;

        // Root Cause #2 check: sharedKey MUST still be dirty because Envelope B was created mid-push!
        expect(service.debugDirtyBudgetMetaKeys, contains(sharedKey));

        // Even if an intervening pull runs right now (fetching cloud bmeta which only has Envelope A),
        // Envelope B MUST NOT be wiped because sharedKey is still dirty and triggers mergeCategories!
        await service.pullFromCloud(notifyChanges: false);
        expect(
          service.debugCategories.map((c) => c.id).toSet(),
          containsAll(<String>['cat_env_a', 'cat_env_b']),
        );

        // Second push uploads both Envelope A and Envelope B cleanly and clears dirty key
        await service.syncVaultToCloud();
        expect(service.debugDirtyBudgetMetaKeys, isNot(contains(sharedKey)));

        // Final pull confirms both envelopes persisted to cloud
        await service.pullFromCloud(notifyChanges: false);
        expect(
          service.debugCategories.map((c) => c.id).toSet(),
          containsAll(<String>['cat_env_a', 'cat_env_b']),
        );
      },
    );

    test(
      'stale-timestamp guard: _applyBudgetMetaRecord ignores older remote bmeta payloads',
      () async {
        SharedPreferences.setMockInitialValues({});
        final service = PocketBaseService();

        final cloudStore = <String, sc.RecordModel>{};
        service.debugGetRecordOverride = (collection, recordId) async {
          return cloudStore['$collection/$recordId'];
        };
        service.debugUpsertRecordOverride = (collection, recordId, textPayload) async {
          final rec = _makeRecord(collection, recordId, textPayload);
          cloudStore['$collection/$recordId'] = rec;
          return rec;
        };

        await service.debugInitTestSession(
          email: 'stale@stiqrbudget.test',
          password: 'StrongTestPassword!3',
          hasLoadedRemoteOnce: true,
        );
        final sharedKey = service.debugSharedBudgetKey('budget_1')!;

        // Create and push Envelope A so _budgetMetaUpdatedAt[sharedKey] is set to T_now
        final envA = _makeCat('cat_env_a', 'Envelope A');
        await service.createCategory(envA, syncImmediately: true);
        final currentUpdatedAt = service.debugBudgetMetaUpdatedAt[sharedKey]!;
        expect(currentUpdatedAt, greaterThan(0));

        // Craft a stale remote bmeta record with older timestamp and empty categories
        final staleEncrypted = await service.debugEncryptBudgetPayload('budget_1', {
          'v': 2,
          'sharedBudgetKey': sharedKey,
          'budgetName': 'My Budget',
          'ownerPubAddress': service.currentUserId,
          'updatedAt': currentUpdatedAt - 10000,
          'categories': <Map<String, dynamic>>[],
          'rules': <Map<String, dynamic>>[],
          'collaborators': <Map<String, dynamic>>[],
          'shardRevisions': <String, int>{},
        });
        final staleRec = _makeRecord(
          PocketBaseService.budgetMetaCollection,
          'bmeta_$sharedKey',
          staleEncrypted,
        );

        final applied = await service.debugApplyBudgetMetaRecord('budget_1', staleRec);
        expect(applied, isFalse);
        expect(
          service.debugCategories.map((c) => c.id).toSet(),
          contains('cat_env_a'),
        );
      },
    );
  });
}
