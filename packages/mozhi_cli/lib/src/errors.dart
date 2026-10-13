import 'dart:async';
import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:translation_repository/translation_repository.dart';

/// A failure with a message meant for the user and a sysexits exit code.
class CliException implements Exception {
  const new(this.message, {this.exitCode = ExitCode.software, this.hint});

  /// Bad arguments or input (exit code 64).
  const new usage(this.message, {this.hint}) : exitCode = ExitCode.usage;

  /// A remote service could not be used (exit code 69).
  const new unavailable(this.message, {this.hint})
    : exitCode = ExitCode.unavailable;

  /// The configuration file is invalid or cannot be written (exit code 78).
  const new config(this.message, {this.hint}) : exitCode = ExitCode.config;

  final String message;
  final ExitCode exitCode;

  /// An optional suggestion on how to fix the problem.
  final String? hint;

  @override
  String toString() => 'CliException(${exitCode.code}): $message';
}

/// Maps any error thrown while running a command to a [CliException] with
/// a readable message.
CliException describeError(Object error) => switch (error) {
  CliException() => error,
  LlmRefusalException(:final message, :final category) =>
    CliException.unavailable(
      'The AI model declined the request'
      '${category == null ? '' : ' ($category)'}: $message',
      hint: 'Rephrase the text or try another engine with --engine.',
    ),
  LlmApiException(:final message, :final statusCode) =>
    CliException.unavailable(
      'AI provider error${statusCode == null ? '' : ' (HTTP $statusCode)'}: '
      '$message',
      hint: switch (statusCode) {
        401 || 403 =>
          'Check the API key: mozhi config providers add --name <name> '
              '--api-key-env <VARIABLE> ...',
        404 => 'Check the model name and the base URL of the provider.',
        429 => 'The provider is rate limiting requests; wait and retry.',
        null =>
          'Check that the provider is reachable (for local models, that the '
              'server is running).',
        _ => null,
      },
    ),
  MozhiApiException(:final message, :final statusCode, :final uri) =>
    CliException.unavailable(
      'Mozhi instance error${statusCode == null ? '' : ' (HTTP $statusCode)'}'
      '${uri == null || uri.host.isEmpty ? '' : ' from ${uri.host}'}: '
      '$message',
      hint: message.toLowerCase().contains('engine does not exist')
          ? 'This engine is disabled on the instance; '
                'list the available ones with: mozhi engines'
          : statusCode == null || statusCode >= 500 || statusCode == 429
          ? 'Try another instance with --instance <url>, '
                'or find a fast one with: mozhi instances ping'
          : null,
    ),
  TimeoutException() => const CliException.unavailable(
    'The request timed out.',
    hint: 'Try again, or use another instance or engine.',
  ),
  io.SocketException(:final message) ||
  io.HttpException(:final message) ||
  io.TlsException(:final message) => CliException.unavailable(
    'Network error: $message',
  ),
  ArgumentError(:final message, :final invalidValue) => CliException.usage(
    '$message${invalidValue == null ? '' : ': $invalidValue'}',
  ),
  StateError(:final message) => CliException.usage(message),
  _ => CliException('Unexpected error: $error'),
};
