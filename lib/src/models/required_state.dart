/// Represents the required state configuration for sliding sync
class RequiredStateRequest {
  RequiredStateRequest({required this.include}) {
    if (include.length > 100) {
      throw ArgumentError('Maximum 100 state elements allowed in include list');
    }
  }

  /// Creates a minimal required state for room list display
  factory RequiredStateRequest.minimal() {
    return RequiredStateRequest(
      include: [
        ['m.room.member', r'$LAZY'], // Lazy-load members
        // $LAZY only covers timeline senders; the SDK needs our own member
        // (e.g. push rule evaluation) and fetches it per room otherwise.
        ['m.room.member', r'$ME'],
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
        ['m.room.member', r'$ME'],
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

  /// State events to include in the response.
  /// Format: [["event_type", "state_key"]]
  /// Special values:
  /// - "*" as state_key means all state keys for that event type
  /// - "$LAZY" for m.room.member means lazy-load member events
  /// - "$ME" as state_key means the current user's id
  ///
  /// Note: The server (Synapse MSC4186 implementation) expects a plain list
  /// format rather than the object format described in the MSC4186 spec draft.
  final List<List<String>> include;

  List<List<String>> toJson() => include;
}
