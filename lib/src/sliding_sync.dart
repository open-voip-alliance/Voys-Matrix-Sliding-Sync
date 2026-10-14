import 'dart:async';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:voys_matrix_sliding_sync/src/api_extensions.dart';
import 'package:voys_matrix_sliding_sync/src/models/request.dart';
import 'package:voys_matrix_sliding_sync/src/models/required_state.dart';
import 'package:voys_matrix_sliding_sync/src/models/response.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_list.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_only_client.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_update.dart';
import 'package:voys_matrix_sliding_sync/src/sync_mode.dart';

const _connId = 'sliding_sync';

/// Main sliding sync controller
class SlidingSync {
  SlidingSync({
    required this.client,
    SlidingSyncExtensions? extensions,
    this.previewEventTypes,
    this.pollTimeout = const Duration(seconds: 30),
  }) : _extensions = extensions ?? SlidingSyncExtensions.essential() {
    // Wake the poll loop after any write that could affect list membership
    // or ordering, regardless of which call site triggered it.
    final client = this.client;
    if (client is SlidingSyncOnlyClient) {
      client
        ..onRoomMutation = wakeSyncLoop
        ..onReadReceipt = _markRoomRead;
    }
  }

  /// The client instance
  final Client client;

  final Set<String>? previewEventTypes;

  /// How long the server may hold an incremental request waiting for new
  /// data (the `timeout` query parameter).
  final Duration pollTimeout;

  /// How long to wait for a long-poll before abandoning it. The server
  /// answers within [pollTimeout], so well past that the connection was most
  /// likely dropped silently (e.g. a NAT timeout while the app was in the
  /// background), which never surfaces as an error on its own.
  Duration get _pollDeadline => pollTimeout + pollTimeout ~/ 3;

  /// The per-list state cached by the previous session, kept so a list
  /// registered after startup via [addList] is preloaded from it too.
  Map<String, dynamic>? _cachedListsState;

  /// Back-off after a failed request.
  static const _errorBackOff = Duration(seconds: 3);

  /// See the busy-loop guard in [_syncLoop].
  static const _busyLoopGuard = Duration(seconds: 1);

  /// Current position token
  String? _pos;

  /// Named lists
  final Map<String, SlidingSyncList> _lists = {};

  /// Extensions configuration
  final SlidingSyncExtensions _extensions;

  /// Whether sync is currently running
  bool _isSyncing = false;

  /// Whether we've emitted the first sync response
  bool _hasEmittedFirstUpdate = false;

  /// Stream controller for sync updates
  final StreamController<SlidingSyncUpdate> _updateController =
      StreamController<SlidingSyncUpdate>.broadcast();

  /// Stream controller for sync status
  final StreamController<SlidingSyncStatus> _statusController =
      StreamController<SlidingSyncStatus>.broadcast();

  /// Completer for stop signal
  Completer<void>? _stopCompleter;

  /// Current sync future
  Future<void>? _currentSync;

  /// Active room subscriptions — sent in every request (MSC4186 has no server-side stickiness)
  final Map<String, RoomSubscription> _activeRoomSubscriptions = {};

  /// Track which rooms we've already initialized to ignore repeated initial=true
  final Set<String> _initializedRooms = {};

  /// Track latest event ID per room to detect new messages
  final Map<String, String> _latestEventIds = {};

  /// Track last known highlight/notification counts per room to detect
  /// real changes — the server may echo these on every response even
  /// when the value hasn't changed.
  final Map<String, int> _highlightCounts = {};
  final Map<String, int> _notificationCounts = {};

  /// Track which events we've already emitted to avoid duplicates
  final Set<String> _emittedEventIds = {};

  /// To-device batch token — echoed back to the server as `extensions.to_device.since`
  String? _toDeviceSince;

  /// Completed by [wakeSyncLoop] to abandon the in-flight long-poll or cut a
  /// back-off short (see [_syncLoop]). Reset at the top of every loop
  /// iteration.
  Completer<void> _wakeSignal = Completer<void>();

  /// Set by [wakeSyncLoop] and consumed by the next request, which is then
  /// sent without a `timeout` so the server answers at once.
  ///
  /// Synapse only returns a long-poll early for new room data or extension
  /// updates, never for list changes (`SlidingSyncResult.__bool__` ignores
  /// `lists`). A request built after a config change (filter, ranges,
  /// subscription) whose rooms were all sent on this connection before would
  /// otherwise be held for the full [pollTimeout]. Same idea as the Rust
  /// SDK's `PollTimeout::None` while its lists are loading.
  bool _wantImmediateResponse = true;

  /// Creates a builder for configuring sliding sync
  static SlidingSyncBuilder builder({required Client client}) {
    return SlidingSyncBuilder(client: client);
  }

  /// Stream of sync updates
  Stream<SlidingSyncUpdate> get updateStream => _updateController.stream;

  /// Stream of sync status
  Stream<SlidingSyncStatus> get statusStream => _statusController.stream;

  /// Current position token
  String? get pos => _pos;

  /// Whether sync is currently running
  bool get isSyncing => _isSyncing;

  /// The default-named sync list ([SlidingSyncList.defaultName]).
  ///
  /// Convenience accessor for the single-list configuration. For multi-list
  /// configurations, use [getList] with the list's explicit name.
  SlidingSyncList? get list => _lists[SlidingSyncList.defaultName];

  /// All configured lists, keyed by name.
  Map<String, SlidingSyncList> get lists => Map.unmodifiable(_lists);

