import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:voys_matrix_sliding_sync/voys_matrix_sliding_sync.dart';

Future<DatabaseApi> _createDatabase() async {
  sqfliteFfiInit();
  return MatrixSdkDatabase.init(
    'integration-test.${DateTime.now().millisecondsSinceEpoch}',
    database: await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
  );
}

void main() {
  final accessToken = Platform.environment['ACCESS_TOKEN'] ?? '';

  group(
    'SlidingSync integration',
    skip: accessToken.isEmpty
        ? 'Integration tests require credentials.\nRun: ./run_tests.sh --token <your_token>'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      late SlidingSyncOnlyClient client;
      late SlidingSync slidingSync;

      setUpAll(() async {
        client = SlidingSyncOnlyClient(
          'integration-test',
          database: await _createDatabase(),
        );

        await client.init(
          waitForFirstSync: false,
          waitUntilLoadCompletedLoaded: false,
        );

        await client.checkHomeserver(
          Uri.parse('https://matrix.eu-production.holodeck.voys.nl'),
        );

        await client.login(
          'nl.voys.single_user',
          token: accessToken,
          identifier: AuthenticationUserIdentifier(user: ''),
        );

        slidingSync =
            SlidingSync.builder(id: 'integration-test', client: client)
                .addList(
                  SlidingSyncList(
                    syncMode: SyncMode.growing,
                    timelineLimit: 0,
                    requiredState: RequiredStateRequest.minimal(),
                    batchSize: 5,
                  ),
                )
                .withPollTimeout(0)
                .build();
      });

      tearDownAll(() async {
        await slidingSync.dispose();
        await client.logout();
      });

      test('loads rooms on first sync', () async {
        await slidingSync.syncOnce();
        expect(slidingSync.list!.roomIds, isNotEmpty);
      });

      test('loads more rooms after loadMore()', () async {
        final initialCount = slidingSync.list!.roomIds.length;

        if ((slidingSync.list!.totalRoomCount ?? initialCount) <= 5) {
          markTestSkipped('Account needs more than 5 rooms for this test');
          return;
        }

        slidingSync.list!.loadMore();
        await slidingSync.syncOnce();
        expect(slidingSync.list!.roomIds.length, greaterThan(initialCount));
      });
    },
  );
}
