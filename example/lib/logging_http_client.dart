import 'package:http/http.dart' as http;
import 'package:http_interceptor/http_interceptor.dart';
import 'package:talker/talker.dart';
import 'package:talker_http_logger/talker_http_logger.dart';

final talker = Talker();

/// Creates an HTTP client with Talker logging
http.Client createLoggingHttpClient() {
  return InterceptedClient.build(
    interceptors: [
      TalkerHttpLogger(
        talker: talker,
        settings: const TalkerHttpLoggerSettings(
          printRequestHeaders: true,
          printResponseHeaders: false,
          printRequestData: true,
          printResponseData: false,
        ),
      ),
    ],
  );
}