  /// Returns the list with the given [name], or `null` if none is configured.
  SlidingSyncList? getList(String name) => _lists[name];

  void _addList(SlidingSyncList list) {
    _lists[list.name]?.dispose();
    list.onConfigChanged = wakeSyncLoop;
    _lists[list.name] = list;
  }

  /// Registers [list] after [SlidingSyncBuilder.build], typically while
  /// syncing, replacing any list with the same name. The next request
  /// includes it; if the previous session cached its rooms they are shown
  /// right away, as for lists registered up front.
  ///
  /// Lets an app request the list behind its visible tab first and the rest
  /// once that has arrived, instead of waiting for one response that carries
  /// them all.
  void addList(SlidingSyncList list) {
    _addList(list);
    final cached = _cachedListsState?[list.name];
    if (cached is Map) {
      _preloadList(list, cached.cast<String, dynamic>());
    }
    wakeSyncLoop();
  }

  /// Subscribes to specific rooms
  void subscribeToRooms(Map<String, RoomSubscription> subscriptions) {
    _activeRoomSubscriptions.addAll(subscriptions);
    // Evict these rooms from the seen-rooms tracking so that the server's
    // upcoming initial=true response (with the subscription's higher
    // timelineLimit / full required state) is processed and cached.
    for (final roomId in subscriptions.keys) {
      _initializedRooms.remove(roomId);
      _latestEventIds.remove(roomId);
    }
    wakeSyncLoop();
  }

  /// Unsubscribes from specific rooms
  void unsubscribeFromRooms(List<String> roomIds) {
    for (final roomId in roomIds) {
      _activeRoomSubscriptions.remove(roomId);
    }
    wakeSyncLoop();
  }

  /// Wakes the sync loop so the next request goes out right away, built from
  /// the current configuration and answered by the server immediately rather
  /// than long-polled. If the server is holding our request as a long-poll,
  /// that request is abandoned (and aborted, where the client's `httpClient`
  /// supports it) and re-sent with the same `pos`; if the loop is backing
  /// off after an error, the back-off is cut short. [SlidingSyncList]'s
  /// config setters already call this themselves via `onConfigChanged`; this
  /// is exposed for other cases where a caller wants to force an immediate
  /// poll (e.g. a pull-to-refresh gesture).
  void wakeSyncLoop() {
    _wantImmediateResponse = true;
    if (!_wakeSignal.isCompleted) {
      _wakeSignal.complete();
    }
  }

  /// Clears [roomId]'s unread counts after the user sent a read receipt for
  /// it, persists that, emits a room update so UIs drop the badge, and polls
  /// so `unread`-filtered lists catch up.
  ///
  /// Optimistic: the server only re-sends a room (and so its counts) along
  /// with new events or state in it, so without this a badge would stay
  /// until the room's next activity. The server's counts win whenever the
  /// room is next sent down.
  Future<void> _markRoomRead(String roomId) async {
    wakeSyncLoop();

    final room = client.getRoomById(roomId);
    if (room == null ||
        (room.notificationCount == 0 && room.highlightCount == 0)) {
      return;
    }

    room
      ..notificationCount = 0
      ..highlightCount = 0;
    _notificationCounts[roomId] = 0;
    _highlightCounts[roomId] = 0;
    await client.database.storeRoomUpdate(
      roomId,
      JoinedRoomUpdate(
        unreadNotifications: UnreadNotificationCounts(
          notificationCount: 0,
          highlightCount: 0,
        ),
      ),
      room.lastEvent,
      client,
    );

    if (!_updateController.isClosed) {
      _updateController.add(
        SlidingSyncUpdate(
          pos: _pos ?? '',
          lists: {},
          rooms: {
            roomId: SlidingSyncRoomUpdate(
              roomId: roomId,
              roomData: SlidingSyncRoomData(
                notificationCount: 0,
                highlightCount: 0,
              ),
            ),
          },
        ),
      );
    }
  }

  /// Loads a specific room by ID, subscribing to it if not already initialized.
  ///
  /// If the room has already been initialized via sliding sync, returns it
  /// immediately. Otherwise, adds a room subscription and waits for the sync
  /// cycle carrying it to complete. The server sends everything for a room
  /// new to this connection, only the extra state or timeline for one it
  /// already sent as part of a list, and nothing at all if [subscription]
  /// asks for no more than the list did; in every case the room is in the
  /// client once that cycle has been processed.
  ///
  /// [subscription] controls the timeline limit and required state requested
  /// from the server. Defaults to a 5-event timeline and minimal state.
  ///
  /// Throws [TimeoutException] if the cycle does not complete within
  /// [timeout]. Throws [StateError] if the sync loop is not running, or if
  /// the server did not deliver the room.
  Future<Room> loadRoom(
    String roomId, {
    RoomSubscription? subscription,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final existing = client.getRoomById(roomId);
    if (existing != null && _initializedRooms.contains(roomId)) {
      return existing;
    }

    if (!_isSyncing) {
      throw StateError('Cannot load room: sync loop is not running');
    }

    // The cycle to wait for is the first request sent after subscribing
    // (subscribeToRooms wakes the loop), not one that may be mid-flight now.
    var seenNewRequest = false;
    final nextCycle = statusStream.firstWhere((status) {
      if (status == SlidingSyncStatus.waitingForResponse) seenNewRequest = true;
      return seenNewRequest && status == SlidingSyncStatus.finished;
    });

    subscribeToRooms({
      roomId:
          subscription ??
          RoomSubscription(
            timelineLimit: 5,
            requiredState: RequiredStateRequest.minimal(),
          ),
    });

    await nextCycle.timeout(timeout);

    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Room $roomId not found after subscription');
    }
    _initializedRooms.add(roomId);
    return room;
  }

