// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:voys_matrix_sliding_sync/src/api_extensions.dart';
import 'package:voys_matrix_sliding_sync/src/models/request.dart';
import 'package:voys_matrix_sliding_sync/src/models/response.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_list.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_update.dart';
import 'package:voys_matrix_sliding_sync/src/sync_mode.dart';

/// Main sliding sync controller
class SlidingSync {
  /// Unique connection identifier
  final String id;

  /// The client instance
  final Client client;

  /// Long-poll timeout in milliseconds
  final int pollTimeout;

  /// Network timeout in milliseconds
  final int networkTimeout;

  /// Current position token
  String? _pos;

  /// Named lists
  final Map<String, SlidingSyncList> _lists = {};

  /// Extensions configuration
  SlidingSyncExtensions _extensions;

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

  /// Track which events we've already emitted to avoid duplicates
  final Set<String> _emittedEventIds = {};

  SlidingSync({
    required this.id,
    required this.client,
    this.pollTimeout = 30000,
    this.networkTimeout = 40000,
    SlidingSyncExtensions? extensions,
  }) : _extensions = extensions ?? SlidingSyncExtensions.essential();

  /// Creates a builder for configuring sliding sync
  static SlidingSyncBuilder builder({
    required String id,
    required Client client,
  }) {
    return SlidingSyncBuilder(id: id, client: client);
  }

  /// Stream of sync updates
  Stream<SlidingSyncUpdate> get updateStream => _updateController.stream;

  /// Stream of sync status
  Stream<SlidingSyncStatus> get statusStream => _statusController.stream;

  /// Current position token
  String? get pos => _pos;

  /// Whether sync is currently running
  bool get isSyncing => _isSyncing;

  /// Named lists
  Map<String, SlidingSyncList> get lists => Map.unmodifiable(_lists);

  /// Adds a list to the sync
  SlidingSyncList addList(SlidingSyncList list) {
    // Validate list count
    if (_lists.length >= 100) {
      throw ArgumentError(
        'Maximum 100 lists allowed per sliding sync instance',
      );
    }

    // Validate list name length (64 bytes max)
    if (list.name.length > 64) {
      throw ArgumentError('List name exceeds 64 characters');
    }

    // Check for duplicate names
    if (_lists.containsKey(list.name)) {
      throw ArgumentError('List with name ${list.name} already exists');
    }

    _lists[list.name] = list;
    return list;
  }

  /// Removes a list from the sync
  void removeList(String name) {
    _lists[name]?.dispose();
    _lists.remove(name);
  }

  /// Gets a list by name
  SlidingSyncList? getList(String name) {
    return _lists[name];
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
  }

  /// Unsubscribes from specific rooms
  void unsubscribeFromRooms(List<String> roomIds) {
    for (final roomId in roomIds) {
      _activeRoomSubscriptions.remove(roomId);
    }
  }

  /// Sets the extensions to use
  void setExtensions(SlidingSyncExtensions extensions) {
    _extensions = extensions;
  }

