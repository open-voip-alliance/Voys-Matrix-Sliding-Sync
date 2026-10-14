import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:voys_matrix_sliding_sync/voys_matrix_sliding_sync.dart';

/// A sliding sync request as seen by [_FakeServer].
class _SeenRequest {
  _SeenRequest(this.request, this.body);

  final http.BaseRequest request;
  final Map<String, dynamic> body;

  Map<String, String> get query => request.url.queryParameters;

  /// Whether the request was cancelled through its `abortTrigger`.
  bool aborted = false;

  /// Complete this to let a held (long-polling) request return.
  final release = Completer<void>();
}

/// Serves the sliding sync endpoint the way Synapse does: a request without
/// `pos` or without `timeout` returns at once, a long-poll (both present) is
/// held until the test releases it or the request is aborted. Everything
/// else goes to the SDK's [FakeMatrixApi].
class _FakeServer extends http.BaseClient {
  _FakeServer({this.honourAbort = true});

  /// Whether to act on `abortTrigger`, like the default `http.Client` does.
  /// `false` mimics a wrapper that copies requests before sending them,
  /// which loses the trigger.
  final bool honourAbort;

  final _inner = FakeMatrixApi();
  final requests = <_SeenRequest>[];
  var _posCounter = 0;

  /// Room payloads (keyed by room ID) returned on an initial sync, in this
  /// order.
  Map<String, Object?> initialRooms = {};

  /// When set, the initial sync's list carries a SYNC op with these room IDs
  /// in this order.
  List<String>? initialListRoomIds;

  /// How many of the next sliding sync requests fail with a 500.
  var failNextRequests = 0;