  /// Starts the sync loop
  Future<void> startSync() async {
    if (_isSyncing) {
      return;
    }

    Logs().i('[SlidingSync] Starting sync loop (id: $_connId)');
    _isSyncing = true;
    _stopCompleter = null;
    // Resuming from a cached position should show what changed right away.
    _wantImmediateResponse = true;

    try {
      // Load cached position if available
      await _loadCachedPosition();

      // Emit initial update with cached rooms if available
      // Ensure rooms are loaded from database first
      final hasListsWithRooms = _lists.values.any(
        (list) => list.roomIds.isNotEmpty,
      );
      if (hasListsWithRooms && !_hasEmittedFirstUpdate) {
        // Collect all unique room IDs from all lists
        final allRoomIds = <String>{};
        for (final list in _lists.values) {
          allRoomIds.addAll(list.roomIds.where((id) => id.isNotEmpty));
        }

        // Make sure every cached room is in `client.rooms` so the UI can
        // render it immediately. Prefer the stored room, which carries the
        // `lastEvent` the list is sorted on; fall back to an empty room with
        // a null lastEvent, which shows "No messages" rather than the SDK's
        // "Refreshing..." placeholder.
        for (final roomId in allRoomIds) {
          var room = client.getRoomById(roomId);
          if (room == null) {
            room =
                await client.database.getSingleRoom(client, roomId) ??
                (Room(id: roomId, client: client)..lastEvent = null);
            client.rooms.add(room);
          }

          // Restore latest event ID to prevent re-processing events after restart
          if (room.lastEvent?.eventId != null) {
            _latestEventIds[roomId] = room.lastEvent!.eventId;
          }
        }

        final listUpdates = <String, SlidingSyncListUpdate>{};
        for (final entry in _lists.entries) {
          if (entry.value.roomIds.isNotEmpty) {
            listUpdates[entry.key] = SlidingSyncListUpdate(
              count: entry.value.totalRoomCount,
              ops: [], // No operations, just showing cached state
            );
          }
        }

        if (listUpdates.isNotEmpty && !_updateController.isClosed) {
          _updateController.add(
            SlidingSyncUpdate(
              pos: _pos ?? '', // Use empty string if no position yet
              lists: listUpdates,
              rooms: {}, // Rooms are already loaded by Client
            ),
          );
          _hasEmittedFirstUpdate = true;
        }
      }

      // Start the sync loop
      _currentSync = _syncLoop();
      await _currentSync;
    } finally {
      _isSyncing = false;
      _currentSync = null;
      _updateStatus(SlidingSyncStatus.stopped);
    }
  }

  /// Stops the sync loop
  Future<void> stopSync() async {
    if (!_isSyncing) {
      return;
    }

    Logs().i('[SlidingSync] Stopping sync loop (id: $_connId)');
    _stopCompleter = Completer<void>();
    // Abandon an in-flight long-poll (or cut a back-off short) so the loop
    // notices the stop now rather than after up to [pollTimeout].
    wakeSyncLoop();
    await _stopCompleter!.future;
    _stopCompleter = null;
    _hasEmittedFirstUpdate = false;
    Logs().i('[SlidingSync] Sync loop stopped (id: $_connId)');
  }

  Future<void> _expireSession() async {
    _pos = null;
    await _saveCachedPosition();

    for (final list in _lists.values) {
      list.reset();
    }
  }

  /// The main sync loop.
  ///
  /// Each iteration sends one request. An initial request (no `pos`) returns
  /// as soon as the server has built the response; an incremental one is
  /// held by the server for up to [pollTimeout] until something changes, so
  /// there is no client-side polling interval. [wakeSyncLoop] abandons the
  /// held request so a config change goes out immediately, and that next
  /// request is answered immediately too (see [_wantImmediateResponse]).
  Future<void> _syncLoop() async {
    while (_isSyncing && _stopCompleter == null) {
      _wakeSignal = Completer<void>();
      try {
        _updateStatus(SlidingSyncStatus.waitingForResponse);
        final requestGenerations = {
          for (final entry in _lists.entries) entry.key: entry.value.generation,
        };
        final longPoll = _pos != null && !_wantImmediateResponse;
        _wantImmediateResponse = false;
        final requestStart = DateTime.now();
        final response = await _sendRequest(longPoll: longPoll);
        if (response == null) {
          // Woken or stopped while the server was long-polling: the request
          // was abandoned. Go round again to send a fresh one built from the
          // current config (or exit if a stop was requested).
          continue;
        }
        _updateStatus(SlidingSyncStatus.processing);
        final update = await _processResponse(response, requestGenerations);
        _updateStatus(SlidingSyncStatus.finished);

        // Only emit update if something actually changed, or if this is the first update
        final hasListChanges = update.lists.values.any(
          (list) => list.ops != null && list.ops!.isNotEmpty,
        );
        final hasChanges =
            !_hasEmittedFirstUpdate ||
            update.rooms.isNotEmpty ||
            hasListChanges;

        if (hasChanges && !_updateController.isClosed) {
          _updateController.add(update);
          _hasEmittedFirstUpdate = true;
        }

        // Busy-loop guard: a long-poll with nothing new should have been held
        // by the server for up to [pollTimeout]. If it came straight back
        // anyway, pause briefly so a server that doesn't honour `timeout`
        // can't make us spin. Never hit with Synapse.
        final elapsed = DateTime.now().difference(requestStart);
        if (longPoll && !hasChanges && elapsed < _busyLoopGuard) {
          await _pause(_busyLoopGuard - elapsed);
        }
      } on MatrixException catch (e) {
        _updateStatus(SlidingSyncStatus.error);
        Logs().e(
          '[SlidingSync] Matrix error in sync loop: ${e.errcode} - ${e.error}',
        );
        if (e.errcode == 'M_UNKNOWN_POS') {
          // Position expired, reset and continue
          await _expireSession();
          continue;
        }

        // For other Matrix errors, wait before retrying
        await _retryAfterError();
      } catch (e, stackTrace) {
        _updateStatus(SlidingSyncStatus.error);
        Logs().e('[SlidingSync] Error in sync loop: $e');
        Logs().e('[SlidingSync] Stack trace: $stackTrace');
        // For network errors, wait before retrying
        await _retryAfterError();
      }
    }

    // Acknowledge a pending stopSync(). Done after the loop rather than
    // inside it so a stop requested before the first iteration, or while a
    // request was being abandoned, is still acknowledged.
    _stopCompleter?.complete();
  }

