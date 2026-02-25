import 'package:voys_matrix_sliding_sync/src/models/response.dart';

/// Update from a sliding sync operation
class SlidingSyncUpdate {

  SlidingSyncUpdate({
    required this.pos,
    required this.lists,
    required this.rooms,
    this.extensions,
  });
  /// New position token
  final String pos;

  /// List updates
  final Map<String, SlidingSyncListUpdate> lists;

  /// Room updates
  final Map<String, SlidingSyncRoomUpdate> rooms;

  /// Extension updates
  final SlidingSyncExtensionResponse? extensions;
}

/// Update for a sliding sync list
class SlidingSyncListUpdate {

  SlidingSyncListUpdate({this.count, this.ops});
  /// Total room count
  final int? count;

  /// Operations applied
  final List<SlidingSyncOperation>? ops;
}

/// Update for a room
class SlidingSyncRoomUpdate {

  SlidingSyncRoomUpdate({required this.roomId, required this.roomData});
  /// Room ID
  final String roomId;

  /// Room data
  final SlidingSyncRoomData roomData;
}
