import 'dart:async';

import 'package:matrix/matrix.dart';

/// Custom client that disables the normal sync completely.
///
/// This client extends [Client] and overrides the [sync] method to prevent
/// any normal Matrix sync requests from being made to the server. This is
/// useful when you want to use only sliding sync and avoid the overhead of
/// the traditional sync mechanism.
///
/// The overridden [sync] method returns an empty [SyncUpdate] without making
/// any HTTP requests, effectively intercepting all sync calls at the API level.
class SlidingSyncOnlyClient extends Client {
  SlidingSyncOnlyClient(
    super.clientName, {
    required super.database,
    super.enableDehydratedDevices,
    super.importantStateEvents,
    super.roomPreviewLastEvents,
    super.sendTimelineEventTimeout,
    super.httpClient,
    super.customRoomSorter,
  }) {
    backgroundSync = false;
  }

  /// Called after a write that could affect sliding sync list membership or
  /// ordering (a state event or a room tag), regardless of which call site
  /// triggered it. [SlidingSync] wires this to `wakeSyncLoop` so the change
  /// is reflected on the next request instead of waiting out the poll delay.
  void Function()? onRoomMutation;

  /// Override the public sync method to prevent any sync calls.
  ///
  /// Returns a minimal SyncUpdate to prevent the SDK from making actual sync requests
  /// while avoiding errors that would indicate connection problems.
  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
    bool? useStateAfter,
  }) async {
    // Return a minimal SyncUpdate to prevent sync without causing errors
    return SyncUpdate(nextBatch: since ?? prevBatch ?? '');
  }

  @override
  Future<String> setRoomStateWithKey(
    String roomId,
    String eventType,
    String stateKey,
    Map<String, Object?> body,
  ) async {
    final eventId = await super.setRoomStateWithKey(
      roomId,
      eventType,
      stateKey,
      body,
    );
    onRoomMutation?.call();
    return eventId;
  }

  @override
  Future<void> setRoomTag(
    String userId,
    String roomId,
    String tag,
    Tag body,
  ) async {
    await super.setRoomTag(userId, roomId, tag, body);
    onRoomMutation?.call();
  }

  @override
  Future<void> deleteRoomTag(String userId, String roomId, String tag) async {
    await super.deleteRoomTag(userId, roomId, tag);
    onRoomMutation?.call();
  }
}