  /// Sends one sync request and returns the parsed response, or `null` if
  /// the request was abandoned because [wakeSyncLoop] (or [stopSync]) fired
  /// while the server was long-polling.
  ///
  /// With [longPoll] the server may hold the request for up to
  /// [pollTimeout]; without it the request carries no `timeout` and the
  /// server answers at once (also the case for an initial sync, which
  /// returns as soon as the server has built the response regardless).
  Future<SlidingSyncResponse?> _sendRequest({required bool longPoll}) async {
    if (!longPoll) {
      // An immediate request returns as soon as the server has built the
      // (potentially large) response, so let it finish rather than throw
      // that work away; the next request picks up any config change anyway.
      return SlidingSyncResponse.fromJson(
        await client.slidingSync(_buildRequest().toJson(), pos: _pos),
      );
    }

    // A long-poll is abandoned when the loop is woken, or when the server
    // has not answered by [_pollDeadline].
    final abandon = Completer<void>();
    void abandonNow() {
      if (!abandon.isCompleted) abandon.complete();
    }

    unawaited(_wakeSignal.future.then((_) => abandonNow()));
    final deadline = Timer(_pollDeadline, () {
      Logs().w(
        '[SlidingSync] No response within $_pollDeadline, abandoning the '
        'long-poll',
      );
      abandonNow();
    });

    try {
      final request = client.slidingSync(
        _buildRequest().toJson(),
        pos: _pos,
        timeout: pollTimeout.inMilliseconds,
        abortTrigger: abandon.future,
      );
      // Race the request against abandonment. With an `httpClient` that
      // honours the abort trigger the request fails right after it; with one
      // that doesn't (e.g. a wrapper that copies the request before sending)
      // it keeps running and its eventual response is discarded here. Either
      // way the loop moves on immediately. Re-sending with the same `pos` is
      // safe: the server drops any newer connection position it handed out
      // for the abandoned request.
      final json = await Future.any<Map<String, Object?>?>([
        request,
        abandon.future.then((_) => null),
      ]);
      return json == null ? null : SlidingSyncResponse.fromJson(json);
    } finally {
      deadline.cancel();
    }
  }

  /// Backs off after a failed request. The retry is answered immediately:
  /// the failed request may have been the one carrying a config change
  /// (which the server never answers a long-poll early for), and after an
  /// outage an immediate answer shows what changed meanwhile right away.
  Future<void> _retryAfterError() async {
    _wantImmediateResponse = true;
    await _pause(_errorBackOff);
  }

  /// Waits for [duration], or less if [wakeSyncLoop] fires first.
  Future<void> _pause(Duration duration) =>
      Future.any([Future<void>.delayed(duration), _wakeSignal.future]);

  /// Builds the sync request body. `pos` and `timeout` are query parameters
  /// and are passed to `slidingSync()` separately.
  SlidingSyncRequest _buildRequest() {
    if (_activeRoomSubscriptions.isNotEmpty) {
      Logs().d(
        '[SlidingSync] Including ${_activeRoomSubscriptions.length} room subscriptions: ${_activeRoomSubscriptions.keys.join(", ")}',
      );
    }

    return SlidingSyncRequest(
      connId: _connId,
      setPresence: client.syncPresence?.toString().split('.').last,
      lists: _lists,
      roomSubscriptions: _activeRoomSubscriptions.isNotEmpty
          ? Map.unmodifiable(_activeRoomSubscriptions)
          : null,
      extensions: _extensions,
      toDeviceSince: _toDeviceSince,
    );
  }

