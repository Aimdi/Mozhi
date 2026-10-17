import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(OfflineModelError, () {
    test('classifies the offline engine errors', () {
      final cases = <Object, OfflineModelError>{
        const MeteredConnectionException(): const OfflineModelError(
          OfflineModelErrorKind.metered,
        ),
        const ModelChecksumException('en-de', 'bad'): const OfflineModelError(
          OfflineModelErrorKind.checksum,
        ),
        const ModelDownloadException('en-de', 'HTTP 503', statusCode: 503):
            const OfflineModelError(
              OfflineModelErrorKind.server,
              statusCode: 503,
            ),
        const ModelDownloadException('en-de', 'SocketException: offline'):
            const OfflineModelError(OfflineModelErrorKind.network),
        const FileSystemException('No space left on device'):
            const OfflineModelError(OfflineModelErrorKind.storage),
        const BergamotEngineException('boom'): const OfflineModelError(
          OfflineModelErrorKind.engine,
        ),
        const OfflineLanguageUnsupportedException('tlh'):
            const OfflineModelError(OfflineModelErrorKind.unsupported),
        UnsupportedError('not here'): const OfflineModelError(
          OfflineModelErrorKind.unsupported,
        ),
        StateError('?'): const OfflineModelError(
          OfflineModelErrorKind.unknown,
        ),
      };
      for (final MapEntry(key: error, value: expected) in cases.entries) {
        expect(OfflineModelError.of(error), expected, reason: '$error');
      }
    });

    test('recognises downloads the network policy refused', () {
      final error = OfflineModelError.of(
        const ModelDownloadException(
          'en-de',
          'ClientException: ${InvalidProxyException.defaultMessage}',
        ),
      );

      expect(error.kind, OfflineModelErrorKind.network);
      expect(error.networkPolicy, NetworkPolicyError.invalidProxy);
    });

    test('supports value equality', () {
      expect(
        const OfflineModelError(OfflineModelErrorKind.server, statusCode: 404),
        isNot(
          const OfflineModelError(
            OfflineModelErrorKind.server,
            statusCode: 500,
          ),
        ),
      );
    });
  });
}
