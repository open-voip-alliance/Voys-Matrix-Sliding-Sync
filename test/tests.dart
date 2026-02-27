import 'dart:async';
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
  final accessToken = Platform.environment['ACCESS_TOKEN'];
  if (accessToken == null || accessToken.isEmpty) {
    throw Exception(
      'ACCESS_TOKEN is required.\nRun: ./run_tests.sh --token <your_token>',
    );
  }

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
      identifier: AuthenticationUserIdentifier(user: 'test user'),
    );

    slidingSync = SlidingSync.builder(client: client)
        .addList(
          SlidingSyncList(
            syncMode: SyncMode.growing,
            timelineLimit: 0,
            requiredState: RequiredStateRequest.minimal(),
            batchSize: 5,
          ),
        )
        .build();
  });

  tearDownAll(() async {
    await slidingSync.dispose();
    await client.logout();
  });

  test('loads rooms on first sync', () async {
    unawaited(slidingSync.startSync());
    await slidingSync.updateStream.first;
    await slidingSync.stopSync();
    expect(slidingSync.list!.roomIds, isNotEmpty);
  });

  test('loads more rooms after loadMore()', () async {
    // Start sync and wait for first cycle to establish baseline state.
    // loadMore() must be called while sync is running — calling it before
    // startSync() would have its ranges overwritten by _loadCachedPosition().
    unawaited(slidingSync.startSync());
    await slidingSync.statusStream.firstWhere(
      (s) => s == SlidingSyncStatus.finished,
    );

    final initialCount = slidingSync.list!.roomIds.length;

    if ((slidingSync.list!.totalRoomCount ?? initialCount) <= 5) {
      await slidingSync.stopSync();
      markTestSkipped('Account needs more than 5 rooms for this test');
      return;
    }

    // Extend the range while sync is running, then wait for the next cycle.
    slidingSync.list!.loadMore();
    await slidingSync.statusStream.firstWhere(
      (s) => s == SlidingSyncStatus.finished,
    );
    await slidingSync.stopSync();
    expect(slidingSync.list!.roomIds.length, greaterThan(initialCount));
  });

  test('statusStream emits expected transitions', () async {
    final statusesFuture = slidingSync.statusStream.take(3).toList();

    unawaited(slidingSync.startSync());
    final statuses = await statusesFuture;
    await slidingSync.stopSync();

    expect(
      statuses,
      equals([
        SlidingSyncStatus.waitingForResponse,
        SlidingSyncStatus.processing,
        SlidingSyncStatus.finished,
      ]),
    );
  });

  test('loadRoom throws StateError when sync is not running', () {
    expect(
      slidingSync.loadRoom('!nonexistent:matrix.example.com'),
      throwsA(isA<StateError>()),
    );
  });

  test('loadRoom returns already-initialized room immediately', () async {
    unawaited(slidingSync.startSync());
    await slidingSync.updateStream.first;
    final roomId = slidingSync.list!.roomIds.first;
    await slidingSync.stopSync();

    // Room is already in _initializedRooms — returns immediately even if
    // sync is stopped, without needing to wait for the server.
    final room = await slidingSync.loadRoom(roomId);
    expect(room.id, equals(roomId));
  });

  test('loadRoom subscribes and loads a room not yet in the list', () async {
    // Start sync and wait for the first cycle to complete so we know which
    // rooms are already loaded and have a valid pos token.
    unawaited(slidingSync.startSync());
    await slidingSync.statusStream.firstWhere(
      (s) => s == SlidingSyncStatus.finished,
    );

    // Ask the server for all joined rooms and find one not yet delivered by
    // the sliding sync list.
    final allJoinedRoomIds = await client.getJoinedRooms();
    final listRoomIds = slidingSync.list!.roomIds.toSet();
    final candidates = allJoinedRoomIds.where((id) => !listRoomIds.contains(id));

    if (candidates.isEmpty) {
      await slidingSync.stopSync();
      markTestSkipped('All joined rooms are already in the sliding sync list');
      return;
    }

    final unloadedRoomId = candidates.first;

    // loadRoom subscribes and waits for the server to deliver the room data
    // on the next sync cycle.
    final room = await slidingSync.loadRoom(
      unloadedRoomId,
      subscription: RoomSubscription(
        timelineLimit: 5,
        requiredState: RequiredStateRequest.minimal(),
      ),
    );
    await slidingSync.stopSync();

    expect(room.id, equals(unloadedRoomId));
  });
}
