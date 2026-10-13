import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('describeError', () {
    test('keeps CLI exceptions', () {
      const error = CliException.config('bad', hint: 'fix');
      expect(describeError(error), same(error));
      expect(error.toString(), 'CliException(78): bad');
      expect(const CliException('x').exitCode, ExitCode.software);
    });

    test('maps LLM errors', () {
      final refusal = describeError(const LlmRefusalException('nope'));
      expect(refusal.exitCode, ExitCode.unavailable);
      expect(refusal.message, 'The AI model declined the request: nope');
      for (final (status, hint) in [
        (401, 'API key'),
        (403, 'API key'),
        (404, 'model name'),
        (429, 'rate limiting'),
        (null, 'reachable'),
      ]) {
        final error = describeError(
          LlmApiException('failed', statusCode: status),
        );
        expect(error.exitCode, ExitCode.unavailable);
        expect(error.hint, contains(hint));
      }
      expect(
        describeError(const LlmApiException('x', statusCode: 500)).hint,
        isNull,
      );
    });

    test('maps Mozhi errors', () {
      final disabled = describeError(
        const MozhiApiException(
          'Engine does not exist or has been disabled.',
          statusCode: 500,
        ),
      );
      expect(disabled.message, startsWith('Mozhi instance error (HTTP 500)'));
      expect(disabled.hint, contains('mozhi engines'));
      expect(
        describeError(const MozhiApiException('bad', statusCode: 429)).hint,
        contains('instances ping'),
      );
      expect(
        describeError(const MozhiApiException('bad', statusCode: 400)).hint,
        isNull,
      );
    });

    test('maps network and argument errors', () {
      expect(
        describeError(TimeoutException('x')).exitCode,
        ExitCode.unavailable,
      );
      expect(
        describeError(const SocketException('refused')).message,
        'Network error: refused',
      );
      expect(
        describeError(ArgumentError.value('x', 'engine', 'Requires AI')),
        isA<CliException>()
            .having((e) => e.exitCode, 'exitCode', ExitCode.usage)
            .having((e) => e.message, 'message', 'Requires AI: x'),
      );
      expect(describeError(ArgumentError('plain')).message, 'plain');
      expect(describeError(StateError('s')).exitCode, ExitCode.usage);
      expect(
        describeError(
          ParallelWaitError<List<Object?>, List<Object?>>(
            [null],
            [null, const MozhiApiException('down')],
          ),
        ).message,
        contains('down'),
      );
      expect(describeError(Exception('x')).exitCode, ExitCode.software);
    });
  });
}
