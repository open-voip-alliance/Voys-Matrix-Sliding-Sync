/// Filters for sliding sync room lists
class SlidingRoomFilter {
  SlidingRoomFilter({
    this.isInvited,
    this.isKnocked,
    this.isDm,
    this.isEncrypted,
    this.spaces,
    this.roomTypes,
    this.notRoomTypes,
    this.roomNameLike,
    this.tags,
    this.notTags,
    this.assignedTo,
    this.responded,
    this.involving,
    this.unread,
  });

  /// Creates a filter for rooms within a specific space
  factory SlidingRoomFilter.inSpace(String spaceId) {
    return SlidingRoomFilter(spaces: [spaceId]);
  }

  /// Filter by invitation status
  final bool? isInvited;

  /// Filter by knock status
  final bool? isKnocked;

  /// Filter by direct message status
  final bool? isDm;

  /// Filter by encryption status
  /// null = all rooms, true = encrypted only, false = unencrypted only
  final bool? isEncrypted;

  /// Filter by parent space IDs
  final List<String>? spaces;

  /// Include specific room types
  final List<String>? roomTypes;

  /// Exclude specific room types
  final List<String>? notRoomTypes;

  /// Filter by room name (partial match)
  final String? roomNameLike;

  /// Filter by tags (e.g., "m.favourite", "m.lowpriority")
  final List<String>? tags;

  /// Exclude rooms with specific tags
  final List<String>? notTags;

  /// Voys-specific extension (`co.voys.assigned_to` state event). Only rooms
  /// whose assignee is in this list are included; `null` matches unassigned
  /// rooms.
  final List<String?>? assignedTo;

  /// Voys-specific extension (`co.voys.responded` state events, one per
  /// responder). Only rooms where one of these identifiers has responded are
  /// included.
  final List<String>? responded;

  /// Voys-specific extension (`co.voys.responded` state events, one per
  /// responder). Only rooms where one of these identifiers is the assignee
  /// OR has responded are included -- an OR across `assignedTo`/`responded`,
  /// unlike every other filter field which is AND'd together.
  final List<String>? involving;

  /// Voys-specific extension. If `true`, only rooms with unread content are
  /// included (the same notification count used for the `notification_count`
  /// field on each room, independent of `co.voys.responded` or room mute
  /// state).
  final bool? unread;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};

    if (isInvited != null) json['is_invited'] = isInvited;
    if (isKnocked != null) json['is_knocked'] = isKnocked;
    if (isDm != null) json['is_dm'] = isDm;
    if (isEncrypted != null) json['is_encrypted'] = isEncrypted;
    if (spaces != null && spaces!.isNotEmpty) json['spaces'] = spaces;
    if (roomTypes != null && roomTypes!.isNotEmpty) {
      json['room_types'] = roomTypes;
    }
    if (notRoomTypes != null && notRoomTypes!.isNotEmpty) {
      json['not_room_types'] = notRoomTypes;
    }
    if (roomNameLike != null) json['room_name_like'] = roomNameLike;
    if (tags != null && tags!.isNotEmpty) json['tags'] = tags;
    if (notTags != null && notTags!.isNotEmpty) json['not_tags'] = notTags;
    if (assignedTo != null && assignedTo!.isNotEmpty) {
      json['assigned_to'] = assignedTo;
    }
    if (responded != null && responded!.isNotEmpty) {
      json['responded'] = responded;
    }
    if (involving != null && involving!.isNotEmpty) {
      json['involving'] = involving;
    }
    if (unread != null) json['unread'] = unread;

    return json;
  }
}
