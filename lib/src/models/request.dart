import 'package:voys_matrix_sliding_sync/src/models/required_state.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync_list.dart';

/// Request structure for sliding sync
class SlidingSyncRequest {
  SlidingSyncRequest({
    this.connId,
    this.pos,
    this.timeout,
    this.setPresence,
    this.lists,
    this.roomSubscriptions,
    this.extensions,
    this.toDeviceSince,
  });

  /// Connection identifier (unique per client connection)
  final String? connId;

  /// Position token from previous response
  final String? pos;

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

  /// To-device batch token from the previous response (MSC4186 `extensions.to_device.since`)
  final String? toDeviceSince;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    if (connId != null) json['conn_id'] = connId;
    if (pos != null) json['pos'] = pos;
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
      final extensionsJson = extensions!.toJson(toDeviceSince: toDeviceSince);
      if (extensionsJson.isNotEmpty) {
        json['extensions'] = extensionsJson;
      }
    }

    return json;
  }
}

/// Subscription to a specific room
class RoomSubscription {
  RoomSubscription({
    this.timelineLimit,
    this.requiredState,
    this.includeHeroes,
  });

  /// Timeline event limit
  final int? timelineLimit;

  /// Required state events
  final RequiredStateRequest? requiredState;

  /// Include hero members
  final bool? includeHeroes;

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
}

/// Extensions configuration
class SlidingSyncExtensions {
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
      accountData: true,
    );
  }

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

  Map<String, dynamic> toJson({String? toDeviceSince}) {
    final json = <String, dynamic>{};

    if (toDevice) {
      json['to_device'] = {
        'enabled': true,
        if (toDeviceSince != null) 'since': toDeviceSince,
      };
    }
    if (e2ee) json['e2ee'] = {'enabled': true};
    if (accountData) json['account_data'] = {'enabled': true};
    if (receipts) json['receipts'] = {'enabled': true};
    if (typing) json['typing'] = {'enabled': true};
    if (presence) json['presence'] = {'enabled': true};

    return json;
  }
}