  /// Processes a sync response
  Future<SlidingSyncUpdate> _processResponse(
    SlidingSyncResponse response,
    Map<String, int> requestGenerations,
  ) async {
    // Update position
    _pos = response.pos;

    // Process list updates
    final listUpdates = <String, SlidingSyncListUpdate>{};
    if (response.lists != null) {
      for (final entry in response.lists!.entries) {
        final listName = entry.key;
        final listResponse = entry.value;
        final list = _lists[listName];

        // Drop responses for a list that has been reset since this
        // response's request was built -- they describe a room set/ranges
        // that no longer apply (e.g. the previous filter's rooms) and would
        // otherwise flash stale data onto the freshly reset list.
        final requestGeneration = requestGenerations[listName];
        final isStale =
            list != null &&
            requestGeneration != null &&
            requestGeneration != list.generation;

        if (list != null && !isStale) {
          // Process all operation types and track if anything actually changed
          var hasActualChanges = false;
          if (listResponse.ops != null) {
            for (final op in listResponse.ops!) {
              switch (op.op) {
                case 'SYNC':
                  if (op.range != null && op.roomIds != null) {
                    final changed = list.applySyncOp(op.range!, op.roomIds!);
                    hasActualChanges = hasActualChanges || changed;
                  }
                case 'INSERT':
                  if (op.index != null && op.roomId != null) {
                    list.applyInsertOp(op.index!, op.roomId!);
                    hasActualChanges = true; // INSERT always means change
                  }
                case 'DELETE':
                  if (op.index != null) {
                    list.applyDeleteOp(op.index!);
                    hasActualChanges = true; // DELETE always means change
                  }
                case 'INVALIDATE':
                  if (op.range != null) {
                    list.applyInvalidateOp(op.range!);
                    hasActualChanges = true; // INVALIDATE always means change
                  }
              }
            }
          }

          // Apply the authoritative count from the server after ops are done.
          // A filter matching zero rooms produces no op/room-ID changes above,
          // but the count moving the list out of `notLoaded` is itself a
          // change callers need to see -- otherwise the UI never learns the
          // list finished loading with zero results.
          final countChanged = list.applyServerCount(listResponse.count);

          // Only add to updates if operations actually changed something
          if (hasActualChanges || countChanged) {
            listUpdates[listName] = SlidingSyncListUpdate(
              count: listResponse.count,
              ops: listResponse.ops,
            );
          }
        }
      }
    }

    // Process room updates
    final roomUpdates = <String, SlidingSyncRoomUpdate>{};
    if (response.rooms != null) {
      Logs().d(
        '[SlidingSync] Processing ${response.rooms!.length} rooms from response',
      );
      for (final entry in _inListOrder(response.rooms!)) {
        final roomId = entry.key;
        final roomData = entry.value;
        Logs().d('[SlidingSync] Processing room: $roomId');

        // Check if this is truly the first time seeing this room
        final isActuallyInitial =
            (roomData.initial ?? false) && !_initializedRooms.contains(roomId);
        if (isActuallyInitial) {
          _initializedRooms.add(roomId);
          Logs().d('[SlidingSync] Room $roomId is initial (first time)');
        }

        // Check for new timeline events by comparing event IDs
        // Server's numLive field is unreliable, so we track the latest event ID instead.
        // Find the newest event by timestamp rather than assuming server order.
        var hasNewTimeline = false;
        if (roomData.timeline?.isNotEmpty ?? false) {
          final latestEvent = roomData.timeline!.reduce(
            (a, b) => a.originServerTs.isAfter(b.originServerTs) ? a : b,
          );
          final latestEventId = latestEvent.eventId;
          final previousEventId = _latestEventIds[roomId];

          if (latestEventId != previousEventId) {
            // Event ID changed, meaning we have a new message
            _latestEventIds[roomId] = latestEventId;
            hasNewTimeline = true;
          }
        }

        // Check for changed highlight/notification counts.
        final effectiveHighlight =
            roomData.highlightCount ??
            roomData.notificationCounts?.highlightCount;
        final effectiveNotification =
            roomData.notificationCount ??
            roomData.notificationCounts?.notificationCount;
        final highlightChanged =
            effectiveHighlight != null &&
            effectiveHighlight != _highlightCounts[roomId];
        final notificationChanged =
            effectiveNotification != null &&
            effectiveNotification != _notificationCounts[roomId];
        if (effectiveHighlight != null) {
          _highlightCounts[roomId] = effectiveHighlight;
        }
        if (effectiveNotification != null) {
          _notificationCounts[roomId] = effectiveNotification;
        }

        // Check if there are meaningful changes
        final hasNewContent =
            hasNewTimeline ||
            isActuallyInitial ||
            (roomData.inviteState?.isNotEmpty ?? false) ||
            highlightChanged ||
            notificationChanged;

        // Only update room state and emit updates if there are actual changes
        // This prevents processing the same timeline events repeatedly
        if (hasNewContent) {
          await _updateRoom(roomId, roomData);

          roomUpdates[roomId] = SlidingSyncRoomUpdate(
            roomId: roomId,
            roomData: roomData,
          );
        }
      }
    }

    // Process extensions
    if (response.extensions != null) {
      await _processExtensions(response.extensions!);
    }

    // Save cached position and list state AFTER all operations are applied
    // Always save because the position token changes even without list/room updates
    await _saveCachedPosition();

    return SlidingSyncUpdate(
      pos: response.pos,
      lists: listUpdates,
      rooms: roomUpdates,
      extensions: response.extensions,
    );
  }

