// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:matrix/matrix.dart';

/// Custom client that disables the normal sync completely.
///
/// This client extends [Client] and overrides the [sync] method to prevent
/// any normal Matrix sync requests from being made to the server. This is
/// useful when you want to use only sliding sync and avoid the overhead of
/// the traditional sync mechanism.
///
/// The overridden [sync] method returns an empty [SyncUpdate] without making
/// any HTTP requests, effectively intercepting all sync calls at the API level.
class SlidingSyncOnlyClient extends Client {
  SlidingSyncOnlyClient(
    super.clientName, {
    required super.database,
    super.enableDehydratedDevices,
    super.importantStateEvents,
    super.roomPreviewLastEvents,
    super.sendTimelineEventTimeout,
    super.httpClient,
  });

  /// Override the public sync method to prevent any sync calls.
  ///
  /// Returns a minimal SyncUpdate to prevent the SDK from making actual sync requests
  /// while avoiding errors that would indicate connection problems.
  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
    bool? useStateAfter,
  }) async {
    // Return a minimal SyncUpdate to prevent sync without causing errors
    return SyncUpdate(
      nextBatch: since ?? prevBatch ?? '',
    );
  }
}