  /// Starts the sync loop
  Future<void> startSync() async {
    if (_isSyncing) {
      return;
    }

    // ignore: avoid_print
    print('[SlidingSync] Starting sync loop (id: $id)');
    _isSyncing = true;
    _stopCompleter = null;
    _updateStatus(SlidingSyncStatus.waitingForResponse);

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

        // Create placeholder room objects so UI can render them immediately
        // Set lastEvent to null explicitly to show "No messages" instead of "Refreshing..."
        for (final roomId in allRoomIds) {
          var room = client.getRoomById(roomId);
          if (room == null) {
            // Create room object with null lastEvent
            room = Room(
              id: roomId,
              membership: Membership.join,
              client: client,
            );
            room.lastEvent =
                null; // Explicitly null to prevent "Refreshing..." placeholder
            client.rooms.add(room);
            // Load room state from database
            await client.database.getSingleRoom(client, roomId);
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
              extensions: null,
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

    // ignore: avoid_print
    print('[SlidingSync] Stopping sync loop (id: $id)');
    _stopCompleter = Completer<void>();
    await _stopCompleter!.future;
    _stopCompleter = null;
    _hasEmittedFirstUpdate = false;
    // ignore: avoid_print
    print('[SlidingSync] Sync loop stopped (id: $id)');
  }

  /// Performs a single sync request
  Future<SlidingSyncUpdate> syncOnce() async {
    final request = _buildRequest();
    final requestJson = request.toJson();

    _updateStatus(SlidingSyncStatus.waitingForResponse);

    try {
      final response = await client.slidingSync(requestJson);

      _updateStatus(SlidingSyncStatus.processing);

      final slidingSyncResponse = SlidingSyncResponse.fromJson(response);
      final update = await _processResponse(slidingSyncResponse);

      _updateStatus(SlidingSyncStatus.finished);

      return update;
    } catch (e) {
      _updateStatus(SlidingSyncStatus.error);
      rethrow;
    }
  }

  /// Expires the current session (clears position)
  Future<void> expireSession() async {
    _pos = null;
    await _saveCachedPosition();

    // Reset all lists
    for (final list in _lists.values) {
      list.reset();
    }

    // Active room subscriptions are already sent on every request, nothing to reset.
  }

  /// The main sync loop
  Future<void> _syncLoop() async {
    var lastRequestTime = DateTime.now();

    while (_isSyncing && _stopCompleter == null) {
      try {
        final update = await syncOnce();
        final requestDuration = DateTime.now().difference(lastRequestTime);

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

        // Workaround: Server ignores timeout parameter and responds immediately
        // Add delay when request completes too fast and there are no changes
        // This prevents busy loop while maintaining responsiveness for new messages
        if (requestDuration.inMilliseconds < 5000 && !hasChanges) {
          const targetInterval =
              3000; // Target 3 second interval between requests
          final delayMs = targetInterval - requestDuration.inMilliseconds;
          if (delayMs > 0) {
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }

        lastRequestTime = DateTime.now();

        // Check for stop signal
        if (_stopCompleter != null) {
          _stopCompleter!.complete();
          break;
        }
      } on MatrixException catch (e) {
        Logs().e(
          '[SlidingSync] Matrix error in sync loop: ${e.errcode} - ${e.error}',
        );
        if (e.errcode == 'M_UNKNOWN_POS') {
          // Position expired, reset and continue
          await expireSession();
          continue;
        }

        // For other Matrix errors, wait before retrying
        await Future.delayed(Duration(seconds: 3));
      } catch (e, stackTrace) {
        Logs().e('[SlidingSync] Error in sync loop: $e');
        Logs().e('[SlidingSync] Stack trace: $stackTrace');
        // For network errors, wait before retrying
        await Future.delayed(Duration(seconds: 3));
      }
    }
  }

  /// Builds the sync request
  SlidingSyncRequest _buildRequest() {
    if (_activeRoomSubscriptions.isNotEmpty) {
      Logs().d(
        '[SlidingSync] Including ${_activeRoomSubscriptions.length} room subscriptions: ${_activeRoomSubscriptions.keys.join(", ")}',
      );
    }

    return SlidingSyncRequest(
      connId: id,
      pos: _pos,
      timeout: pollTimeout,
      setPresence: client.syncPresence?.toString().split('.').last,
      lists: _lists,
      roomSubscriptions: _activeRoomSubscriptions.isNotEmpty
          ? Map.unmodifiable(_activeRoomSubscriptions)
          : null,
      extensions: _extensions,
    );
  }

  /// Processes a sync response
  Future<SlidingSyncUpdate> _processResponse(
    SlidingSyncResponse response,
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

        if (list != null) {
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
                  break;
                case 'INSERT':
                  if (op.index != null && op.roomId != null) {
                    list.applyInsertOp(op.index!, op.roomId!);
                    hasActualChanges = true; // INSERT always means change
                  }
                  break;
                case 'DELETE':
                  if (op.index != null) {
                    list.applyDeleteOp(op.index!);
                    hasActualChanges = true; // DELETE always means change
                  }
                  break;
                case 'INVALIDATE':
                  if (op.range != null) {
                    list.applyInvalidateOp(op.range!);
                    hasActualChanges = true; // INVALIDATE always means change
                  }
                  break;
              }
            }
          }

          // Update the list with count (operations already applied above)
          list.updateFromResponse(
            count: listResponse.count,
            roomIds: null, // Operations handle room updates
            ranges: null, // Operations handle range updates
          );

          // Only add to updates if operations actually changed something
          if (hasActualChanges) {
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
      for (final entry in response.rooms!.entries) {
        final roomId = entry.key;
        final roomData = entry.value;
        Logs().d('[SlidingSync] Processing room: $roomId');

        // Check if this is truly the first time seeing this room
        final isActuallyInitial =
            roomData.initial == true && !_initializedRooms.contains(roomId);
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

        // Check if there are meaningful changes
        final hasNewContent =
            hasNewTimeline ||
            isActuallyInitial ||
            (roomData.inviteState?.isNotEmpty ?? false);

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
              stateKey: event.stateKey!,
              content: event.content,
              senderId: event.senderId,
            ),
          );
        }
      }
    }

    // Process timeline events. Sort oldest-first so events are emitted in
    // chronological order regardless of how the server delivered them.
    Event? mostRecentEvent;
    if (data.timeline != null) {
      final sortedTimeline = data.timeline!.toList()
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));

      for (final matrixEvent in sortedTimeline) {
        final event = Event.fromMatrixEvent(
          matrixEvent,
          room,
          status: EventStatus.synced,
        );

        // Track most recent event by timestamp (last item after sorting)
        mostRecentEvent = event;

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
                ..sort(
                  (a, b) => a.originServerTs.compareTo(b.originServerTs),
                ),
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
      unreadNotifications: data.notificationCounts,
    );

    // Capture lastEvent before handleSync so we can compare afterwards.
    // The list subscription may only carry a small timeline (e.g. limit 1),
    // which could be older than a message the user just sent.
    final previousLastEvent = room.lastEvent;

    // Store room update in database so handleSync can find the events
    await client.database.storeRoomUpdate(
      roomId,
      roomUpdate,
      mostRecentEvent, // Pass the true latest event to store in database
      client,
    );

    // Only call handleSync if we have timeline events to process
    // This prevents placeholder "Refreshing..." events from being created
    if (data.timeline != null && data.timeline!.isNotEmpty) {
      // Call handleSync to properly process events into room state
      // This makes events available for getTimeline() to retrieve
      await client.handleSync(
        SyncUpdate(
          nextBatch: _pos ?? 'sliding_sync_initial',
          rooms: RoomsUpdate(join: {roomId: roomUpdate}),
        ),
      );
    }

    // Restore lastEvent to whichever event is truly the most recent:
    // either the newest event from this sync batch, or what was already set
    // (e.g. a just-sent message). This prevents a partial timeline batch from
    // overwriting a newer lastEvent with an older one.
    final candidates = [
      if (mostRecentEvent != null) mostRecentEvent,
      if (previousLastEvent != null) previousLastEvent,
    ];
    if (candidates.isNotEmpty) {
      room.lastEvent = candidates.reduce(
        (a, b) => a.originServerTs.isAfter(b.originServerTs) ? a : b,
      );
    }
  }

  /// Processes extensions from the response
  Future<void> _processExtensions(
    SlidingSyncExtensionResponse extensions,
  ) async {
    // Process to-device events
    if (extensions.toDevice != null && extensions.toDevice!.events != null) {
      for (final event in extensions.toDevice!.events!) {
        client.onToDeviceEvent.add(event);
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
        // Presence events have 'sender' in content
        final userId = event.content['sender'] as String?;
        if (userId != null) {
          final presence = CachedPresence.fromJson(event.content);
          client.onPresenceChanged.add(presence);
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
    final cachedPosEvent = accountData['sliding_sync_pos_$id'];
    if (cachedPosEvent != null && cachedPosEvent.content['pos'] is String) {
      _pos = cachedPosEvent.content['pos'] as String;

      // Restore list state (similar to Rust SDK's cold_cache)
      if (cachedPosEvent.content['lists'] is Map) {
        final cachedLists =
            cachedPosEvent.content['lists'] as Map<String, dynamic>;
        for (final entry in cachedLists.entries) {
          final list = _lists[entry.key];
          if (list != null && entry.value is Map) {
            final listData = entry.value as Map<String, dynamic>;
            final roomIds =
                (listData['room_ids'] as List?)?.cast<String>() ?? [];
            final totalCount = listData['total_count'] as int?;
            final ranges = (listData['ranges'] as List?)
                ?.map((r) => (r as List).cast<int>())
                .toList();

            if (roomIds.isNotEmpty) {
              // Mark list as preloaded with cached data
              list.markAsPreloaded(roomIds, totalCount);

              // Restore ranges if available
              if (ranges != null && ranges.isNotEmpty) {
                list.setRanges(ranges);

                // Only switch to selective mode if the list was fully loaded
                // If partially loaded, keep growing mode to continue loading
                final wasFullyLoaded =
                    totalCount != null && roomIds.length >= totalCount;
                if (wasFullyLoaded) {
                  // Switch to selective mode to maintain the cached range
                  // This prevents the server from re-syncing from scratch
                  list.setSyncMode(SyncMode.selective);
                }
                // Otherwise keep the original sync mode (likely growing)
              }
            }
          }
        }
      }
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
          'ranges': entry.value.ranges,
        };
      }

      await client.database.storeAccountData('sliding_sync_pos_$id', {
        'pos': _pos,
        'lists': listsState,
      });
    }
  }

  /// Disposes resources
  /// Note: This will stop the sync loop if it's running
  Future<void> dispose() async {
    // ignore: avoid_print
    print('[SlidingSync] Disposing resources (id: $id)');

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

    // ignore: avoid_print
    print('[SlidingSync] Resources disposed (id: $id)');
  }
}