  /// Orders [rooms] as they appear in the lists (lowest position across the
  /// lists first), with rooms that are in no list last, in response order.
  ///
  /// The server builds the room entries concurrently and emits them in
  /// completion order, so the response order is arbitrary. Processing them
  /// top of list first means a UI that shows rooms as they are added to the
  /// client shows the right ones first.
  List<MapEntry<String, SlidingSyncRoomData>> _inListOrder(
    Map<String, SlidingSyncRoomData> rooms,
  ) {
    final positions = <String, int>{};
    for (final list in _lists.values) {
      final roomIds = list.roomIds;
      for (var i = 0; i < roomIds.length; i++) {
        final roomId = roomIds[i];
        if (roomId.isEmpty || !rooms.containsKey(roomId)) continue;
        final known = positions[roomId];
        if (known == null || i < known) positions[roomId] = i;
      }
    }

    // Rooms in no list (room subscriptions) sort after every listed room,
    // whatever its list index.
    final afterLists = positions.values.fold(-1, max) + 1;
    int positionOf(String roomId) => positions[roomId] ?? afterLists;
    // Indexed so the sort is stable for rooms with the same position.
    final indexed = rooms.entries.toList().asMap().entries.toList()
      ..sort((a, b) {
        final byPosition = positionOf(
          a.value.key,
        ).compareTo(positionOf(b.value.key));
        return byPosition != 0 ? byPosition : a.key.compareTo(b.key);
      });
    return [for (final entry in indexed) entry.value];
  }