  /// Waits until at least [count] sliding sync requests have arrived.
  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void releaseAll() {
    for (final seen in requests) {
      if (!seen.release.isCompleted) seen.release.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!request.url.path.endsWith('simplified_msc3575/sync')) {
      return _inner.send(request);
    }

    final body =
        jsonDecode(await request.finalize().bytesToString())
            as Map<String, dynamic>;
    final seen = _SeenRequest(request, body);
    requests.add(seen);

    if (failNextRequests > 0) {
      failNextRequests--;
      return http.StreamedResponse(
        http.ByteStream.fromBytes(utf8.encode('upstream error')),
        500,
        request: request,
      );
    }

    if (seen.query.containsKey('pos') && seen.query.containsKey('timeout')) {
      final abortTrigger = switch (request) {
        http.Abortable(:final abortTrigger?) when honourAbort => abortTrigger,
        _ => null,
      };
      final aborted = await Future.any<bool>([
        seen.release.future.then((_) => false),
        if (abortTrigger != null) abortTrigger.then((_) => true),
      ]);
      if (aborted) {
        seen.aborted = true;
        throw http.RequestAbortedException(request.url);
      }
    }

    final isInitial = !seen.query.containsKey('pos');
    final listRoomIds = isInitial ? initialListRoomIds : null;
    final response = jsonEncode({
      'pos': 'pos${++_posCounter}',
      'lists': {
        'rooms': {
          'count': listRoomIds?.length ?? 0,
          'ops': [
            if (listRoomIds != null)
              {
                'op': 'SYNC',
                'range': [0, listRoomIds.length - 1],
                'room_ids': listRoomIds,
              },
          ],
        },
      },
      'rooms': isInitial ? initialRooms : <String, Object>{},
      'extensions': <String, Object>{},
    });
    return http.StreamedResponse(
      http.ByteStream.fromBytes(utf8.encode(response)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Rebuilds every request as a plain [http.Request] before forwarding it,
/// like http_interceptor's `InterceptedClient` does, which drops the
/// `abortTrigger` of an [http.AbortableRequest].
class _CopyingClient extends http.BaseClient {
  _CopyingClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return _inner.send(copy);
  }
}

Future<DatabaseApi> _createDatabase() async {
  sqfliteFfiInit();
  return MatrixSdkDatabase.init(
    'sync-loop-test.${DateTime.now().microsecondsSinceEpoch}',
    database: await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
  );
}

void main() {
  late _FakeServer server;
  late SlidingSyncOnlyClient client;
  late SlidingSync slidingSync;

  Future<void> setUpWith({
    bool honourAbort = true,
    Set<String>? previewEventTypes,
    http.Client Function(http.Client server)? wrapClient,
    Duration pollTimeout = const Duration(seconds: 30),
  }) async {
    server = _FakeServer(honourAbort: honourAbort);
    client = SlidingSyncOnlyClient(
      'sync-loop-test',
      database: await _createDatabase(),
      httpClient: wrapClient == null ? server : wrapClient(server),
    );
    await client.checkHomeserver(
      Uri.parse('https://fakeserver.notexisting'),
      checkWellKnown: false,
    );
    await client.init(
      newToken: 'abcd',
      newUserID: '@test:fakeserver.notexisting',
      newHomeserver: client.homeserver,
      newDeviceName: 'sync-loop-test',
      newDeviceID: 'SYNCLOOPTEST',
      waitForFirstSync: false,
      // Keep the default waitUntilLoadCompletedLoaded: otherwise the room list
      // finishes loading from the (empty) database after the first sync and
      // replaces the rooms that sync just added.
    );
    var builder = SlidingSync.builder(client: client)
        .withPollTimeout(pollTimeout)
        .addList(
          SlidingSyncList(
            syncMode: SyncMode.growing,
            timelineLimit: 0,
            requiredState: RequiredStateRequest.minimal(),
            batchSize: 5,
          ),
        );
    if (previewEventTypes != null) {
      builder = builder.withPreviewEventTypes(previewEventTypes);
    }
    slidingSync = builder.build();
  }

  tearDown(() async {
    server.releaseAll();
    await slidingSync.dispose();
    await client.dispose();
  });

  test('sends pos and timeout as query parameters, not in the body', () async {
    await setUpWith();
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);

    // An initial sync is answered at once whatever the timeout, so none is
    // sent.
    final initial = server.requests[0];
    expect(initial.query, isNot(contains('pos')));
    expect(initial.query, isNot(contains('timeout')));
    expect(initial.body, isNot(contains('pos')));
    expect(initial.body, isNot(contains('timeout')));

    // The second request carries the position handed out by the first
    // response, so the server treats it as incremental and long-polls.
    final incremental = server.requests[1];
    expect(incremental.query['pos'], 'pos1');
    expect(incremental.query['timeout'], '30000');
    expect(incremental.body, isNot(contains('pos')));
    expect(incremental.body, isNot(contains('timeout')));
  });

  test(
    'wakeSyncLoop aborts the long-poll and resends with the same pos',
    () async {
      await setUpWith();
      unawaited(slidingSync.startSync());
      await server.waitForRequests(2);
      final held = server.requests[1];

      const roomId = '!room:fakeserver.notexisting';
      slidingSync.subscribeToRooms({
        roomId: RoomSubscription(
          timelineLimit: 5,
          requiredState: RequiredStateRequest.minimal(),
        ),
      });
      await server.waitForRequests(3);

      expect(held.aborted, isTrue);
      final resent = server.requests[2];
      expect(resent.query['pos'], held.query['pos']);
      expect(resent.query, isNot(contains('timeout')));
      expect(resent.body['room_subscriptions'], contains(roomId));
    },
  );

  test(
    'a list config change is answered at once, then long-polling resumes',
    () async {
      await setUpWith();
      unawaited(slidingSync.startSync());
      await server.waitForRequests(2);
      final held = server.requests[1];

      // Synapse only cuts a long-poll short for room or extension updates,
      // never for list changes, so the request carrying the new filter must
      // not ask the server to wait.
      slidingSync.list!.setFilters(
        SlidingRoomFilter(notRoomTypes: ['m.space']),
      );
      await server.waitForRequests(4);

      expect(held.aborted, isTrue);
      final withFilter = server.requests[2];
      expect(withFilter.query['pos'], held.query['pos']);
      expect(withFilter.query, isNot(contains('timeout')));
      final lists = withFilter.body['lists'] as Map<String, dynamic>;
      final rooms = lists['rooms'] as Map<String, dynamic>;
      expect(rooms['filters'], containsPair('not_room_types', ['m.space']));

      // Once that is answered the loop goes back to long-polling.
      final next = server.requests[3];
      expect(next.query['pos'], 'pos2');
      expect(next.query['timeout'], '30000');
    },
  );

  test('a client that ignores abortTrigger still moves on at once', () async {
    await setUpWith(honourAbort: false);
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    final held = server.requests[1];

    // The wake sends an immediate request (answered with pos2) while the
    // old long-poll is still open; the loop then long-polls from pos2.
    slidingSync.wakeSyncLoop();
    await server.waitForRequests(4);
    expect(held.aborted, isFalse);
    expect(held.release.isCompleted, isFalse);
    expect(server.requests[2].query['pos'], held.query['pos']);
    expect(server.requests[2].query, isNot(contains('timeout')));
    expect(server.requests[3].query['pos'], 'pos2');

    // The abandoned request's late response (pos3) is discarded: it neither
    // triggers a new request nor moves the position forward.
    held.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.requests, hasLength(4));

    server.requests[3].release.complete();
    await server.waitForRequests(5);
    expect(server.requests[4].query['pos'], 'pos4');
  });

  test('persists unread counts so they survive a restart', () async {
    await setUpWith();
    const roomId = '!unread:fakeserver.notexisting';
    server.initialRooms = {
      roomId: {
        'name': 'Unread room',
        'initial': true,
        'joined_count': 2,
        'notification_count': 3,
        'highlight_count': 1,
        'required_state': <Object>[],
        'timeline': <Object>[],
      },
    };
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);

    expect(client.getRoomById(roomId)?.notificationCount, 3);
    expect(client.getRoomById(roomId)?.highlightCount, 1);

    // A restart resumes from the cached `pos`, so the server only sends rooms
    // that changed since; the counts must come from the database.
    final stored = await client.database.getSingleRoom(client, roomId);
    expect(stored?.notificationCount, 3);
    expect(stored?.highlightCount, 1);
  });

