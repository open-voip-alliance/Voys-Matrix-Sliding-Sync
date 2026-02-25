// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:matrix/matrix.dart';

/// Response structure for sliding sync
class SlidingSyncResponse {

  SlidingSyncResponse({
    required this.pos,
    this.lists,
    this.rooms,
    this.extensions,
  });

  factory SlidingSyncResponse.fromJson(Map<String, dynamic> json) {
    return SlidingSyncResponse(
      pos: json['pos'] as String,
      lists: json['lists'] != null
          ? (json['lists'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                SlidingSyncListResponse.fromJson(value as Map<String, dynamic>),
              ),
            )
          : null,
      rooms: json['rooms'] != null
          ? (json['rooms'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                SlidingSyncRoomData.fromJson(value as Map<String, dynamic>),
              ),
            )
          : null,
      extensions: json['extensions'] != null
          ? SlidingSyncExtensionResponse.fromJson(
              json['extensions'] as Map<String, dynamic>,
            )
          : null,
    );
  }
  /// Position token for next request
  final String pos;

  /// Named list updates
  final Map<String, SlidingSyncListResponse>? lists;

  /// Room data keyed by room ID
  final Map<String, SlidingSyncRoomData>? rooms;

  /// Extension data
  final SlidingSyncExtensionResponse? extensions;
}

/// List response data
class SlidingSyncListResponse {

  SlidingSyncListResponse({this.count, this.ops});

  factory SlidingSyncListResponse.fromJson(Map<String, dynamic> json) {
    return SlidingSyncListResponse(
      count: json['count'] as int?,
      ops: json['ops'] != null
          ? (json['ops'] as List<dynamic>)
                .map(
                  (e) =>
                      SlidingSyncOperation.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : null,
    );
  }
  /// Total number of rooms matching filters
  final int? count;

  /// Operations to apply to the list
  final List<SlidingSyncOperation>? ops;
}

/// Operation for list updates
class SlidingSyncOperation {

  SlidingSyncOperation({
    required this.op,
    this.range,
    this.index,
    this.roomIds,
    this.roomId,
  });

  factory SlidingSyncOperation.fromJson(Map<String, dynamic> json) {
    return SlidingSyncOperation(
      op: json['op'] as String,
      range: json['range'] != null
          ? (json['range'] as List<dynamic>).map((e) => e as int).toList()
          : null,
      index: json['index'] as int?,
      roomIds: json['room_ids'] != null
          ? (json['room_ids'] as List<dynamic>).map((e) => e as String).toList()
          : null,
      roomId: json['room_id'] as String?,
    );
  }
  /// Operation type (SYNC, INSERT, DELETE, INVALIDATE)
  final String op;

  /// Range affected by the operation
  final List<int>? range;

  /// Index for INSERT/DELETE operations
  final int? index;

  /// Room IDs for SYNC operation
  final List<String>? roomIds;

  /// Room ID for INSERT operation
  final String? roomId;
}

/// Room data in sliding sync response
class SlidingSyncRoomData {

  SlidingSyncRoomData({
    this.name,
    this.avatarUrl,
    this.topic,
    this.roomType,
    this.joinedCount,
    this.invitedCount,
    this.heroCount,
    this.heroes,
    this.bumpStamp,
    this.initial,
    this.expandedTimeline,
    this.numLive,
    this.timeline,
    this.requiredState,
    this.prevBatch,
    this.limited,
    this.inviteState,
    this.encrypted,
    this.canonicalAlias,
    this.joinRule,
    this.knockState,
    this.dmTargets,
    this.notificationCounts,
    this.highlightCount,
    this.notificationCount,
  });

