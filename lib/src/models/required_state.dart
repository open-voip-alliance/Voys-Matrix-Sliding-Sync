// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

/// Represents the required state configuration for sliding sync
class RequiredStateRequest {

  RequiredStateRequest({required this.include, this.exclude}) {
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
        ['m.room.member', r'$LAZY'], // Lazy-load members
        ['m.room.name', ''],
        ['m.room.avatar', ''],
        ['m.room.topic', ''],
        ['m.room.canonical_alias', ''],
        ['m.room.join_rules', ''],
      ],
    );
  }

  /// Creates a full required state for detailed room view
  factory RequiredStateRequest.full() {
    return RequiredStateRequest(
      include: [
        ['m.room.member', r'$LAZY'],
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
    );
  }

  factory RequiredStateRequest.fromJson(Map<String, dynamic> json) {
    return RequiredStateRequest(
      include: (json['include'] as List<dynamic>)
          .map((e) => (e as List<dynamic>).map((s) => s as String).toList())
          .toList(),
      exclude: json['exclude'] != null
          ? (json['exclude'] as List<dynamic>)
                .map(
                  (e) => (e as List<dynamic>).map((s) => s as String).toList(),
                )
                .toList()
          : null,
    );
  }
  /// State events to include in the response
  /// Format: [["event_type", "state_key"]]
  /// Special values:
  /// - "*" as state_key means all state keys for that event type
  /// - "$LAZY" for m.room.member means lazy-load member events
  final List<List<String>> include;

  /// State events to exclude from the response (optional)
  final List<List<String>>? exclude;

  dynamic toJson() {
    // Matrix.org's implementation expects a plain list, not an object with 'include'
    // Return just the include list for compatibility
    return include;
  }
}