  /// Updates a room with sliding sync data
  Future<void> _updateRoom(String roomId, SlidingSyncRoomData data) async {
    // Get or create room
    var room = client.getRoomById(roomId);
    if (room == null) {
      // Determine membership from data
      Membership membership;
      if (data.inviteState != null && data.inviteState!.isNotEmpty) {
        membership = Membership.invite;
      } else if (data.knockState != null && data.knockState!.isNotEmpty) {
        membership = Membership.knock;
      } else {
        // Default to join for rooms in the sync response
        membership = Membership.join;
      }

      // Create a basic room structure
      room = Room(id: roomId, membership: membership, client: client);
      client.rooms.add(room);
    }

    // Update room properties through state events
    if (data.name != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.name',
          stateKey: '',
          content: {'name': data.name},
          senderId: '',
        ),
      );
    }

    if (data.avatarUrl != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.avatar',
          stateKey: '',
          content: {'url': data.avatarUrl},
          senderId: '',
        ),
      );
    }

    if (data.topic != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.topic',
          stateKey: '',
          content: {'topic': data.topic},
          senderId: '',
        ),
      );
    }

    if (data.canonicalAlias != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.canonical_alias',
          stateKey: '',
          content: {'alias': data.canonicalAlias},
          senderId: '',
        ),
      );
    }

    if (data.joinRule != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.join_rules',
          stateKey: '',
          content: {'join_rule': data.joinRule},
          senderId: '',
        ),
      );
    }

    // roomType mirrors m.room.create content['type']. Applied as a minimal
    // placeholder; a full m.room.create from requiredState will override this.
    if (data.roomType != null) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.create',
          stateKey: '',
          content: {'type': data.roomType},
          senderId: '',
        ),
      );
    }

    // encrypted is a convenience flag. Apply a minimal m.room.encryption event
    // so the SDK treats the room as encrypted; the full event from requiredState
    // will override this if present.
    // Note: dmTargets and heroCount are intentionally not applied here.
    // dmTargets requires updating m.direct account data (not done here), and
    // heroCount has no corresponding field in the SDK's RoomSummary.
    if (data.encrypted ?? false) {
      room.setState(
        StrippedStateEvent(
          type: 'm.room.encryption',
          stateKey: '',
          content: {},
          senderId: '',
        ),
      );
    }

    if (data.highlightCount != null) {
      room.highlightCount = data.highlightCount!;
    }

    if (data.notificationCount != null) {
      room.notificationCount = data.notificationCount!;
    }

    if (data.prevBatch != null) {
      room.prev_batch = data.prevBatch;
    }

    // Process required state
    if (data.requiredState != null) {
      for (final event in data.requiredState!) {
        if (event.stateKey != null) {
          room.setState(
            StrippedStateEvent(
              type: event.type,
              stateKey: event.stateKey,
              content: event.content,
              senderId: event.senderId,
            ),
          );
        }
      }
    }

    final previewTypes = previewEventTypes ?? client.roomPreviewLastEvents;

    // Only these events may become room.lastEvent. Excludes redactions, edits
    // and empty content so ordering ignores non-preview events (e.g.
    // sent-status, matching the web client.
    bool isPreviewable(Event event) =>
        previewTypes.contains(event.type) &&
        !event.redacted &&
        event.relationshipType != RelationshipTypes.edit &&
        event.content.isNotEmpty;

    // Sort oldest-first so events are emitted in chronological order regardless
    // of how the server delivered them.
    Event? mostRecentPreviewableEvent;
    if (data.timeline != null) {
      final sortedTimeline = data.timeline!.toList()
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

      for (final matrixEvent in sortedTimeline) {
        final event = Event.fromMatrixEvent(
          matrixEvent,
          room,
          status: EventStatus.synced,
        );

        if (isPreviewable(event)) {
          mostRecentPreviewableEvent = event;
        }

        // Only emit events we haven't seen before to avoid duplicate processing
        if (!_emittedEventIds.contains(event.eventId)) {
          _emittedEventIds.add(event.eventId);
          client.onTimelineEvent.add(event);
        }
      }
    }

    final roomUpdate = JoinedRoomUpdate(
      timeline: data.timeline != null
          ? TimelineUpdate(
              // Sort events oldest-first by timestamp as the SDK expects.
              // Sliding sync may deliver events out of chronological order,
              // so explicit sorting is more reliable than just reversing.
              events: data.timeline!.toList()
                ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs)),
              // Force limited to false to prevent SDK from calling /messages API
              // We manage lastEvent ourselves in sliding sync.
              limited: false,
              prevBatch: data.prevBatch,
            )
          : null,
      state: data.requiredState,
      summary: RoomSummary.fromJson({
        if (data.heroes != null)
          'm.heroes': data.heroes!.map((h) => h.userId).toList(),
        if (data.joinedCount != null) 'm.joined_member_count': data.joinedCount,
        if (data.invitedCount != null)
          'm.invited_member_count': data.invitedCount,
      }),
      // Synapse sends the counts as top-level `notification_count` /
      // `highlight_count`; `notification_counts` is the sliding sync proxy's
      // spelling. Pass them on so storeRoomUpdate persists them and the
      // badges survive a restart, which resumes from the cached `pos` and so
      // only receives rooms that changed since.
      unreadNotifications:
          data.notificationCounts ??
          (data.notificationCount != null || data.highlightCount != null
              ? UnreadNotificationCounts(
                  notificationCount: data.notificationCount,
                  highlightCount: data.highlightCount,
                )
              : null),
    );

    // The room's lastEvent: the newest previewable event in this batch, or the
    // current one when it's previewable and newer (e.g. a just-sent message the
    // batch doesn't include yet). We fall back to the current event because
    // storeRoomUpdate below persists this value and overwrites the stored
    // lastEvent even when it is null.
    final prior = room.lastEvent;
    var lastEventToStore = mostRecentPreviewableEvent;
    if (prior != null &&
        isPreviewable(prior) &&
        (lastEventToStore == null ||
            prior.originServerTs.isAfter(lastEventToStore.originServerTs))) {
      lastEventToStore = prior;
    }

    // Store room update in database so handleSync can find the events
    await client.database.storeRoomUpdate(
      roomId,
      roomUpdate,
      lastEventToStore,
      client,
    );

    // handleSync stores the timeline events (so getTimeline() can retrieve
    // them) and the state events (so they survive a restart; the setState
    // calls above are in memory only). Skip it when there is nothing to
    // store. With `limited: false` and no timeline the SDK creates no
    // "Refreshing..." placeholder lastEvent.
    final hasTimeline = data.timeline?.isNotEmpty ?? false;
    final hasState = data.requiredState?.isNotEmpty ?? false;
    if (hasTimeline || hasState) {
      await client.handleSync(
        SyncUpdate(
          nextBatch: _pos ?? 'sliding_sync_initial',
          rooms: RoomsUpdate(join: {roomId: roomUpdate}),
        ),
      );
    }

    // handleSync (above) picks lastEvent from `client.roomPreviewLastEvents`
    // and persists that pick, overwriting what we stored. Overwrite it with
    // our previewable choice, in memory and in the database, so the order
    // after a restart (sorted on the stored lastEvent) matches the order
    // before it. If we don't have one, leave handleSync's value rather than
    // nulling it.
    if (lastEventToStore != null &&
        room.lastEvent?.eventId != lastEventToStore.eventId) {
      room.lastEvent = lastEventToStore;
      await client.database.storeRoomUpdate(
        roomId,
        JoinedRoomUpdate(),
        lastEventToStore,
        client,
      );
    }
  }

  /// Processes extensions from the response
  Future<void> _processExtensions(
    SlidingSyncExtensionResponse extensions,
  ) async {
    // Process to-device events
    if (extensions.toDevice != null) {
      // Advance the to-device batch token so the server knows we've processed
      // these events and won't re-deliver them on reconnect (MSC4186 §to_device).
      if (extensions.toDevice!.nextBatch != null) {
        _toDeviceSince = extensions.toDevice!.nextBatch;
      }
      if (extensions.toDevice!.events != null) {
        for (final event in extensions.toDevice!.events!) {
          client.onToDeviceEvent.add(event);
        }
      }
    }

    // Process E2EE data
    if (extensions.e2ee != null) {
      if (extensions.e2ee!.deviceLists != null) {
        // Update device lists
        final deviceLists = extensions.e2ee!.deviceLists!;
        if (deviceLists.changed != null) {
          for (final userId in deviceLists.changed!) {
            final userKeys = client.userDeviceKeys[userId];
            if (userKeys != null) {
              userKeys.outdated = true;
              await client.database.storeUserDeviceKeysInfo(userId, true);
            }
          }
        }
        if (deviceLists.left != null) {
          for (final userId in deviceLists.left!) {
            if (client.userDeviceKeys.containsKey(userId)) {
              client.userDeviceKeys.remove(userId);
            }
          }
        }
      }

      if (extensions.e2ee!.deviceOneTimeKeysCount != null) {
        // Update one-time key counts
        client.encryption?.handleDeviceOneTimeKeysCount(
          extensions.e2ee!.deviceOneTimeKeysCount ?? {},
          extensions.e2ee!.deviceUnusedFallbackKeyTypes,
        );
      }
    }

    // Process account data
    if (extensions.accountData != null) {
      if (extensions.accountData!.global != null) {
        for (final event in extensions.accountData!.global!) {
          client.accountData[event.type] = event;
          client.onSync.add(SyncUpdate(nextBatch: '', accountData: [event]));
        }
      }

      if (extensions.accountData!.rooms != null) {
        for (final entry in extensions.accountData!.rooms!.entries) {
          final roomId = entry.key;
          final events = entry.value;
          final room = client.getRoomById(roomId);

          if (room != null) {
            for (final event in events) {
              room.roomAccountData[event.type] = event;
            }
          }
        }
      }
    }

    // Process typing notifications
    if (extensions.typing != null && extensions.typing!.rooms != null) {
      for (final entry in extensions.typing!.rooms!.entries) {
        final roomId = entry.key;
        final typingContent = entry.value;
        final room = client.getRoomById(roomId);

        if (room != null) {
          // Store typing users in ephemerals
          room.ephemerals['m.typing'] = BasicEvent(
            type: 'm.typing',
            content: {'user_ids': typingContent.userIds},
          );
        }
      }
    }

    // Process receipts
    if (extensions.receipts != null && extensions.receipts!.rooms != null) {
      for (final entry in extensions.receipts!.rooms!.entries) {
        final roomId = entry.key;
        final receiptContent = entry.value;
        final room = client.getRoomById(roomId);

        if (room != null) {
          // Store receipts in ephemerals
          room.ephemerals['m.receipt'] = BasicEvent(
            type: 'm.receipt',
            content: receiptContent.content,
          );
        }
      }
    }

    // Process presence
    if (extensions.presence != null && extensions.presence!.events != null) {
      for (final event in extensions.presence!.events!) {
        // Guard against malformed events that are missing the sender field
        if (event.content['sender'] is String) {
          client.onPresenceChanged.add(CachedPresence.fromJson(event.content));
        }
      }
    }
  }

  /// Updates sync status
  void _updateStatus(SlidingSyncStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  /// Loads cached position from database
  Future<void> _loadCachedPosition() async {
    final accountData = await client.database.getAccountData();
    final cachedPosEvent = accountData['sliding_sync_pos_$_connId'];
    if (cachedPosEvent != null && cachedPosEvent.content['pos'] is String) {
      _pos = cachedPosEvent.content['pos']! as String;
      _toDeviceSince = cachedPosEvent.content['to_device_since'] as String?;

      // Restore list state (similar to Rust SDK's cold_cache)
      if (cachedPosEvent.content['lists'] is Map) {
        final cachedLists =
            cachedPosEvent.content['lists']! as Map<String, dynamic>;
        _cachedListsState = cachedLists;
        for (final entry in cachedLists.entries) {
          final list = _lists[entry.key];
          if (list != null && entry.value is Map) {
            _preloadList(list, entry.value as Map<String, dynamic>);
          }
        }
      }
    }
  }

  /// Shows [list]'s rooms from the previous session's cache.
  void _preloadList(SlidingSyncList list, Map<String, dynamic> listData) {
    final roomIds = (listData['room_ids'] as List?)?.cast<String>() ?? [];
    final totalCount = listData['total_count'] as int?;

    if (roomIds.isNotEmpty) {
      // Restore cached room IDs for immediate UI display, but don't
      // restore ranges. Let the list start with its initial batch size
      // to avoid requesting hundreds of rooms on the first sync after
      // restart, which causes timeouts and slow loading.
      list.markAsPreloaded(roomIds, totalCount);
    }
  }

  /// Saves position and list state to database cache
  Future<void> _saveCachedPosition() async {
    if (_pos != null) {
      // Collect list state (similar to Rust SDK's cold_cache persistence)
      final listsState = <String, Map<String, dynamic>>{};
      for (final entry in _lists.entries) {
        final roomIds = entry.value.roomIds;

        listsState[entry.key] = {
          'room_ids': roomIds,
          'total_count': entry.value.totalRoomCount,
        };
      }

      await client.database.storeAccountData('sliding_sync_pos_$_connId', {
        'pos': _pos,
        'lists': listsState,
        if (_toDeviceSince != null) 'to_device_since': _toDeviceSince,
      });
    }
  }

  /// Disposes resources
  /// Note: This will stop the sync loop if it's running
  Future<void> dispose() async {
    Logs().i('[SlidingSync] Disposing resources (id: $_connId)');

    // Stop sync loop if running
    if (_isSyncing) {
      await stopSync();
    }

    // Dispose all lists
    for (final list in _lists.values) {
      list.dispose();
    }
    _lists.clear();

    // Close stream controllers
    await _updateController.close();
    await _statusController.close();

    Logs().i('[SlidingSync] Resources disposed (id: $_connId)');
  }
}

