// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:voys_matrix_sliding_sync/src/models/filters.dart';
import 'package:voys_matrix_sliding_sync/src/models/required_state.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_list.dart';

/// Request structure for sliding sync
class SlidingSyncRequest {
  /// Connection identifier (unique per client connection)
  final String? connId;

  /// Position token from previous response
  final String? pos;

  /// Transaction ID for sticky parameter tracking
  final String? txnId;

  /// Long-poll timeout in milliseconds
  final int? timeout;

  /// Set presence status
  final String? setPresence;

  /// Named room lists with their configurations
  final Map<String, SlidingSyncList>? lists;

  /// Explicit room subscriptions
  final Map<String, RoomSubscription>? roomSubscriptions;

  /// Extensions to enable
  final SlidingSyncExtensions? extensions;

  SlidingSyncRequest({
    this.connId,
    this.pos,
    this.txnId,
    this.timeout,
    this.setPresence,
    this.lists,
    this.roomSubscriptions,
    this.extensions,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    // Note: conn_id and txn_id might not be supported by all servers yet
    // Commenting out for compatibility
    // if (connId != null) json['conn_id'] = connId;
    if (pos != null) json['pos'] = pos;
    // if (txnId != null) json['txn_id'] = txnId;
    // MSC4186: timeout is in request body (only effective when pos is set)
    if (timeout != null) json['timeout'] = timeout;
    if (setPresence != null) json['set_presence'] = setPresence;
    if (lists != null && lists!.isNotEmpty) {
      json['lists'] = lists!.map(
        (key, value) => MapEntry(key, value.toRequestJson()),
      );
    }
    if (roomSubscriptions != null && roomSubscriptions!.isNotEmpty) {
      json['room_subscriptions'] = roomSubscriptions!.map(
        (key, value) => MapEntry(key, value.toJson()),
      );
    }
    if (extensions != null) {
      final extensionsJson = extensions!.toJson();
      if (extensionsJson.isNotEmpty) {
        json['extensions'] = extensionsJson;
      }
    }

    return json;
  }
}

/// Request representation for a sliding sync list
class SlidingSyncListRequest {
  /// Ranges to request (e.g., [[0, 19], [100, 119]])
  final List<List<int>>? ranges;

  /// Maximum timeline events per room
  final int? timelineLimit;

  /// Required state events
  final RequiredStateRequest? requiredState;

  /// Room filters
  final SlidingRoomFilter? filters;

  /// Sort order (default is by bump_stamp)
  final String? sortBy;

  /// Event types that affect the bump_stamp ordering
  final List<String>? bumpEventTypes;

  /// Include hero member info for room name calculation
  final bool? includeHeroes;

  SlidingSyncListRequest({
    this.ranges,
    this.timelineLimit,
    this.requiredState,
    this.filters,
    this.sortBy,
    this.bumpEventTypes,
    this.includeHeroes,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    // Request uses 'ranges' (plural array of arrays) even though MSC4186 simplified
    // the response to use 'range' (singular) in operations
    if (ranges != null && ranges!.isNotEmpty) {
      json['ranges'] = ranges;
    }
    if (timelineLimit != null) {
      json['timeline_limit'] = timelineLimit;
    }
    if (requiredState != null) {
      json['required_state'] = requiredState!.toJson();
    }
    if (filters != null) {
      json['filters'] = filters!.toJson();
    }
    if (sortBy != null) {
      json['sort_by'] = sortBy;
    }
    if (bumpEventTypes != null && bumpEventTypes!.isNotEmpty) {
      json['bump_event_types'] = bumpEventTypes;
    }
    if (includeHeroes != null) {
      json['include_heroes'] = includeHeroes;
    }

    return json;
  }

  factory SlidingSyncListRequest.fromJson(Map<String, dynamic> json) {
    return SlidingSyncListRequest(
      ranges: (json['ranges'] as List<dynamic>?)
          ?.map((e) => (e as List<dynamic>).map((n) => n as int).toList())
          .toList(),
      timelineLimit: json['timeline_limit'] as int?,
      requiredState: json['required_state'] != null
          ? RequiredStateRequest.fromJson(
              json['required_state'] as Map<String, dynamic>,
            )
          : null,
      filters: json['filters'] != null
          ? SlidingRoomFilter.fromJson(json['filters'] as Map<String, dynamic>)
          : null,
      sortBy: json['sort_by'] as String?,
      includeHeroes: json['include_heroes'] as bool?,
    );
  }
}

/// Subscription to a specific room
class RoomSubscription {
  /// Timeline event limit
  final int? timelineLimit;

  /// Required state events
  final RequiredStateRequest? requiredState;

  /// Include hero members
  final bool? includeHeroes;

  RoomSubscription({
    this.timelineLimit,
    this.requiredState,
    this.includeHeroes,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    if (timelineLimit != null) {
      json['timeline_limit'] = timelineLimit;
    }
    if (requiredState != null) {
      json['required_state'] = requiredState!.toJson();
    }
    if (includeHeroes != null) {
      json['include_heroes'] = includeHeroes;
    }

    return json;
  }

  factory RoomSubscription.fromJson(Map<String, dynamic> json) {
    return RoomSubscription(
      timelineLimit: json['timeline_limit'] as int?,
      requiredState: json['required_state'] != null
          ? RequiredStateRequest.fromJson(
              json['required_state'] as Map<String, dynamic>,
            )
          : null,
      includeHeroes: json['include_heroes'] as bool?,
    );
  }
}

/// Extensions configuration
class SlidingSyncExtensions {
  /// Enable to-device message extension
  final bool toDevice;

  /// Enable end-to-end encryption extension
  final bool e2ee;

  /// Enable account data extension
  final bool accountData;

  /// Enable receipts extension
  final bool receipts;

  /// Enable typing notifications extension
  final bool typing;

  /// Enable presence extension
  final bool presence;

  SlidingSyncExtensions({
    this.toDevice = false,
    this.e2ee = false,
    this.accountData = false,
    this.receipts = false,
    this.typing = false,
    this.presence = false,
  });

  /// Enable all extensions (except E2EE which is disabled)
  factory SlidingSyncExtensions.all() {
    return SlidingSyncExtensions(
      toDevice: true,
      e2ee: false,
      accountData: true,
      receipts: true,
      typing: true,
      presence: true,
    );
  }

  /// Enable essential extensions only (E2EE disabled)
  factory SlidingSyncExtensions.essential() {
    return SlidingSyncExtensions(
      toDevice: true,
      e2ee: false,
      accountData: true,
    );
  }

  /// No extensions (for testing/compatibility)
  factory SlidingSyncExtensions.none() {
    return SlidingSyncExtensions();
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    if (toDevice) json['to_device'] = {'enabled': true};
    if (e2ee) json['e2ee'] = {'enabled': true};
    if (accountData) json['account_data'] = {'enabled': true};
    if (receipts) json['receipts'] = {'enabled': true};
    if (typing) json['typing'] = {'enabled': true};
    if (presence) json['presence'] = {'enabled': true};

    return json;
  }

  factory SlidingSyncExtensions.fromJson(Map<String, dynamic> json) {
    return SlidingSyncExtensions(
      toDevice: json['to_device']?['enabled'] == true,
      e2ee: json['e2ee']?['enabled'] == true,
      accountData: json['account_data']?['enabled'] == true,
      receipts: json['receipts']?['enabled'] == true,
      typing: json['typing']?['enabled'] == true,
      presence: json['presence']?['enabled'] == true,
    );
  }
}
