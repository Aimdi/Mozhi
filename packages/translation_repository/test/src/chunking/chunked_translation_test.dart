import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/src/chunking/chunked_translation.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/translation_repository.dart';

const engine = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
);

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');

const chunks = [
  TextChunk(text: 'One.', separator: '\n\n'),
  TextChunk(text: 'Two.', separator: '\n \n'),
  TextChunk(text: 'Three.'),
];

/// One chunk request and the controller that answers it.
class Call {
  new(this.request, this.preceding);

  final TranslationRequest request;
  final String preceding;
  bool cancelled = false;
  bool paused = false;
  late final controller = StreamController<TranslationResult>(
    onCancel: () => cancelled = true,
    onPause: () => paused = true,
    onResume: () => paused = false,
  );

  void snapshot(String text, {String? detected}) => controller.add(
    TranslationResult(
      engineId: engine.id,
      engineName: engine.name,
      text: text,
      isComplete: false,
      detectedSource: detected,
    ),
  );

  Future<void> finish(String text, {String? detected}) async {
    controller.add(
      TranslationResult(
        engineId: engine.id,
        engineName: engine.name,
        text: text,
        detectedSource: detected,
      ),
    );
    await controller.close();
  }
}

void main() {
  late List<Call> calls;
  late List<String> pinned;

  Stream<TranslationResult> translate(
    TranslationRequest request,
    String preceding,
  ) {
    final call = Call(request, preceding);
    calls.add(call);
    return call.controller.stream;
  }

  Language languageFor(String code) {
    pinned.add(code);
    return Language(code: code, name: 'Language $code');
  }

  Stream<TranslationResult> chunked(
    TranslationRequest request, {
    List<TextChunk> chunks = chunks,
    Stream<TranslationResult> Function(TranslationRequest, String)? translator,
    int concurrency = 2,
    int contextChars = 400,
  }) => chunkedTranslation(
    engine: engine,
    request: request,
    chunks: chunks,
    translate: translator ?? translate,
    languageFor: languageFor,
    concurrency: concurrency,
    contextChars: contextChars,
  );

  setUp(() {
    calls = [];
    pinned = [];
  });

  final explicit = TranslationRequest(
    text: chunks.map((c) => '${c.text}${c.separator}').join(),
    source: english,
    target: german,
    options: const TranslationOptions(
      context: 'A letter to my landlord',
      formality: Formality.more,
    ),
  );
  final auto = explicit.copyWith(source: Language.auto);

  group('chunkedTranslation', () {
    test('emits nothing for no chunks', () async {
      await expectLater(chunked(explicit, chunks: const []), emitsDone);
      expect(calls, isEmpty);
    });

    test('translates two chunks at a time, in order', () async {
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(explicit).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      expect(calls.map((c) => c.request.text), ['One.', 'Two.']);

      await calls[1].finish('Zwei.');
      await pumpEventQueue();
      // The next chunk starts while the first one still runs.
      expect(calls.map((c) => c.request.text), ['One.', 'Two.', 'Three.']);
      expect(results.last.text, '\n\nZwei.');
      expect(results.last.isComplete, isFalse);

      await calls[2].finish('Drei.');
      await pumpEventQueue();
      expect(results.last.isComplete, isFalse);
      await calls[0].finish('Eins.');
      await done.future;

      expect(results.last.text, 'Eins.\n\nZwei.\n \nDrei.');
      expect(results.last.isComplete, isTrue);
      expect(results.where((r) => r.isComplete), hasLength(1));
      expect(results.last.engineId, engine.id);
      expect(results.last.engineName, engine.name);
      expect(results.last.elapsed, isNotNull);
      expect(results.last.detectedSource, isNull);
    });

    test('keeps the request and gives later chunks the preceding text', () {
      chunked(explicit).listen((_) {});
      return pumpEventQueue().then((_) {
        final first = calls[0].request;
        expect(first.source, english);
        expect(first.target, german);
        expect(first.options, explicit.options);
        expect(calls[0].preceding, isEmpty);
        // The preceding text is passed on its own, never as the user's
        // context (which ends up in the system prompt).
        final second = calls[1].request;
        expect(second.options, explicit.options);
        expect(calls[1].preceding, 'One.');
      });
    });

    test('passes only the end of a long preceding chunk', () async {
      final long = List.filled(50, 'word').join(' ');
      chunked(
        explicit,
        chunks: [
          TextChunk(text: long, separator: '\n\n'),
          const TextChunk(text: 'Next.'),
        ],
        contextChars: 20,
      ).listen((_) {});
      await pumpEventQueue();
      expect(calls[1].preceding, precedingTextTail(long, maxChars: 20));
      expect(calls[1].preceding, startsWith('…'));
    });

    test('combines finished and in-progress chunks in order', () async {
      final texts = <String>[];
      final sub = chunked(explicit).listen((r) => texts.add(r.text));
      await pumpEventQueue();
      calls[1].snapshot('Zw');
      await pumpEventQueue();
      calls[0].snapshot('Ei');
      await pumpEventQueue();
      calls[1].snapshot('Zwei');
      await pumpEventQueue();
      await calls[0].finish('Eins.');
      await pumpEventQueue();
      expect(texts, [
        // The empty first chunk keeps the place of its separator.
        '\n\nZw',
        'Ei\n\nZw',
        'Ei\n\nZwei',
        'Eins.\n\nZwei',
      ]);
      // The third chunk started but has no text yet.
      expect(calls, hasLength(3));
      calls[2].snapshot('Dr');
      await pumpEventQueue();
      expect(texts.last, 'Eins.\n\nZwei\n \nDr');
      await sub.cancel();
    });

    test('drops identical consecutive snapshots', () async {
      final results = <TranslationResult>[];
      chunked(explicit).listen(results.add);
      await pumpEventQueue();
      calls[0]
        ..snapshot('Eins')
        ..snapshot('Eins');
      await pumpEventQueue();
      expect(results, hasLength(1));
    });

    test('pins the source the first chunk detected', () async {
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(auto).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      expect(calls, hasLength(1), reason: 'the first chunk runs alone');
      expect(calls.single.request.source, Language.auto);

      calls[0].snapshot('', detected: 'en');
      await pumpEventQueue();
      expect(results.single.text, isEmpty);
      expect(results.single.detectedSource, 'en');
      expect(results.single.isComplete, isFalse);

      await calls[0].finish('Eins.', detected: 'en');
      await pumpEventQueue();
      expect(pinned, ['en']);
      expect(calls.map((c) => c.request.source.code), ['auto', 'en', 'en']);

      await calls[1].finish('Zwei.');
      await calls[2].finish('Drei.');
      await done.future;
      expect(results.map((r) => r.detectedSource), everyElement('en'));
      expect(results.last.text, 'Eins.\n\nZwei.\n \nDrei.');
    });

    test('keeps an auto source when the first chunk is in the target '
        'language', () async {
      // An English e-mail with a German reply, translated into English:
      // pinning English would ask for English -> English ("polish, do not
      // translate") and leave the German reply untranslated.
      final results = <TranslationResult>[];
      final done = Completer<void>();
      final toEnglish = auto.copyWith(target: english);
      chunked(toEnglish).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      await calls[0].finish('One.', detected: 'en-US');
      await pumpEventQueue();
      expect(pinned, isEmpty);
      expect(calls, hasLength(3), reason: 'the others run in parallel');
      expect(calls.map((c) => c.request.source), everyElement(Language.auto));
      await calls[1].finish('Two.', detected: 'de');
      await calls[2].finish('Three.', detected: 'de');
      await done.future;
      expect(results.last.detectedSource, 'en-US');
      expect(results.last.isComplete, isTrue);
    });

    test('pins a detected language for a custom target', () async {
      chunked(auto.copyWith(target: const Language.custom('Pirate speak')))
          .listen((_) {});
      await pumpEventQueue();
      await calls[0].finish('Arr.', detected: 'en');
      await pumpEventQueue();
      expect(pinned, ['en']);
    });

    test('keeps an auto source when the first chunk detected none', () async {
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(auto).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      await calls[0].finish('Eins.');
      await pumpEventQueue();
      expect(pinned, isEmpty);
      expect(calls.map((c) => c.request.source), everyElement(Language.auto));
      // A later chunk's detection is used instead.
      await calls[1].finish('Zwei.', detected: 'fr');
      await calls[2].finish('Drei.', detected: 'en');
      await done.future;
      expect(results.last.detectedSource, 'fr');
    });

    test('runs at least one chunk at a time', () async {
      chunked(explicit, concurrency: 0).listen((_) {});
      await pumpEventQueue();
      expect(calls, hasLength(1));
    });

    test('honours the concurrency', () async {
      chunked(explicit, concurrency: 1).listen((_) {});
      await pumpEventQueue();
      expect(calls, hasLength(1));
      await calls[0].finish('Eins.');
      await pumpEventQueue();
      expect(calls, hasLength(2));
    });

    test('cancels the other chunks and emits an error', () async {
      final events = <Object>[];
      final done = Completer<void>();
      chunked(explicit).listen(
        events.add,
        onError: (Object error) => events.add('error: $error'),
        onDone: done.complete,
      );
      await pumpEventQueue();
      calls[0].snapshot('Ei');
      await pumpEventQueue();
      calls[1].controller.addError(StateError('rate limited'));
      await done.future;
      expect(events, hasLength(2));
      expect(events.last, 'error: Bad state: rate limited');
      expect(calls[0].cancelled, isTrue);
      expect(calls, hasLength(2), reason: 'no chunk starts after an error');
    });

    test('joins a CJK sentence end with a space where needed', () async {
      const cjk = [
        TextChunk(text: '这是第一句。', sentenceEnd: true),
        TextChunk(text: '这是第二句。', sentenceEnd: true),
        TextChunk(text: '第三句。'),
      ];
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(explicit, chunks: cjk).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      await calls[1].finish('This is the second one.');
      await pumpEventQueue();
      // No space before a part that has no text yet.
      expect(results.last.text, 'This is the second one.');
      await calls[0].finish('This is the first one.');
      await pumpEventQueue();
      await calls[2].finish('第三句。');
      await done.future;
      // A space between sentences in a script with spaces; none next to
      // Chinese text.
      expect(
        results.last.text,
        'This is the first one. This is the second one.第三句。',
      );
    });

    test('emits an error thrown when a chunk is requested', () async {
      final error = ArgumentError('bad chunk');
      await expectLater(
        chunked(explicit, translator: (_, _) => throw error),
        emitsInOrder([emitsError(same(error)), emitsDone]),
      );
    });

    test('cancelling cancels the chunks in flight', () async {
      final subscription = chunked(explicit).listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();
      expect(calls.map((c) => c.cancelled), [true, true]);
    });

    test('forwards pause and resume', () async {
      final subscription = chunked(explicit, concurrency: 1).listen((_) {});
      await pumpEventQueue();
      subscription.pause();
      expect(calls[0].paused, isTrue);
      subscription.resume();
      expect(calls[0].paused, isFalse);
      await calls[0].finish('Eins.');
      await pumpEventQueue();
      expect(calls, hasLength(2));
      subscription.pause();
      expect(calls[1].paused, isTrue);
      subscription.resume();
      expect(calls[1].paused, isFalse);
      await subscription.cancel();
    });
  });

  group('precedingTextTail', () {
    test('keeps a short preceding text whole', () {
      expect(precedingTextTail('  The end.  '), 'The end.');
    });

    test('keeps only the end of a long preceding text', () {
      final preceding = List.filled(200, 'word').join(' ');
      final tail = precedingTextTail(preceding);
      expect(tail, startsWith('…word'));
      expect(tail.length, lessThanOrEqualTo(401));
      expect(preceding, endsWith(tail.substring(1)));
    });

    test('starts at a word boundary', () {
      final preceding = 'abcdefghij ${'x' * 9}';
      // The cut inside "abcdefghij" moves to the next word.
      expect(precedingTextTail(preceding, maxChars: 12), '…${'x' * 9}');
    });

    test('cuts a very long word where needed', () {
      expect(precedingTextTail('y' * 100, maxChars: 10), '…${'y' * 10}');
    });

    test('never starts inside a surrogate pair', () {
      final tail = precedingTextTail('😀' * 10, maxChars: 5);
      expect(tail.runes.skip(1), everyElement(0x1F600));
    });

    test('keeps nothing with a limit of 0', () {
      expect(precedingTextTail('text', maxChars: 0), isEmpty);
    });
  });
}