/// Builder for configuring sliding sync
class SlidingSyncBuilder {
  SlidingSyncBuilder({required this.client});
  final Client client;

  SlidingSyncExtensions? extensions;
  Set<String>? _previewEventTypes;
  Duration _pollTimeout = const Duration(seconds: 30);
  final List<SlidingSyncList> _lists = [];

  /// Sets the extensions
  SlidingSyncBuilder withExtensions(SlidingSyncExtensions ext) {
    extensions = ext;
    return this;
  }

  /// How long the server may hold a request waiting for new data. Defaults
  /// to 30 seconds.
  SlidingSyncBuilder withPollTimeout(Duration timeout) {
    _pollTimeout = timeout;
    return this;
  }

  SlidingSyncBuilder withPreviewEventTypes(Set<String> types) {
    _previewEventTypes = types;
    return this;
  }

  /// Adds a list
  SlidingSyncBuilder addList(SlidingSyncList list) {
    _lists.add(list);
    return this;
  }

  /// Builds the sliding sync instance
  SlidingSync build() {
    final slidingSync = SlidingSync(
      client: client,
      extensions: extensions,
      previewEventTypes: _previewEventTypes,
      pollTimeout: _pollTimeout,
    );

    for (final list in _lists) {
      slidingSync._addList(list);
    }

    return slidingSync;
  }
}
