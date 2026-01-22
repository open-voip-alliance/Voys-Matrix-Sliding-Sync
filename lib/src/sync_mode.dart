// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

/// Sync mode for sliding sync lists
enum SyncMode {
  /// Client specifies exact ranges to fetch
  selective,

  /// Sequential pagination through the list (0-19 → 20-39 → 40-59...)
  paging,

  /// Expanding window from the start (0-19 → 0-39 → 0-59...)
  growing,
}

/// Loading state for sliding sync lists
enum SlidingSyncListLoadingState {
  /// List has not been loaded yet
  notLoaded,

  /// List was previously loaded from cache
  preloaded,

  /// List is partially loaded
  partiallyLoaded,

  /// List is fully loaded
  fullyLoaded,
}

/// Sync status for sliding sync
enum SlidingSyncStatus {
  /// Not syncing
  stopped,

  /// Waiting for server response
  waitingForResponse,

  /// Processing sync response
  processing,

  /// Sync completed
  finished,

  /// Error occurred
  error,
}
