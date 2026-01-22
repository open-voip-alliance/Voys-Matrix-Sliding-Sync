// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:voys_matrix_sliding_sync/src/models/response.dart';

/// Update from a sliding sync operation
class SlidingSyncUpdate {
  /// New position token
  final String pos;

  /// List updates
  final Map<String, SlidingSyncListUpdate> lists;

  /// Room updates
  final Map<String, SlidingSyncRoomUpdate> rooms;

  /// Extension updates
  final SlidingSyncExtensionResponse? extensions;

  SlidingSyncUpdate({
    required this.pos,
    required this.lists,
    required this.rooms,
    this.extensions,
  });
}

/// Update for a sliding sync list
class SlidingSyncListUpdate {
  /// Total room count
  final int? count;

  /// Operations applied
  final List<SlidingSyncOperation>? ops;

  SlidingSyncListUpdate({
    this.count,
    this.ops,
  });
}

/// Update for a room
class SlidingSyncRoomUpdate {
  /// Room ID
  final String roomId;

  /// Room data
  final SlidingSyncRoomData roomData;

  SlidingSyncRoomUpdate({
    required this.roomId,
    required this.roomData,
  });
}
