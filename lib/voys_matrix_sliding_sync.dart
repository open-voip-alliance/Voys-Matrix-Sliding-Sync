/// A sliding sync implementation for Matrix (MSC4186).
///
/// This library provides efficient synchronization for Matrix chat clients
/// using the sliding sync protocol, which allows clients to fetch only the
/// data they need.
///
/// ## Basic Usage
///
/// ```dart
/// import 'package:voys_matrix_sliding_sync/voys_matrix_sliding_sync.dart';
///
/// final slidingSync = SlidingSync.builder(id: 'main', client: client)
///     .withExtensions(SlidingSyncExtensions.essential())
///     .addList(SlidingSyncList(
///       name: 'all_rooms',
///       syncMode: SyncMode.growing,
///       timelineLimit: 1,
///       requiredState: RequiredStateRequest.minimal(),
///       batchSize: 100,
///       includeHeroes: true,
///     ))
///     .build();
///
/// await slidingSync.startSync();
/// ```
library;

export 'src/client_extensions.dart' show SlidingSyncClientExtensions;
export 'src/models/filters.dart' show SlidingRoomFilter;
export 'src/models/request.dart' show RoomSubscription, SlidingSyncExtensions;
export 'src/models/required_state.dart' show RequiredStateRequest;
export 'src/models/response.dart'
    show
        SlidingSyncExtensionResponse,
        SlidingSyncOperation,
        SlidingSyncRoomData;
export 'src/sliding_sync.dart' show SlidingSync, SlidingSyncBuilder;
export 'src/sliding_sync_list.dart' show SlidingSyncList;
export 'src/sliding_sync_only_client.dart' show SlidingSyncOnlyClient;
export 'src/sliding_sync_update.dart'
    show SlidingSyncListUpdate, SlidingSyncRoomUpdate, SlidingSyncUpdate;
export 'src/sync_mode.dart'
    show SlidingSyncListLoadingState, SlidingSyncStatus, SyncMode;
