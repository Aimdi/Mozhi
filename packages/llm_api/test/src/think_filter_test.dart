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

      test('removes consecutive <thinking> and <reasoning> blocks', () {
        expect(
          ThinkTagFilter.strip(
            '<thinking>a</thinking>\n<reasoning>b</reasoning> One two',
          ),
          'One two',
        );
      });

      test('matches tags case-insensitively', () {
        expect(ThinkTagFilter.strip('<THINK>x</Think>Answer'), 'Answer');
      });

      test('drops whitespace around a leading block', () {
        expect(ThinkTagFilter.strip(' \n<think>x</think>  tail'), 'tail');
      });

      test('keeps leading whitespace before visible text', () {
        expect(ThinkTagFilter.strip('  Hello'), '  Hello');
        expect(ThinkTagFilter.strip(' \n '), ' \n ');
        expect(ThinkTagFilter.strip(''), isEmpty);
      });

      test('keeps tags that follow visible text', () {
        const texts = [
          'Utilisez la balise <reasoning> pour structurer la réponse.',
          'Le mot <Think> signifie penser. Fin.',
          'Wrap it in <thinking>...</thinking> tags, then answer.',
          '{"translation": "Use the <think> tag here."}',
          '  lead <think>x</think>  tail',
          'One <reasoning>b</reasoning>two',
        ];
        for (final text in texts) {
          expect(ThinkTagFilter.strip(text), text);
        }
      });

      test('keeps tags after a removed leading block', () {
        expect(
          ThinkTagFilter.strip('<think>plan</think>\nUse the <reasoning> tag.'),
          'Use the <reasoning> tag.',
        );
      });

      test('removes reasoning before a closing tag without opening tag', () {
        expect(
          ThinkTagFilter.strip(
            'Okay, the user wants French. "Hello" is "Bonjour".\n'
            '</think>\n\nBonjour',
          ),
          'Bonjour',
        );
        expect(ThinkTagFilter.strip('\n</THINKING>\n\nAnswer'), 'Answer');
        expect(ThinkTagFilter.strip('x</reasoning>'), isEmpty);
        expect(
          ThinkTagFilter.strip('a</think>\n<think>b</think> c'),
          'c',
        );
      });

      test('keeps a closing tag that follows an opening tag', () {
        const text = 'Use <think> and </think> tags.';
        expect(ThinkTagFilter.strip(text), text);
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
        expect(ThinkTagFilter.strip(' <think>never closes'), isEmpty);
      });

      test('keeps a trailing partial tag as text', () {
        expect(ThinkTagFilter.strip('Hello <thi'), 'Hello <thi');
        expect(ThinkTagFilter.strip(' <thi'), ' <thi');
        expect(ThinkTagFilter.strip('</thin'), '</thin');
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

        controller.add('\n<thin');
        await pumpEventQueue();
        expect(output, isEmpty);

        controller.add('king> hidden');
        await pumpEventQueue();
        expect(output, isEmpty);

        controller.add('</thinking>\nHello <thin');
        await pumpEventQueue();
        expect(output, ['Hello <thin']);

        controller.add('king> shown');
        await pumpEventQueue();
        expect(output, ['Hello <thin', 'king> shown']);

        await controller.close();
        await subscription.cancel();
        expect(output, ['Hello <thin', 'king> shown']);
      });

      test('keeps tags that follow visible text', () async {
        expect(
          await _filter([
            'Utilisez la balise <rea',
            'soning> pour structurer ',
            'la réponse.',
          ]),
          'Utilisez la balise <reasoning> pour structurer la réponse.',
        );
        expect(
          await _filter(['Le mot ', '<Think>', ' signifie penser. Fin.']),
          'Le mot <Think> signifie penser. Fin.',
        );
      });

      test('drops a closing tag that only whitespace precedes', () async {
        expect(await _filter(['\n</th', 'ink>\n\n', 'Bonjour']), 'Bonjour');
      });

      test('passes a closing tag after visible text through so that strip '
          'can remove the reasoning from the accumulated text', () async {
        final output = await _filter([
          'Okay, the user ',
          'wants French.\n</th',
          'ink>\n\nBon',
          'jour',
        ]);
        expect(output, 'Okay, the user wants French.\n</think>\n\nBonjour');
        expect(ThinkTagFilter.strip(output), 'Bonjour');
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
        expect(await _filter([' ', '<think>a', 'b</th']), isEmpty);
      });

      test('flushes a trailing partial tag at end of stream', () async {
        expect(await _filter(['\n', '<reas']), '\n<reas');
        expect(await _filter(['Hi ', '<reas']), 'Hi <reas');
      });

      test('matches strip for every chunk size', () async {
        const inputs = [
          '<think>\nreasoning with <tags> and < signs\n</think>\n\nBonjour !',
          'Before <THINKING>x</thinking> after <reasoning>y',
          'a <b <think>c</think> d <thin',
          '日本語 <think>思考</think> テキスト 👋',
          ' \n<thinking>x</thinking>\n<REASONING>y</reasoning>  Answer '
              '<think>kept</think>',
          '\n</think>\n\nBonjour',
          '<b>bold</b> <think>',
          '  <thin',
          ' \n ',
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
