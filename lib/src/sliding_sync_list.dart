// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:voys_matrix_sliding_sync/src/models/filters.dart';
import 'package:voys_matrix_sliding_sync/src/models/required_state.dart';
import 'package:voys_matrix_sliding_sync/src/sync_mode.dart';

/// Manages a sliding sync list
class SlidingSyncList {
  /// Unique name for this list
  final String name;

  /// Sync mode for this list
  SyncMode _syncMode;

  /// Current loading state
  final StreamController<SlidingSyncListLoadingState> _stateController =
      StreamController<SlidingSyncListLoadingState>.broadcast();

  /// Current list of room IDs in order
  List<String> _roomIds = [];

  /// Total number of rooms matching filters
  int? _totalRoomCount;

  /// Timeline limit for rooms in this list
  int _timelineLimit;

  /// Required state configuration
  RequiredStateRequest? _requiredState;

  /// Room filters
  SlidingRoomFilter? _filters;

  /// Current ranges being synced
  List<List<int>> _ranges = [];

  /// Batch size for paging/growing modes
  int _batchSize;

  /// Current position for paging mode
  int _currentPageStart = 0;

  /// Maximum number of rooms to fetch
  int? _maximumNumberOfRooms;

  /// Whether to include hero members
  bool _includeHeroes;

  /// Current loading state
  SlidingSyncListLoadingState _state = SlidingSyncListLoadingState.notLoaded;

  SlidingSyncList({
    required this.name,
    SyncMode syncMode = SyncMode.selective,
    List<List<int>>? ranges,
    int timelineLimit = 1,
    RequiredStateRequest? requiredState,
    SlidingRoomFilter? filters,
    int batchSize = 20,
    int? maximumNumberOfRooms,
    bool includeHeroes = false,
  }) : _syncMode = syncMode,
       _timelineLimit = timelineLimit,
       _requiredState = requiredState,
       _filters = filters,
       _batchSize = batchSize,
       _maximumNumberOfRooms = maximumNumberOfRooms,
       _includeHeroes = includeHeroes {
    if (ranges != null) {
      _ranges = ranges;
    } else {
      _ranges = _generateRanges();
    }
  }

  /// Creates a list for all rooms with minimal data
  factory SlidingSyncList.allRoomsMinimal({
    required String name,
    int batchSize = 20,
  }) {
    return SlidingSyncList(
      name: name,
      syncMode: SyncMode.growing,
      timelineLimit: 0,
      requiredState: RequiredStateRequest.minimal(),
      batchSize: batchSize,
      includeHeroes: true,
    );
  }

  /// Creates a list for active rooms with timeline
  factory SlidingSyncList.activeRooms({
    required String name,
    int timelineLimit = 10,
    int batchSize = 20,
  }) {
    return SlidingSyncList(
      name: name,
      syncMode: SyncMode.paging,
      timelineLimit: timelineLimit,
      requiredState: RequiredStateRequest.full(),
      batchSize: batchSize,
      includeHeroes: true,
    );
  }

  /// Creates a list for a specific space
  factory SlidingSyncList.space({
    required String name,
    required String spaceId,
    int batchSize = 50,
  }) {
    return SlidingSyncList(
      name: name,
      syncMode: SyncMode.growing,
      timelineLimit: 1,
      requiredState: RequiredStateRequest.minimal(),
      filters: SlidingRoomFilter.inSpace(spaceId),
      batchSize: batchSize,
      includeHeroes: true,
    );
  }

  /// Stream of state changes
  Stream<SlidingSyncListLoadingState> get stateStream =>
      _stateController.stream;

  /// Current state
  SlidingSyncListLoadingState get state => _state;

  /// Current room IDs in order
  List<String> get roomIds => List.unmodifiable(_roomIds);

  /// Total number of rooms (if known)
  int? get totalRoomCount => _totalRoomCount;

  /// Sync mode
  SyncMode get syncMode => _syncMode;

  /// Timeline limit
  int get timelineLimit => _timelineLimit;

  /// Required state
  RequiredStateRequest? get requiredState => _requiredState;

  /// Filters
  SlidingRoomFilter? get filters => _filters;

  /// Current ranges
  List<List<int>> get ranges => List.unmodifiable(_ranges);

  /// Whether all rooms have been loaded
  bool get isFullyLoaded => _state == SlidingSyncListLoadingState.fullyLoaded;

  /// Updates the sync mode
  void setSyncMode(SyncMode mode) {
    if (_syncMode != mode) {
      _syncMode = mode;
      _currentPageStart = 0;
      _ranges = _generateRanges();
    }
  }

  /// Updates the timeline limit
  void setTimelineLimit(int limit) {
    _timelineLimit = limit;
  }

