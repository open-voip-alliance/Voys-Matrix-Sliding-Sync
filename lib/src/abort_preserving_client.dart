import 'dart:async';

import 'package:http/http.dart' as http;

/// Carries an [http.Abortable] request's `abortTrigger` through an
/// [http.Client] wrapper that rebuilds requests before forwarding them.
///
/// `package:http_interceptor`'s `InterceptedClient` copies every request into
/// a plain [http.Request], which drops the trigger. Sliding sync relies on the
/// trigger to cancel the in-flight long-poll when the loop is woken; without
/// it the abandoned request stays open on the server until it answers.
///
/// Each abortable request is tagged with a header that the middle client
/// preserves, and the trigger is re-attached on the inner side before the
/// request goes out. The header never reaches the server. A request the
/// middle client sends more than once (a retry policy) is only abortable the
/// first time.
///
/// ```dart
/// httpClient: AbortPreservingClient(
///   (inner) => InterceptedClient.build(interceptors: [...], client: inner),
/// )
/// ```
class AbortPreservingClient extends http.BaseClient {
  /// [buildMiddle] builds the request-copying client around [inner], which
  /// is what actually sends and defaults to a new [http.Client].
  AbortPreservingClient(
    http.Client Function(http.Client inner) buildMiddle, {
    http.Client? inner,
  }) {
    _middle = buildMiddle(_Inner(_triggers, inner ?? http.Client()));
  }

  static const _header = 'x-voys-abort-id';

  final _triggers = <String, Future<void>>{};
  late final http.Client _middle;
  var _nextId = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request case http.Abortable(:final abortTrigger?)) {
      final id = '${_nextId++}';
      _triggers[id] = abortTrigger;
      request.headers[_header] = id;
      return _middle.send(request).whenComplete(() => _triggers.remove(id));
    }
    return _middle.send(request);
  }

  @override
  void close() {
    _middle.close();
    super.close();
  }
}

class _Inner extends http.BaseClient {
  _Inner(this._triggers, this._client);

  final Map<String, Future<void>> _triggers;
  final http.Client _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final id = request.headers.remove(AbortPreservingClient._header);
    if (request case http.Abortable(abortTrigger: _?)) {
      // The middle client forwarded our own request object; nothing to do.
      return _client.send(request);
    }
    final trigger = id == null ? null : _triggers.remove(id);
    if (trigger == null) {
      return _client.send(request);
    }

    final abortable =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: trigger,
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = await request.finalize().toBytes()
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection;
    return _client.send(abortable);
  }

  @override
  void close() {
    _client.close();
    super.close();
  }
}
