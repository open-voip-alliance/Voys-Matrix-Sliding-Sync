import 'package:matrix/matrix.dart';
import 'package:voys_matrix_sliding_sync/src/sliding_sync.dart';

/// Extension methods for [Client] to support sliding sync functionality
extension SlidingSyncClientExtensions on Client {
  /// Creates a new sliding sync instance with the specified connection ID.
  ///
  /// Sliding sync (MSC4186) is an efficient synchronization protocol that allows
  /// clients to fetch only the data they need. It's particularly useful
  /// for mobile clients and clients with limited bandwidth.
  ///
  /// Example usage:
  /// ```dart
  /// final sync = client.createSlidingSync('main')
  ///   ..addList(SlidingSyncList.allRoomsMinimal(name: 'all_rooms'))
  ///   ..addList(SlidingSyncList.activeRooms(name: 'active'));
  ///
  /// await sync.startSync();
  /// ```
  SlidingSync createSlidingSync(String id) {
    return SlidingSync(id: id, client: this);
  }

  /// Creates a sliding sync builder for advanced configuration
  SlidingSyncBuilder createSlidingSyncBuilder(String id) {
    return SlidingSync.builder(id: id, client: this);
  }
}
