// Copyright (c) 2025 Famedly GmbH
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:matrix/matrix_api_lite.dart';

/// Extension methods for Matrix API to support sliding sync endpoints
extension SlidingSyncMatrixApiExtensions on MatrixApi {
  /// Performs a sliding sync request (MSC4186 - Simplified Sliding Sync).
  ///
  /// Uses the unstable endpoint with the org.matrix.simplified_msc3575 identifier.
  ///
  /// [body] The sliding sync request body
  /// [timeout] Optional timeout in milliseconds for long-polling
  Future<Map<String, Object?>> slidingSync(
    Map<String, Object?> body, {
    int? timeout,
  }) async {
    final query = <String, Object?>{};
    if (timeout != null) {
      query['timeout'] = timeout.toString();
    }

    // MSC4186 (Simplified Sliding Sync) uses the org.matrix.simplified_msc3575 endpoint identifier
    // Note: Matrix paths are relative to /_matrix, so this becomes /_matrix/client/unstable/org.matrix.simplified_msc3575/sync
    return await request(
      RequestType.POST,
      '/client/unstable/org.matrix.simplified_msc3575/sync',
      data: body,
      query: query,
    );
  }
}