/// Builder for configuring sliding sync
class SlidingSyncBuilder {
  final String id;
  final Client client;

  int pollTimeout = 30000;
  int networkTimeout = 40000;
  SlidingSyncExtensions? extensions;
  final List<SlidingSyncList> _lists = [];
  final Map<String, RoomSubscription> _roomSubscriptions = {};

  SlidingSyncBuilder({required this.id, required this.client});

  /// Sets the poll timeout
  SlidingSyncBuilder withPollTimeout(int milliseconds) {
    pollTimeout = milliseconds;
    return this;
  }

  /// Sets the network timeout
  SlidingSyncBuilder withNetworkTimeout(int milliseconds) {
    networkTimeout = milliseconds;
    return this;
  }

  /// Sets the extensions
  SlidingSyncBuilder withExtensions(SlidingSyncExtensions ext) {
    extensions = ext;
    return this;
  }

  /// Adds a list
  SlidingSyncBuilder addList(SlidingSyncList list) {
    _lists.add(list);
    return this;
  }

  /// Subscribes to rooms
  SlidingSyncBuilder subscribeToRooms(Map<String, RoomSubscription> subs) {
    _roomSubscriptions.addAll(subs);
    return this;
  }

  /// Builds the sliding sync instance
  SlidingSync build() {
    final slidingSync = SlidingSync(
      id: id,
      client: client,
      pollTimeout: pollTimeout,
      networkTimeout: networkTimeout,
      extensions: extensions,
    );

    // Add lists
    for (final list in _lists) {
      slidingSync.addList(list);
    }

    // Add room subscriptions
    if (_roomSubscriptions.isNotEmpty) {
      slidingSync.subscribeToRooms(_roomSubscriptions);
    }

    return slidingSync;
  }
}
