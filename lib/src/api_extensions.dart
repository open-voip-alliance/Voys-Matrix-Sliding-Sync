import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix_api_lite.dart';

/// Extension methods for Matrix API to support sliding sync endpoints
extension SlidingSyncMatrixApiExtensions on MatrixApi {
  /// Performs a sliding sync request (MSC4186 - Simplified Sliding Sync).
  ///
  /// Uses the unstable endpoint with the org.matrix.simplified_msc3575
  /// identifier.
  ///
  /// [body] The sliding sync request body (lists, room subscriptions,
  /// extensions).
  ///
  /// [pos] and [timeout] are sent as query parameters. Synapse only reads
  /// them from the query string and silently ignores them in the body, which
  /// turns every request into an initial sync that returns immediately.
  ///
  /// [abortTrigger] cancels the request when it completes, for `httpClient`
  /// implementations that honour [http.Abortable] (the default `http.Client`
  /// does). The returned future then fails with [http.RequestAbortedException].
  /// Clients that don't honour it simply let the request run to completion.
  ///
  /// This builds the request itself instead of going through
  /// [MatrixApi.request] because that method offers no way to abort an
  /// in-flight request, which a long-poll needs. The response handling
  /// mirrors [MatrixApi.request].
  Future<Map<String, Object?>> slidingSync(
    Map<String, Object?> body, {
    String? pos,
    int? timeout,
    Future<void>? abortTrigger,
  }) async {
    final homeserver = this.homeserver;
    if (homeserver == null) {
      throw Exception('No homeserver specified.');
    }

    final query = <String, String>{
      if (pos != null) 'pos': pos,
      if (timeout != null) 'timeout': timeout.toString(),
    };
    // Matrix paths are relative to /_matrix, so this becomes
    // /_matrix/client/unstable/org.matrix.simplified_msc3575/sync
    final url = homeserver.resolveUri(
      Uri(
        path: '_matrix/client/unstable/org.matrix.simplified_msc3575/sync',
        queryParameters: query.isEmpty ? null : query,
      ),
    );

    final request =
        http.AbortableRequest('POST', url, abortTrigger: abortTrigger)
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
    final accessToken = this.accessToken;
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }

    final response = await http.Response.fromStream(
      await httpClient.send(request),
    );
    final responseBody = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 500 && response.statusCode < 600) {
      throw Exception(responseBody);
    }
    if (response.statusCode >= 400) {
      throw MatrixException(response);
    }
    return jsonDecode(responseBody) as Map<String, Object?>;
  }
}