  test('a read receipt clears the unread counts and polls', () async {
    await setUpWith();
    // FakeMatrixApi stubs /read_markers for this room ID.
    const roomId = '!1234:example.com';
    server.initialRooms = {
      roomId: {
        'name': 'Read room',
        'initial': true,
        'joined_count': 2,
        'notification_count': 3,
        'highlight_count': 1,
        'required_state': <Object>[],
        'timeline': <Object>[],
      },
    };
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    expect(client.getRoomById(roomId)?.notificationCount, 3);

    final badgeUpdate = slidingSync.updateStream.firstWhere(
      (update) => update.rooms.containsKey(roomId),
    );
    await client.setReadMarker(
      roomId,
      mFullyRead: r'$event:example.com',
      mRead: r'$event:example.com',
    );

    expect(client.getRoomById(roomId)?.notificationCount, 0);
    expect(client.getRoomById(roomId)?.highlightCount, 0);
    final stored = await client.database.getSingleRoom(client, roomId);
    expect(stored?.notificationCount, 0);
    expect(stored?.highlightCount, 0);

    final update = await badgeUpdate.timeout(const Duration(seconds: 5));
    expect(update.rooms[roomId]!.roomData.notificationCount, 0);

    // The receipt changes the server-side `unread` filter, which never cuts
    // a long-poll short, so the loop polls right away.
    await server.waitForRequests(3);
    expect(server.requests[2].query, isNot(contains('timeout')));
  });

