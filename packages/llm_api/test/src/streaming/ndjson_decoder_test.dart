import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

void main() {
  group(NdjsonDecoder, () {
    test('decodes one value per line and skips blank lines', () async {
      final values = await Stream.fromIterable([
        '{"a":1}\n\n  \r\n[2]\r\n"three"',
      ]).transform(const NdjsonDecoder()).toList();
      expect(values, [
        {'a': 1},
        [2],
        'three',
      ]);
    });

    test('decodes identically for any chunk boundaries', () async {
      const body = '{"t":"Grüße"}\n{"t":"世界 👋"}\r\n';
      for (final size in awkwardChunkSizes) {
        final values = await Stream.fromIterable(
          splitBytes(utf8.encode(body), size),
        ).transform(utf8.decoder).transform(const NdjsonDecoder()).toList();
        expect(values, [
          {'t': 'Grüße'},
          {'t': '世界 👋'},
        ], reason: 'chunk size $size');
      }
    });

    test('reports malformed lines as FormatException', () async {
      final stream = Stream.fromIterable(['{"ok":true}\nnot json\n'])
          .transform(const NdjsonDecoder());
      await expectLater(
        stream,
        emitsInOrder(<Object>[
          {'ok': true},
          emitsError(isFormatException),
          emitsDone,
        ]),
      );
    });
  });
}