  /// Updates the required state
  void setRequiredState(RequiredStateRequest? requiredState) {
    _requiredState = requiredState;
  }

  /// Updates the filters
  void setFilters(SlidingRoomFilter? filters) {
    _filters = filters;
    // Reset state when filters change
    _state = SlidingSyncListLoadingState.notLoaded;
    _updateState(_state);
    _roomIds.clear();
    _totalRoomCount = null;
    _currentPageStart = 0;
    _ranges = _generateRanges();
  }

  /// Updates the ranges
  /// For selective mode: sets the exact ranges to maintain
  /// For growing mode: restores the cached range to continue from where it left off
  void setRanges(List<List<int>> ranges) {
    if (_syncMode == SyncMode.selective || _syncMode == SyncMode.growing) {
      _ranges = ranges;
    }
  }

  /// Loads the next page (for paging mode)
  void loadNextPage() {
    if (_syncMode == SyncMode.paging) {
      _currentPageStart += _batchSize;
      _ranges = _generateRanges();
    }
  }

  /// Loads more rooms (for growing mode)
  void loadMore() {
    if (_syncMode == SyncMode.growing) {
      _ranges = _generateRanges();
    }
  }

  /// Resets the list
  void reset() {
    _roomIds.clear();
    _totalRoomCount = null;
    _currentPageStart = 0;
    _ranges = _generateRanges();
    _state = SlidingSyncListLoadingState.notLoaded;
    _updateState(_state);
  }

  /// Generates ranges based on sync mode
  List<List<int>> _generateRanges() {
    switch (_syncMode) {
      case SyncMode.selective:
        // Use explicitly set ranges
        return _ranges;

      case SyncMode.paging:
        // Single range for current page
        final start = _currentPageStart;
        var end = start + _batchSize - 1;
        if (_maximumNumberOfRooms != null) {
          end = end.clamp(0, _maximumNumberOfRooms! - 1);
        }
        if (start > end) {
          return [];
        }
        return [
          [start, end],
        ];

      case SyncMode.growing:
        // Expanding range from 0
        final currentEnd = _ranges.isEmpty
            ? _batchSize - 1
            : _ranges.last[1] + _batchSize;
        var end = currentEnd;
        if (_maximumNumberOfRooms != null) {
          end = end.clamp(0, _maximumNumberOfRooms! - 1);
        }
        return [
          [0, end],
        ];
    }
  }

  /// Converts to JSON for request
  Map<String, dynamic> toRequestJson() {
    final json = <String, dynamic>{};

    if (_ranges.isNotEmpty) {
      json['ranges'] = _ranges;
    }

    json['timeline_limit'] = _timelineLimit;

    if (_requiredState != null) {
      json['required_state'] = _requiredState!.toJson();
    }

    if (_filters != null) {
      final filterJson = _filters!.toJson();
      if (filterJson.isNotEmpty) {
        json['filters'] = filterJson;
      }
    }

    if (_includeHeroes) {
      json['include_heroes'] = true;
    }

    return json;
  }

  /// Updates from a sync response
  void updateFromResponse({
    required int? count,
    required List<String>? roomIds,
    required List<List<int>>? ranges,
  }) {
    // Update total count
    if (count != null) {
      _totalRoomCount = count;
    }

    // Update room IDs based on ranges
    if (roomIds != null && ranges != null) {
      for (var i = 0; i < ranges.length && i < roomIds.length; i++) {
        final range = ranges[i];
        if (range.length == 2) {
          final start = range[0];
          final end = range[1];
          final rangeRoomIds = roomIds.sublist(
            i * (end - start + 1),
            (i + 1) * (end - start + 1),
          );

          // Ensure list is large enough
          while (_roomIds.length <= end) {
            _roomIds.add('');
          }

          // Update the range
          for (var j = 0; j < rangeRoomIds.length && start + j <= end; j++) {
            _roomIds[start + j] = rangeRoomIds[j];
          }
        }
      }
    }

    // Update state
    _updateLoadingState();
  }

