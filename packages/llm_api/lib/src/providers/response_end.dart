import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:llm_api/src/llm_exception.dart';

/// Records how one streamed chat response ended and checks it once the
/// response body is complete.
///
/// Providers call [finish] when they see their end-of-response signal and
/// [truncate] when the model stopped at its output limit. [check] then turns
/// a body that ended without either into an [LlmInterruptedException] and a
/// truncated response into an [LlmTruncatedException].
class ResponseEnd {
  bool _finished = false;
  String? _truncationReason;

  /// The provider signalled that the response is complete.
  void finish() => _finished = true;

  /// The provider signalled that the response was cut off by an output
  /// limit; [reason] is its stop reason.
  void truncate(String reason) {
    _finished = true;
    _truncationReason = reason;
  }

  /// Passes text deltas through unchanged and, when they end, errors with
  /// [LlmTruncatedException] after [truncate] or with
  /// [LlmInterruptedException] when neither [finish] nor [truncate] was
  /// called. A transport error while streaming (`http.ClientException`, e.g.
  /// "Connection closed while receiving data") also becomes an
  /// [LlmInterruptedException]. Both carry the text streamed so far.
  StreamTransformer<String, String> check() {
    final text = StringBuffer();
    return StreamTransformer.fromHandlers(
      handleData: (delta, sink) {
        text.write(delta);
        sink.add(delta);
      },
      handleError: (error, stackTrace, sink) => sink.addError(
        error is http.ClientException
            ? LlmInterruptedException(partialText: text.toString())
            : error,
        stackTrace,
      ),
      handleDone: (sink) {
        if (_truncationReason case final reason?) {
          sink.addError(
            LlmTruncatedException(partialText: text.toString(), reason: reason),
          );
        } else if (!_finished) {
          sink.addError(LlmInterruptedException(partialText: text.toString()));
        }
        sink.close();
      },
    );
  }
}