  test('persists its own previewable lastEvent, not the SDK pick', () async {
    // The SDK's handleSync only considers `client.roomPreviewLastEvents`
    // (here: the default, without co.voys.note) for lastEvent and persists
    // that; the stored lastEvent decides the room order after a restart.
    await setUpWith(previewEventTypes: {EventTypes.Message, 'co.voys.note'});
    const roomId = '!preview:fakeserver.notexisting';
    Map<String, Object?> event(String type, String id, int ts) => {
      'type': type,
      'event_id': id,
      'sender': '@alice:fakeserver.notexisting',
      'origin_server_ts': ts,
      'room_id': roomId,
      'content': {'body': '$type $id'},
    };
    server.initialRooms = {
      roomId: {
        'name': 'Preview room',
        'initial': true,
        'joined_count': 2,
        'required_state': <Object>[],
        'timeline': [
          event('co.voys.note', r'$note', 2000),
          event(EventTypes.Message, r'$message', 1000),
        ],
      },
    };
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);

    expect(client.getRoomById(roomId)?.lastEvent?.eventId, r'$note');
    final stored = await client.database.getSingleRoom(client, roomId);
    expect(stored?.lastEvent?.eventId, r'$note');
  });

  test(
    'AbortPreservingClient carries the abort through a copying wrapper',
    () async {
      await setUpWith(
        wrapClient: (server) =>
            AbortPreservingClient(_CopyingClient.new, inner: server),
      );
      unawaited(slidingSync.startSync());
      await server.waitForRequests(2);
      final held = server.requests[1];
      expect(held.request, isA<http.Abortable>());
      expect(held.request.headers, isNot(contains('x-voys-abort-id')));

      slidingSync.wakeSyncLoop();
      await server.waitForRequests(3);

      expect(held.aborted, isTrue);
      expect(server.requests[2].query['pos'], held.query['pos']);
    },
  );

  test('abandons a long-poll the server never answers', () async {
    // A connection dropped while the app was in the background (NAT timeout)
    // produces no error, so the loop must give up on its own, a little after
    // the server would have answered.
    await setUpWith(pollTimeout: const Duration(milliseconds: 300));
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    final held = server.requests[1];
    expect(held.query['timeout'], '300');

    await server.waitForRequests(3).timeout(const Duration(seconds: 3));

    expect(held.aborted, isTrue);
    // Not a config change, so the next request long-polls again.
    expect(server.requests[2].query['pos'], held.query['pos']);
    expect(server.requests[2].query['timeout'], '300');
  });

  test('addList sends the new list on the next request', () async {
    await setUpWith();
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    expect(server.requests[1].body['lists'], isNot(contains('extra')));

    slidingSync.addList(
      SlidingSyncList(
        name: 'extra',
        syncMode: SyncMode.growing,
        timelineLimit: 0,
        requiredState: RequiredStateRequest.minimal(),
        batchSize: 5,
      ),
    );
    await server.waitForRequests(3);

    final lists = server.requests[2].body['lists'] as Map<String, dynamic>;
    expect(lists.keys, containsAll(['rooms', 'extra']));
    expect(server.requests[2].query, isNot(contains('timeout')));
    expect(slidingSync.getList('extra'), isNotNull);
  });

  test('persists required state for a room without timeline events', () async {
    await setUpWith();
    const roomId = '!stateonly:fakeserver.notexisting';
    const userId = '@test:fakeserver.notexisting';
    server.initialRooms = {
      roomId: {
        'name': 'State only',
        'initial': true,
        'joined_count': 1,
        'required_state': [
          {
            'type': 'm.room.member',
            'state_key': userId,
            'sender': userId,
            'event_id': r'$me',
            'origin_server_ts': 1000,
            'room_id': roomId,
            'content': {'membership': 'join'},
          },
          {
            'type': 'm.room.topic',
            'state_key': '',
            'sender': userId,
            'event_id': r'$topic',
            'origin_server_ts': 1000,
            'room_id': roomId,
            'content': {'topic': 'Stored'},
          },
        ],
        'timeline': <Object>[],
      },
    };
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);

    // The in-memory room has it; a restart only has what was stored. The
    // SDK keeps member events apart from other state.
    final stored = await client.database.getSingleRoom(client, roomId);
    await stored!.postLoad();
    expect(stored.getState('m.room.topic')?.content['topic'], 'Stored');
    expect(await client.database.getUser(userId, stored), isNotNull);
    expect(stored.lastEvent, isNull);
  });

  test('processes rooms in list order, not response order', () async {
    await setUpWith();
    const userId = '@test:fakeserver.notexisting';
    Map<String, Object?> room(String id, int ts) => {
      'name': id,
      'initial': true,
      'joined_count': 1,
      'required_state': <Object>[],
      'timeline': [
        {
          'type': EventTypes.Message,
          'event_id': '\$msg$id',
          'sender': userId,
          'origin_server_ts': ts,
          'room_id': id,
          'content': {'body': 'hi'},
        },
      ],
    };
    // The server emits rooms in completion order; the list says A, B, C.
    server
      ..initialRooms = {
        '!c:x': room('!c:x', 3),
        '!a:x': room('!a:x', 1),
        '!b:x': room('!b:x', 2),
      }
      ..initialListRoomIds = ['!a:x', '!b:x', '!c:x'];

    // handleSync fires onSync once per processed room.
    final processed = <String>[];
    final subscription = client.onSync.stream.listen(
      (update) => processed.addAll(update.rooms?.join?.keys ?? const []),
    );
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    await subscription.cancel();

    expect(processed, ['!a:x', '!b:x', '!c:x']);
  });

  test(
    'retries a failed immediate request immediately, not as a long-poll',
    () async {
      await setUpWith();
      unawaited(slidingSync.startSync());
      await server.waitForRequests(2);
      final held = server.requests[1];

      // The request carrying a config change fails (network blip). Were the
      // retry a long-poll, the server would hold a list-only change for the
      // full poll timeout.
      server.failNextRequests = 1;
      slidingSync.wakeSyncLoop();
      await server.waitForRequests(3);
      expect(server.requests[2].query, isNot(contains('timeout')));

      await server.waitForRequests(4).timeout(const Duration(seconds: 10));
      final retry = server.requests[3];
      expect(retry.query['pos'], held.query['pos']);
      expect(retry.query, isNot(contains('timeout')));
    },
  );

  test('processes room subscriptions after every listed room', () async {
    await setUpWith();
    const userId = '@test:fakeserver.notexisting';
    Map<String, Object?> room(String id) => {
      'name': id,
      'initial': true,
      'joined_count': 1,
      'required_state': <Object>[],
      'timeline': [
        {
          'type': EventTypes.Message,
          'event_id': '\$msg$id',
          'sender': userId,
          'origin_server_ts': 1,
          'room_id': id,
          'content': {'body': 'hi'},
        },
      ],
    };
    // Only the last listed room and a room outside the list have data; the
    // response is smaller than that room's list index.
    server
      ..initialListRoomIds = [
        for (var i = 0; i < 5; i++) '!r$i:x',
        '!listed:x',
      ]
      ..initialRooms = {
        '!sub:x': room('!sub:x'),
        '!listed:x': room('!listed:x'),
      };

    final processed = <String>[];
    final subscription = client.onSync.stream.listen(
      (update) => processed.addAll(update.rooms?.join?.keys ?? const []),
    );
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    await subscription.cancel();

    expect(processed, ['!listed:x', '!sub:x']);
  });

  test('stopSync returns promptly while the server is long-polling', () async {
    await setUpWith();
    unawaited(slidingSync.startSync());
    await server.waitForRequests(2);
    final held = server.requests[1];

    await slidingSync.stopSync().timeout(const Duration(seconds: 5));

    expect(held.aborted, isTrue);
    expect(slidingSync.isSyncing, isFalse);
    expect(server.requests, hasLength(2));
  });

  test('legacy sync loop stays off after logging out and in again', () async {
    await setUpWith();
    await client.logout();
    await client.init(
      newToken: 'abcd',
      // The casing FakeMatrixApi serves the sync filter for; with any other
      // user the sync fails and the loop backs off instead of spinning.
      newUserID: '@test:fakeServer.notExisting',
      newHomeserver: Uri.parse('https://fakeserver.notexisting'),
      newDeviceName: 'sync-loop-test',
      newDeviceID: 'SYNCLOOPTEST',
    );

    // init() awaits a single sync. A running background loop would repeat it
    // without pause, since SlidingSyncOnlyClient.sync returns at once.
    var finishedSyncs = 0;
    final subscription = client.onSyncStatus.stream
        .where((update) => update.status == SyncStatus.finished)
        .listen((_) => finishedSyncs++);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await subscription.cancel();

    expect(finishedSyncs, 0);
  });
}
