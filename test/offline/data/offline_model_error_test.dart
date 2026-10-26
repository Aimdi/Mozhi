import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show
        TessdataChecksumException,
        TessdataDownloadException,
        TessdataInsufficientSpaceException,
        TessdataMissingException;
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(OfflineModelError, () {
    test('classifies the text recognition data errors', () {
      final cases = <Object, OfflineModelError>{
        const TessdataChecksumException('deu', 'bad'): const OfflineModelError(
          OfflineModelErrorKind.checksum,
        ),
        const TessdataDownloadException(
          'deu',
          'HTTP 404',
          statusCode: 404,
        ): const OfflineModelError(
          OfflineModelErrorKind.server,
          statusCode: 404,
        ),
        const TessdataDownloadException('deu', 'SocketException: offline'):
            const OfflineModelError(OfflineModelErrorKind.network),
        const TessdataMissingException(['deu']): const OfflineModelError(
          OfflineModelErrorKind.unsupported,
        ),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(OfflineModelError.of(key), value, reason: '$key');
      }
    });

    test('classifies the offline engine errors', () {
      final cases = <Object, OfflineModelError>{
        const MeteredConnectionException(): const OfflineModelError(
          OfflineModelErrorKind.metered,
        ),
        const ModelChecksumException('en-de', 'bad'): const OfflineModelError(
          OfflineModelErrorKind.checksum,
        ),
        const ModelDownloadException(
          'en-de',
          'HTTP 503',
          statusCode: 503,
        ): const OfflineModelError(
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
        StateError('?'): const OfflineModelError(OfflineModelErrorKind.unknown),
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

    test('names the mirror a failed download came from', () {
      final mirror = Uri.parse('https://mirror.example/models/');
      final lan = Uri.parse('http://192.168.1.10:8080/');
      final cases = <Object, OfflineModelError>{
        ModelChecksumException(
          'en-de',
          'bad',
          mirror: mirror,
        ): const OfflineModelError(
          OfflineModelErrorKind.checksum,
          mirror: 'mirror.example',
        ),
        ModelDownloadException(
          'en-de',
          'HTTP 404',
          statusCode: 404,
          mirror: lan,
        ): const OfflineModelError(
          OfflineModelErrorKind.server,
          statusCode: 404,
          mirror: '192.168.1.10:8080',
        ),
        ModelDownloadException(
          'en-de',
          'offline',
          mirror: mirror,
        ): const OfflineModelError(
          OfflineModelErrorKind.network,
          mirror: 'mirror.example',
        ),
        TessdataChecksumException(
          'deu',
          'bad',
          mirror: mirror,
        ): const OfflineModelError(
          OfflineModelErrorKind.checksum,
          mirror: 'mirror.example',
        ),
        TessdataDownloadException(
          'deu',
          'HTTP 404',
          statusCode: 404,
          mirror: mirror,
        ): const OfflineModelError(
          OfflineModelErrorKind.server,
          statusCode: 404,
          mirror: 'mirror.example',
        ),
        TessdataDownloadException(
          'deu',
          'offline',
          mirror: mirror,
        ): const OfflineModelError(
          OfflineModelErrorKind.network,
          mirror: 'mirror.example',
        ),
      };
      for (final MapEntry(key: error, value: expected) in cases.entries) {
        expect(OfflineModelError.of(error), expected, reason: '$error');
      }
      expect(OfflineModelError.mirrorName(null), isNull);
    });

    test('classifies too little free space', () {
      const space = SpaceShortfall(requiredBytes: 9, availableBytes: 3);
      for (final error in const <Object>[
        ModelInsufficientSpaceException(
          'de-en',
          'x',
          requiredBytes: 9,
          availableBytes: 3,
        ),
        TessdataInsufficientSpaceException(
          'deu',
          'x',
          requiredBytes: 9,
          availableBytes: 3,
        ),
        NotEnoughSpaceException(requiredBytes: 9, availableBytes: 3),
      ]) {
        expect(
          OfflineModelError.of(error),
          const OfflineModelError(OfflineModelErrorKind.space, space: space),
        );
      }
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
