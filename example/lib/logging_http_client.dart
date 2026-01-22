import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// HTTP client wrapper that logs all requests and responses
class LoggingHttpClient extends http.BaseClient {
  final http.Client _inner;

  LoggingHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (kDebugMode) {
      print('┌── HTTP REQUEST ──────────────────────────────────');
      print('│ ${request.method} ${request.url}');
      if (request.headers.isNotEmpty) {
        print('│ Headers: ${request.headers.keys.join(', ')}');
      }
      if (request is http.Request && request.body.isNotEmpty) {
        try {
          final body = jsonDecode(request.body);
          print(
            '│ Body: ${const JsonEncoder.withIndent('  ').convert(body).split('\n').join('\n│ ')}',
          );
        } catch (_) {
          print(
            '│ Body: ${request.body.substring(0, request.body.length.clamp(0, 200))}...',
          );
        }
      }
      print('└──────────────────────────────────────────────────');
    }

    final stopwatch = Stopwatch()..start();
    final response = await _inner.send(request);
    stopwatch.stop();

    if (kDebugMode) {
      print('┌── HTTP RESPONSE (${stopwatch.elapsedMilliseconds}ms) ────────────');
      print('│ ${response.statusCode} ${request.url.path}');
      print('└──────────────────────────────────────────────────');
    }

    return response;
  }

  @override
  void close() {
    _inner.close();
  }
}
