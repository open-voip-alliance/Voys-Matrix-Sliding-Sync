import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_interceptor/http_interceptor.dart';
import 'package:talker/talker.dart';
import 'package:talker_http_logger/talker_http_logger.dart';

final talker = Talker();

/// Intercepts HTTP requests and logs the body with sensitive fields masked.
/// Must be placed before [TalkerHttpLogger] in the interceptors list, with
/// [TalkerHttpLoggerSettings.printRequestData] set to false to avoid logging
/// the unmasked body.
class _SensitiveDataMaskingInterceptor implements InterceptorContract {
  final bool enabled;

  const _SensitiveDataMaskingInterceptor({this.enabled = true});

  static const _sensitiveBodyKeys = {'user', 'password', 'token'};
  static const _sensitiveHeaderKeys = {'authorization'};

  @override
  Future<BaseRequest> interceptRequest({required BaseRequest request}) async {
    _logHeaders(request.headers);
    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final body = jsonDecode(request.body);
        if (body is Map) {
          final masked = _maskMap(body, _sensitiveBodyKeys);
          final prettyJson = const JsonEncoder.withIndent('  ').convert(masked);
          talker.debug('Request Data (masked):\n$prettyJson');
        }
      } catch (_) {}
    }
    return request;
  }

  void _logHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return;
    final masked = {
      for (final entry in headers.entries)
        entry.key: _sensitiveHeaderKeys.contains(entry.key.toLowerCase())
            ? '***'
            : entry.value,
    };
    final prettyJson = const JsonEncoder.withIndent('  ').convert(masked);
    talker.debug('Request Headers (masked):\n$prettyJson');
  }

  @override
  Future<BaseResponse> interceptResponse({
    required BaseResponse response,
  }) async => response;

  @override
  Future<bool> shouldInterceptRequest() async => enabled;

  @override
  Future<bool> shouldInterceptResponse() async => false;

  static Map<String, dynamic> _maskMap(
    Map<dynamic, dynamic> map,
    Set<String> sensitiveKeys,
  ) => {
    for (final entry in map.entries)
      entry.key as String: _maskValue(
        entry.key as String,
        entry.value,
        sensitiveKeys,
      ),
  };

  static dynamic _maskValue(
    String key,
    dynamic value,
    Set<String> sensitiveKeys,
  ) {
    if (sensitiveKeys.contains(key)) return '***';
    if (value is Map) return _maskMap(value, sensitiveKeys);
    return value;
  }
}

/// Creates an HTTP client with Talker logging.
/// Set [enabled] to false to disable all HTTP logging.
http.Client createLoggingHttpClient({bool enabled = false}) {
  return InterceptedClient.build(
    interceptors: [
      _SensitiveDataMaskingInterceptor(enabled: enabled),
      TalkerHttpLogger(
        talker: talker,
        settings: TalkerHttpLoggerSettings(
          enabled: enabled,
          printRequestHeaders:
              false, // handled by _SensitiveDataMaskingInterceptor
          printResponseHeaders: false,
          printRequestData:
              false, // handled by _SensitiveDataMaskingInterceptor
          printResponseData: false,
        ),
      ),
    ],
  );
}
