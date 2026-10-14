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
  /// ordering (a state event, a room tag or a read receipt), regardless of
  /// which call site triggered it. [SlidingSync] wires this to `wakeSyncLoop`
  /// so the change is reflected on the next request instead of waiting out
  /// the long-poll.
  void Function()? onRoomMutation;

  /// Called after a read receipt (`m.read` / `m.read.private`) for [roomId]
  /// was accepted by the server. [SlidingSync] wires this to clear the
  /// room's unread counts locally and poll, since the server only re-sends
  /// a room's counts along with new activity in that room.
  Future<void> Function(String roomId)? onReadReceipt;

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

  /// [Client.clear] (run on logout) re-enables the background sync loop. With
  /// [sync] returning immediately that loop would spin without pause after the
  /// next login, so switch it back off.
  @override
  Future<void> clear() async {
    await super.clear();
    backgroundSync = false;
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

  // Read receipts change the server-side `unread` list filter, which Synapse
  // never answers a long-poll early for (it only does so for room data), so
  // poll right after sending one. A fully-read marker on its own does not
  // affect unread counts, so it only wakes the loop.

  @override
  Future<void> setReadMarker(
    String roomId, {
    String? mFullyRead,
    String? mRead,
    String? mReadPrivate,
  }) async {
    await super.setReadMarker(
      roomId,
      mFullyRead: mFullyRead,
      mRead: mRead,
      mReadPrivate: mReadPrivate,
    );
    await _afterReceipt(roomId, isRead: mRead != null || mReadPrivate != null);
  }

  @override
  Future<void> postReceipt(
    String roomId,
    ReceiptType receiptType,
    String eventId, {
    String? threadId,
  }) async {
    await super.postReceipt(roomId, receiptType, eventId, threadId: threadId);
    await _afterReceipt(
      roomId,
      isRead:
          receiptType == ReceiptType.mRead ||
          receiptType == ReceiptType.mReadPrivate,
    );
  }

  Future<void> _afterReceipt(String roomId, {required bool isRead}) async {
    final onReadReceipt = this.onReadReceipt;
    if (isRead && onReadReceipt != null) {
      await onReadReceipt(roomId);
    } else {
      onRoomMutation?.call();
    }
  }
}
