import 'dart:async';
import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

Future<List<SseEvent>> _decode(List<String> chunks) =>
    Stream.fromIterable(chunks).transform(const SseDecoder()).toList();

void main() {
  group(SseEvent, () {
    test('supports value equality', () {
      expect(const SseEvent('a', event: 'x'), const SseEvent('a', event: 'x'));
      expect(
        const SseEvent('a', event: 'x').hashCode,
        const SseEvent('a', event: 'x').hashCode,
      );
      expect(const SseEvent('a'), isNot(const SseEvent('a', event: 'x')));
      expect(const SseEvent('a'), isNot(const SseEvent('b')));
    });

    test('has a readable toString', () {
      expect(const SseEvent('{}').toString(), 'SseEvent(message: {})');
      expect(
        const SseEvent('1', event: 'ping').toString(),
        'SseEvent(ping: 1)',
      );
    });
  });

  group(SseDecoder, () {
    test('decodes events with and without names', () async {
      expect(await _decode(['event: start\ndata: {"a":1}\n\ndata: two\n\n']), [
        const SseEvent('{"a":1}', event: 'start'),
        const SseEvent('two'),
      ]);
    });

    test('joins multiple data lines with a newline', () async {
      expect(await _decode(['data: a\ndata: b\n\n']), [const SseEvent('a\nb')]);
    });

    test('ignores comments, id, retry and unknown fields', () async {
      expect(
        await _decode([
          ': keep-alive\nid: 7\nretry: 1000\nfoo: bar\ndata: x\n\n',
        ]),
        [const SseEvent('x')],
      );
    });

    test('strips exactly one optional space after the colon', () async {
      expect(await _decode(['data:x\n\ndata:  y\n\n']), [
        const SseEvent('x'),
        const SseEvent(' y'),
      ]);
    });

    test('treats a field without colon as an empty value', () async {
      expect(await _decode(['data\n\n']), [const SseEvent('')]);
    });

    test('accepts CRLF and CR line endings', () async {
      expect(await _decode(['data: a\r\n\r\ndata: b\r\rdata: c\n\n']), [
        const SseEvent('a'),
        const SseEvent('b'),
        const SseEvent('c'),
      ]);
    });

    test('does not dispatch events without data', () async {
      expect(await _decode(['event: ping\n\n\n\ndata: x\n\n']), [
        const SseEvent('x'),
      ]);
    });

    test('resets the event name after each event', () async {
      expect(await _decode(['event: a\ndata: 1\n\ndata: 2\n\n']), [
        const SseEvent('1', event: 'a'),
        const SseEvent('2'),
      ]);
    });

    test('treats an empty event name as none', () async {
      expect(await _decode(['event:\ndata: 1\n\n']), [const SseEvent('1')]);
    });

    test('dispatches a pending event when the stream ends', () async {
      expect(await _decode(['data: last']), [const SseEvent('last')]);
    });

    test('strips a byte order mark at the start of the stream', () async {
      expect(await _decode(['﻿data: x\n\n']), [const SseEvent('x')]);
    });

    test('decodes identically for any chunk boundaries', () async {
      const body =
          ': hello\r\nevent: delta\r\ndata: {"t":"Grüße 世界 👋"}\r\n\r\n'
          'data:{"t":"x"}\n\ndata: [DONE]\n\n';
      for (final size in awkwardChunkSizes) {
        final events = await Stream.fromIterable(
          splitBytes(utf8.encode(body), size),
        ).transform(utf8.decoder).transform(const SseDecoder()).toList();
        expect(events, [
          const SseEvent('{"t":"Grüße 世界 👋"}', event: 'delta'),
          const SseEvent('{"t":"x"}'),
          const SseEvent('[DONE]'),
        ], reason: 'chunk size $size');
      }
    });

    test('forwards errors', () async {
      final stream = Stream<String>.multi((controller) {
        controller
          ..add('data: a\n\n')
          ..addError(const FormatException('bad'))
          ..closeSync();
      }).transform(const SseDecoder());
      await expectLater(
        stream,
        emitsInOrder(<Object>[
          const SseEvent('a'),
          emitsError(isFormatException),
          emitsDone,
        ]),
      );
    });
  });
}
