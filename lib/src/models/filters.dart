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
  });

  /// Creates a filter for all rooms
  factory SlidingRoomFilter.all() {
    return SlidingRoomFilter();
  }

  /// Creates a filter for direct messages only
  factory SlidingRoomFilter.directMessages() {
    return SlidingRoomFilter(isDm: true);
  }

  /// Creates a filter for group rooms only
  factory SlidingRoomFilter.groups() {
    return SlidingRoomFilter(isDm: false);
  }

  /// Creates a filter for invitations
  factory SlidingRoomFilter.invitations() {
    return SlidingRoomFilter(isInvited: true);
  }

  /// Creates a filter for spaces
  factory SlidingRoomFilter.spaces() {
    return SlidingRoomFilter(roomTypes: ['m.space']);
  }

  /// Creates a filter for favorite rooms
  factory SlidingRoomFilter.favorites() {
    return SlidingRoomFilter(tags: ['m.favourite']);
  }

  /// Creates a filter for rooms within a specific space
  factory SlidingRoomFilter.inSpace(String spaceId) {
    return SlidingRoomFilter(spaces: [spaceId]);
  }

  /// Creates a filter for encrypted rooms only
  factory SlidingRoomFilter.encryptedRooms() {
    return SlidingRoomFilter(isEncrypted: true);
  }

  /// Creates a filter for unencrypted rooms only
  factory SlidingRoomFilter.unencryptedRooms() {
    return SlidingRoomFilter(isEncrypted: false);
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

    return json;
  }
}
