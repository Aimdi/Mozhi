import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

Future<String> _filter(List<String> chunks) =>
    Stream.fromIterable(chunks).transform(const ThinkTagFilter()).join();

/// [text] cut into chunks of [size] characters.
List<String> _split(String text, int size) => [
  for (var start = 0; start < text.length; start += size)
    text.substring(start, (start + size).clamp(0, text.length)),
];

void main() {
  group(ThinkTagFilter, () {
    group('strip', () {
      test('removes a leading think block and the whitespace after it', () {
        expect(
          ThinkTagFilter.strip('<think>\nplan the answer\n</think>\n\nHello'),
          'Hello',
        );
      });

      test('removes <thinking> and <reasoning> blocks', () {
        expect(
          ThinkTagFilter.strip(
            '<thinking>a</thinking>One <reasoning>b</reasoning>two',
          ),
          'One two',
        );
      });

      test('matches tags case-insensitively', () {
        expect(ThinkTagFilter.strip('<THINK>x</Think>Answer'), 'Answer');
      });

      test('keeps whitespace that precedes a block', () {
        expect(
          ThinkTagFilter.strip('  lead <think>x</think>  tail'),
          '  lead tail',
        );
      });

      test('leaves text without tags untouched', () {
        const text = 'a < b, <b>bold</b>, <thinker>, x<y';
        expect(ThinkTagFilter.strip(text), text);
      });

      test('ends a block at the first closing tag (no nesting)', () {
        expect(
          ThinkTagFilter.strip('<think>a <think> b</think>c</think>d'),
          'c</think>d',
        );
      });

      test('only the matching closing tag ends a block', () {
        expect(ThinkTagFilter.strip('<thinking>x</think>y</thinking>z'), 'z');
      });

      test('drops an unterminated block', () {
        expect(ThinkTagFilter.strip('Hi <think>never closes'), 'Hi ');
      });

      test('keeps a trailing partial opening tag as text', () {
        expect(ThinkTagFilter.strip('Hello <thi'), 'Hello <thi');
      });

      test('returns an empty string for a lone block', () {
        expect(ThinkTagFilter.strip('<think>only</think>\n'), isEmpty);
      });
    });

    group('bind', () {
      test('handles an opening tag split across three chunks', () async {
        expect(
          await _filter(['<th', 'in', 'k>secret</think>Answer']),
          'Answer',
        );
      });

      test('handles a closing tag split across chunks', () async {
        expect(await _filter(['<think>a</th', 'ink', '>  B']), 'B');
      });

      test('distinguishes <think> from <thinking> across chunks', () async {
        expect(
          await _filter(['<think', 'ing>x</think>y</thin', 'king>z']),
          'z',
        );
      });

      test('emits a held back "<" once it cannot start a tag', () async {
        expect(await _filter(['x <', ' y']), 'x < y');
        expect(await _filter(['<thi', 'ef']), '<thief');
      });

      test('holds back a possible tag until it is decided', () async {
        final controller = StreamController<String>();
        final output = <String>[];
        final subscription = controller.stream
            .transform(const ThinkTagFilter())
            .listen(output.add);

        controller.add('Hello <thin');
        await pumpEventQueue();
        expect(output, ['Hello ']);

        controller.add('king> hidden');
        await pumpEventQueue();
        expect(output, ['Hello ']);

        await controller.close();
        await subscription.cancel();
        expect(output, ['Hello ']);
      });

      test('ignores "<" inside a block that does not close it', () async {
        expect(await _filter(['<think>a < b <c', 'd</think>ok']), 'ok');
        expect(await _filter(['<think>x <y', 'z</think>w']), 'w');
      });

      test('drops whitespace-only chunks after a block', () async {
        expect(
          await _filter(['<think>x</think>', '\n', '  ', 'Answer']),
          'Answer',
        );
      });

      test('drops an unterminated block at end of stream', () async {
        expect(await _filter(['Hi ', '<think>a', 'b</th']), 'Hi ');
      });

      test('flushes a trailing partial tag at end of stream', () async {
        expect(await _filter(['Hi ', '<reas']), 'Hi <reas');
      });

      test('matches strip for every chunk size', () async {
        const inputs = [
          '<think>\nreasoning with <tags> and < signs\n</think>\n\nBonjour !',
          'Before <THINKING>x</thinking> after <reasoning>y',
          'a <b <think>c</think> d <thin',
          '日本語 <think>思考</think> テキスト 👋',
        ];
        for (final input in inputs) {
          final expected = ThinkTagFilter.strip(input);
          for (var size = 1; size <= input.length; size++) {
            expect(
              await _filter(_split(input, size)),
              expected,
              reason: 'chunk size $size of "$input"',
            );
          }
        }
      });

      test('forwards errors', () async {
        final stream = Stream<String>.multi((controller) {
          controller
            ..add('ok')
            ..addError(StateError('boom'))
            ..closeSync();
        }).transform(const ThinkTagFilter());
        await expectLater(
          stream,
          emitsInOrder(<Object>['ok', emitsError(isStateError), emitsDone]),
        );
      });
    });
  });
}
