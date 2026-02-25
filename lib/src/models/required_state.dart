// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

/// Represents the required state configuration for sliding sync
class RequiredStateRequest {

  RequiredStateRequest({
    required this.include,
    this.exclude,
    this.lazyMembers,
  }) {
    // Validate input
    if (include.length > 100) {
      throw ArgumentError('Maximum 100 state elements allowed in include list');
    }
    if (exclude != null && exclude!.length > 100) {
      throw ArgumentError('Maximum 100 state elements allowed in exclude list');
    }
  }

  /// Creates a minimal required state for room list display
  factory RequiredStateRequest.minimal() {
    return RequiredStateRequest(
      include: [
        ['m.room.name', ''],
        ['m.room.avatar', ''],
        ['m.room.topic', ''],
        ['m.room.canonical_alias', ''],
        ['m.room.join_rules', ''],
      ],
      lazyMembers: true,
    );
  }

  /// Creates a full required state for detailed room view
  factory RequiredStateRequest.full() {
    return RequiredStateRequest(
      include: [
        ['m.room.name', ''],
        ['m.room.avatar', ''],
        ['m.room.topic', ''],
        ['m.room.canonical_alias', ''],
        ['m.room.join_rules', ''],
        ['m.room.history_visibility', ''],
        ['m.room.guest_access', ''],
        ['m.room.power_levels', ''],
        ['m.room.encryption', ''],
        ['m.room.create', ''],
        ['m.room.tombstone', ''],
        ['m.space.child', '*'], // All space children
        ['m.space.parent', '*'], // All space parents
      ],
      lazyMembers: true,
    );
  }

  /// State events to include in the response.
  /// Format: [["event_type", "state_key"]]
  /// Special values:
  /// - "*" as state_key means all state keys for that event type
  /// - An empty list entry [] serializes to {} which matches all state events
  final List<List<String>> include;

  /// State events to exclude from the response (optional)
  final List<List<String>>? exclude;

  /// Lazy-load room member events (m.room.member) rather than including them
  /// in required_state. Equivalent to the MSC4186 `lazy_members` flag.
  final bool? lazyMembers;

  Map<String, dynamic> toJson() {
    Map<String, dynamic> elementToJson(List<String> pair) {
      if (pair.isEmpty) return {};
      return {
        'type': pair[0],
        if (pair.length > 1) 'state_key': pair[1],
      };
    }

    return {
      'include': include.map(elementToJson).toList(),
      if (exclude != null && exclude!.isNotEmpty)
        'exclude': exclude!.map(elementToJson).toList(),
      if (lazyMembers ?? false) 'lazy_members': true,
    };
  }
}
