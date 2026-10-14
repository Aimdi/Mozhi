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
  new(this.request);

  final TranslationRequest request;
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

  Stream<TranslationResult> translate(TranslationRequest request) {
    final call = Call(request);
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
    Stream<TranslationResult> Function(TranslationRequest)? translator,
    int concurrency = 2,
  }) => chunkedTranslation(
    engine: engine,
    request: request,
    chunks: chunks,
    translate: translator ?? translate,
    languageFor: languageFor,
    concurrency: concurrency,
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
        final second = calls[1].request;
        expect(second.options.formality, Formality.more);
        expect(
          second.options.context,
          precedingTextContext('A letter to my landlord', 'One.'),
        );
        expect(second.options.context, startsWith('A letter to my landlord'));
        expect(second.options.context, endsWith('Preceding text: One.'));
      });
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

    test('emits an error thrown when a chunk is requested', () async {
      final error = ArgumentError('bad chunk');
      await expectLater(
        chunked(explicit, translator: (_) => throw error),
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

  group('precedingTextContext', () {
    test('labels the preceding text without the user context', () {
      final context = precedingTextContext('', 'The end.');
      expect(context, startsWith('The text to translate continues'));
      expect(context, contains('do not translate it'));
      expect(context, endsWith('Preceding text: The end.'));
    });

    test('puts the user context first', () {
      final context = precedingTextContext('  Legal text  ', 'The end.');
      expect(context, startsWith('Legal text\n\nThe text to translate'));
    });

    test('keeps only the end of a long preceding text', () {
      final preceding = List.filled(200, 'word').join(' ');
      final context = precedingTextContext('', preceding);
      final tail = context.split('Preceding text: ').last;
      expect(tail, startsWith('…word'));
      expect(tail.length, lessThanOrEqualTo(401));
      expect(preceding, endsWith(tail.substring(1)));
    });

    test('starts at a word boundary', () {
      final preceding = 'abcdefghij ${'x' * 9}';
      final tail = precedingTextContext(
        '',
        preceding,
        maxChars: 12,
      ).split('Preceding text: ').last;
      // The cut inside "abcdefghij" moves to the next word.
      expect(tail, '…${'x' * 9}');
    });

    test('cuts a very long word where needed', () {
      final tail = precedingTextContext(
        '',
        'y' * 100,
        maxChars: 10,
      ).split('Preceding text: ').last;
      expect(tail, '…${'y' * 10}');
    });

    test('never starts inside a surrogate pair', () {
      final tail = precedingTextContext(
        '',
        '😀' * 10,
        maxChars: 5,
      ).split('Preceding text: ').last;
      expect(tail.runes.skip(1), everyElement(0x1F600));
    });

    test('keeps nothing with a limit of 0', () {
      expect(
        precedingTextContext('', 'text', maxChars: 0),
        endsWith('Preceding text: '),
      );
    });
  });
}