  /// Apply a SYNC operation - replaces room IDs in a range
  /// Returns true if any room IDs actually changed
  bool applySyncOp(List<int> range, List<String> roomIds) {
    if (range.length != 2) return false;

    final start = range[0];
    final end = range[1];

    // If we're in preloaded state and receive a SYNC starting from 0 that's smaller
    // than our cached range, the server is re-syncing from scratch. Clear cache and start fresh.
    if (_state == SlidingSyncListLoadingState.preloaded && start == 0) {
      final cachedRoomCount = _roomIds.where((id) => id.isNotEmpty).length;
      if (end + 1 < cachedRoomCount) {
        _roomIds.clear();
        _state = SlidingSyncListLoadingState.notLoaded;
      }
    }

    // Ensure list is large enough
    while (_roomIds.length <= end) {
      _roomIds.add('');
    }

    // Before syncing, remove any rooms that will be synced if they already exist
    // OUTSIDE the sync range (prevents duplicates when room order changes)
    for (var syncIndex = 0; syncIndex < roomIds.length; syncIndex++) {
      final roomId = roomIds[syncIndex];
      if (roomId.isEmpty) continue;

      // Search for duplicates outside the sync range
      for (var i = 0; i < _roomIds.length; i++) {
        // Skip if this is within the sync range
        if (i >= start && i <= end) continue;

        // If we find this room outside the sync range, remove it
        if (_roomIds[i] == roomId) {
          _roomIds.removeAt(i);

          // Adjust our loop index since we removed an item
          if (i < start) {
            // Removed before the sync range, need to check this index again
            i--;
          }

          // After removal, ensure list is still large enough
          while (_roomIds.length <= end) {
            _roomIds.add('');
          }
        }
      }
    }

    // Now replace room IDs in the range and track if anything changed
    var index = 0;
    var hasChanges = false;
    for (var i = start; i <= end && index < roomIds.length; i++) {
      if (_roomIds[i] != roomIds[index]) {
        _roomIds[i] = roomIds[index];
        hasChanges = true;
      }
      index++;
    }

    _updateLoadingState();
    return hasChanges;
  }

  /// Apply an INSERT operation - inserts a room at a specific index
  void applyInsertOp(int index, String roomId) {
    // Check if room already exists in the list
    final existingIndex = _roomIds.indexOf(roomId);

    if (existingIndex != -1) {
      // Room already exists - this could be a move operation or a duplicate INSERT

      // Remove it from its current position first
      _roomIds.removeAt(existingIndex);

      // Adjust insertion index if we removed something before it
      final adjustedIndex = existingIndex < index ? index - 1 : index;

      // Insert at new position
      if (adjustedIndex >= _roomIds.length) {
        _roomIds.add(roomId);
      } else {
        _roomIds.insert(adjustedIndex, roomId);
      }
      // Don't increment count since we're just moving, not adding
    } else {
      // Room doesn't exist - normal insertion

      if (index >= _roomIds.length) {
        _roomIds.add(roomId);
      } else {
        _roomIds.insert(index, roomId);
      }

      // Increment total count if known
      if (_totalRoomCount != null) {
        _totalRoomCount = _totalRoomCount! + 1;
      }
    }

    _updateLoadingState();
  }

  /// Apply a DELETE operation - removes a room at a specific index
  void applyDeleteOp(int index) {
    if (index < _roomIds.length) {
      _roomIds.removeAt(index);

      // Decrement total count if known
      if (_totalRoomCount != null && _totalRoomCount! > 0) {
        _totalRoomCount = _totalRoomCount! - 1;
      }
    }

    _updateLoadingState();
  }

  /// Apply an INVALIDATE operation - clears rooms in a range
  void applyInvalidateOp(List<int> range) {
    if (range.length != 2) return;

    final start = range[0];
    final end = range[1];

    // Clear room IDs in the range
    for (var i = start; i <= end && i < _roomIds.length; i++) {
      _roomIds[i] = '';
    }

    // Mark the range as needing refresh
    _state = SlidingSyncListLoadingState.partiallyLoaded;
    _updateState(_state);
  }

  /// Updates the loading state based on current data
  void _updateLoadingState() {
    final newState = _calculateLoadingState();
    if (newState != _state) {
      _state = newState;
      _updateState(newState);
    }
  }

  /// Calculates the current loading state
  SlidingSyncListLoadingState _calculateLoadingState() {
    if (_roomIds.isEmpty && _totalRoomCount == null) {
      return SlidingSyncListLoadingState.notLoaded;
    }

    // In selective mode, consider fully loaded since we're not progressively loading
    if (_syncMode == SyncMode.selective && _roomIds.isNotEmpty) {
      return SlidingSyncListLoadingState.fullyLoaded;
    }

    if (_totalRoomCount != null) {
      final loadedCount = _roomIds.where((id) => id.isNotEmpty).length;
      if (loadedCount >= _totalRoomCount!) {
        return SlidingSyncListLoadingState.fullyLoaded;
      }
    }

    return SlidingSyncListLoadingState.partiallyLoaded;
  }

  /// Updates state and notifies listeners
  void _updateState(SlidingSyncListLoadingState newState) {
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Marks as preloaded from cache
  void markAsPreloaded(List<String> cachedRoomIds, int? cachedCount) {
    _roomIds = List.from(cachedRoomIds);
    _totalRoomCount = cachedCount;
    _state = SlidingSyncListLoadingState.preloaded;
    _updateState(_state);
  }

  /// Disposes resources
  void dispose() {
    unawaited(_stateController.close());
  }
}