  factory SlidingSyncRoomData.fromJson(Map<String, dynamic> json) {
    return SlidingSyncRoomData(
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      topic: json['topic'] as String?,
      roomType: json['room_type'] as String?,
      joinedCount: json['joined_count'] as int?,
      invitedCount: json['invited_count'] as int?,
      heroCount: json['hero_count'] as int?,
      heroes: json['heroes'] != null
          ? (json['heroes'] as List<dynamic>)
                .map((e) => SlidingSyncHero.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
      bumpStamp: json['bump_stamp'] as int?,
      initial: json['initial'] as bool?,
      expandedTimeline: json['expanded_timeline'] as bool?,
      numLive: json['num_live'] as int?,
      timeline: json['timeline'] != null
          ? (json['timeline'] as List<dynamic>)
                .map((e) => MatrixEvent.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
      requiredState: json['required_state'] != null
          ? (json['required_state'] as List<dynamic>)
                .map((e) => MatrixEvent.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
      prevBatch: json['prev_batch'] as String?,
      limited: json['limited'] as bool?,
      inviteState: json['invite_state'] != null
          ? (json['invite_state'] as List<dynamic>)
                .map(
                  (e) => StrippedStateEvent.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : null,
      encrypted: json['encrypted'] as bool?,
      canonicalAlias: json['canonical_alias'] as String?,
      joinRule: json['join_rule'] as String?,
      knockState: json['knock_state'] != null
          ? (json['knock_state'] as List<dynamic>)
                .map(
                  (e) => StrippedStateEvent.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : null,
      dmTargets: json['dm_targets'] != null
          ? (json['dm_targets'] as List<dynamic>)
                .map((e) => e as String)
                .toList()
          : null,
      notificationCounts: json['notification_counts'] != null
          ? UnreadNotificationCounts.fromJson(
              json['notification_counts'] as Map<String, dynamic>,
            )
          : null,
      highlightCount: json['highlight_count'] as int?,
      notificationCount: json['notification_count'] as int?,
    );
  }
  /// Calculated room name
  final String? name;

  /// Room avatar URL
  final String? avatarUrl;

  /// Room topic
  final String? topic;

  /// Room type (e.g., "m.space")
  final String? roomType;

  /// Number of joined members
  final int? joinedCount;

  /// Number of invited members
  final int? invitedCount;

  /// Number of hero members
  final int? heroCount;

  /// Hero member information for room name calculation
  final List<SlidingSyncHero>? heroes;

  /// Activity timestamp in milliseconds
  final int? bumpStamp;

  /// Whether this is the initial sync for this room
  final bool? initial;

  /// Whether timeline was expanded due to increased limit
  final bool? expandedTimeline;

  /// Number of live events in timeline
  final int? numLive;

  /// Timeline events (newest first)
  final List<MatrixEvent>? timeline;

  /// Required state events
  final List<MatrixEvent>? requiredState;

  /// Pagination token for loading history
  final String? prevBatch;

  /// Whether the timeline is limited
  final bool? limited;

  /// Invite state for invited rooms
  final List<StrippedStateEvent>? inviteState;

  /// Whether the room is encrypted
  final bool? encrypted;

  /// Canonical alias for the room
  final String? canonicalAlias;

  /// Join rule for the room (public, invite, knock, etc)
  final String? joinRule;

  /// Knock state for knocked rooms
  final List<StrippedStateEvent>? knockState;

  /// DM target user IDs (for direct message identification)
  final List<String>? dmTargets;

  /// Notification counts
  final UnreadNotificationCounts? notificationCounts;

  /// Highlight count
  final int? highlightCount;

  /// Notification count
  final int? notificationCount;
}

/// Hero member information
class SlidingSyncHero {

  SlidingSyncHero({required this.userId, this.name, this.avatarUrl});

  factory SlidingSyncHero.fromJson(Map<String, dynamic> json) {
    return SlidingSyncHero(
      userId: json['user_id'] as String,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
  /// User ID
  final String userId;

  /// Display name
  final String? name;

  /// Avatar URL
  final String? avatarUrl;
}

/// Extension response data
class SlidingSyncExtensionResponse {

  SlidingSyncExtensionResponse({
    this.toDevice,
    this.e2ee,
    this.accountData,
    this.receipts,
    this.typing,
    this.presence,
  });

  factory SlidingSyncExtensionResponse.fromJson(Map<String, dynamic> json) {
    return SlidingSyncExtensionResponse(
      toDevice: json['to_device'] != null
          ? ToDeviceExtension.fromJson(
              json['to_device'] as Map<String, dynamic>,
            )
          : null,
      e2ee: json['e2ee'] != null
          ? E2EEExtension.fromJson(json['e2ee'] as Map<String, dynamic>)
          : null,
      accountData: json['account_data'] != null
          ? AccountDataExtension.fromJson(
              json['account_data'] as Map<String, dynamic>,
            )
          : null,
      receipts: json['receipts'] != null
          ? ReceiptsExtension.fromJson(json['receipts'] as Map<String, dynamic>)
          : null,
      typing: json['typing'] != null
          ? TypingExtension.fromJson(json['typing'] as Map<String, dynamic>)
          : null,
      presence: json['presence'] != null
          ? PresenceExtension.fromJson(json['presence'] as Map<String, dynamic>)
          : null,
    );
  }
  /// To-device events
  final ToDeviceExtension? toDevice;

  /// E2EE data
  final E2EEExtension? e2ee;

  /// Account data
  final AccountDataExtension? accountData;

  /// Receipts
  final ReceiptsExtension? receipts;

  /// Typing notifications
  final TypingExtension? typing;

  /// Presence updates
  final PresenceExtension? presence;
}

/// To-device extension data
class ToDeviceExtension {

  ToDeviceExtension({this.nextBatch, this.events});

  factory ToDeviceExtension.fromJson(Map<String, dynamic> json) {
    return ToDeviceExtension(
      nextBatch: json['next_batch'] as String?,
      events: json['events'] != null
          ? (json['events'] as List<dynamic>)
                .map((e) => ToDeviceEvent.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
    );
  }
  /// Next batch token
  final String? nextBatch;

  /// To-device events
  final List<ToDeviceEvent>? events;
}

/// E2EE extension data
class E2EEExtension {

  E2EEExtension({
    this.deviceLists,
    this.deviceOneTimeKeysCount,
    this.deviceUnusedFallbackKeyTypes,
  });

  factory E2EEExtension.fromJson(Map<String, dynamic> json) {
    return E2EEExtension(
      deviceLists: json['device_lists'] != null
          ? DeviceListsUpdate.fromJson(
              json['device_lists'] as Map<String, dynamic>,
            )
          : null,
      deviceOneTimeKeysCount: json['device_one_time_keys_count'] != null
          ? (json['device_one_time_keys_count'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(key, value as int),
            )
          : null,
      deviceUnusedFallbackKeyTypes:
          json['device_unused_fallback_key_types'] != null
          ? (json['device_unused_fallback_key_types'] as List<dynamic>)
                .map((e) => e as String)
                .toList()
          : null,
    );
  }
  /// Device list changes
  final DeviceListsUpdate? deviceLists;

  /// One-time key counts
  final Map<String, int>? deviceOneTimeKeysCount;

  /// Unused fallback key algorithms
  final List<String>? deviceUnusedFallbackKeyTypes;
}

/// Account data extension
class AccountDataExtension {

  AccountDataExtension({this.global, this.rooms});

  factory AccountDataExtension.fromJson(Map<String, dynamic> json) {
    return AccountDataExtension(
      global: json['global'] != null
          ? (json['global'] as List<dynamic>)
                .map((e) => BasicEvent.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
      rooms: json['rooms'] != null
          ? (json['rooms'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                (value as List<dynamic>)
                    .map((e) => BasicEvent.fromJson(e as Map<String, dynamic>))
                    .toList(),
              ),
            )
          : null,
    );
  }
  /// Global account data events
  final List<BasicEvent>? global;

  /// Room-specific account data
  final Map<String, List<BasicEvent>>? rooms;
}

/// Receipts extension
class ReceiptsExtension {

  ReceiptsExtension({this.rooms});

  factory ReceiptsExtension.fromJson(Map<String, dynamic> json) {
    return ReceiptsExtension(
      rooms: json['rooms'] != null
          ? (json['rooms'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                ReceiptContent.fromJson(value as Map<String, dynamic>),
              ),
            )
          : null,
    );
  }
  /// Room receipts
  final Map<String, ReceiptContent>? rooms;
}

/// Receipt content for a room
class ReceiptContent {

  ReceiptContent({required this.content});

  factory ReceiptContent.fromJson(Map<String, dynamic> json) {
    return ReceiptContent(content: json);
  }
  final Map<String, dynamic> content;
}

/// Typing extension
class TypingExtension {

  TypingExtension({this.rooms});

  factory TypingExtension.fromJson(Map<String, dynamic> json) {
    return TypingExtension(
      rooms: json['rooms'] != null
          ? (json['rooms'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                TypingContent.fromJson(value as Map<String, dynamic>),
              ),
            )
          : null,
    );
  }
  /// Rooms with typing users
  final Map<String, TypingContent>? rooms;
}

/// Typing content for a room
class TypingContent {

  TypingContent({required this.userIds});

  factory TypingContent.fromJson(Map<String, dynamic> json) {
    return TypingContent(
      userIds:
          (json['user_ids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
  /// User IDs of users currently typing
  final List<String> userIds;
}

/// Presence extension
class PresenceExtension {

  PresenceExtension({this.events});

  factory PresenceExtension.fromJson(Map<String, dynamic> json) {
    return PresenceExtension(
      events: json['events'] != null
          ? (json['events'] as List<dynamic>)
                .map((e) => BasicEvent.fromJson(e as Map<String, dynamic>))
                .toList()
          : null,
    );
  }
  /// Presence events
  final List<BasicEvent>? events;
}
