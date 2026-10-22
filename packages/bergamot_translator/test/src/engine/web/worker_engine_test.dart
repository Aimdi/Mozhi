import 'dart:async';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'fake_bergamot_worker.dart';

const _ende = ModelPaths(
  key: 'en-de/run1',
  model: 'models/en-de/run1/model.ende.intgemm.alphas.bin',
  shortlist: 'models/en-de/run1/lex.50.50.ende.s2t.bin',
  sourceVocab: 'models/en-de/run1/vocab.ende.spm',
);

const _zhen = ModelPaths(
  key: 'zh_hant-en/run2',
  model: 'models/zh_hant-en/run2/model.bin',
  shortlist: 'models/zh_hant-en/run2/lex.bin',
  sourceVocab: 'models/zh_hant-en/run2/srcvocab.spm',
  targetVocab: 'models/zh_hant-en/run2/trgvocab.spm',
);

void main() {
  late FakeBergamotWorker worker;
  late WorkerBergamotEngine engine;

  setUp(() {
    worker = FakeBergamotWorker();
    for (final model in [_ende, _zhen]) {
      for (final path in [model.model, model.shortlist, model.sourceVocab]) {
        worker.files[path] = Uint8List(1);
      }
    }
    engine = WorkerBergamotEngine(worker);
  });

  test('modelSpec has the files and the languages of the key', () {
    expect(WorkerBergamotEngine.modelSpec(_ende), {
      'key': 'en-de/run1',
      'source': 'en',
      'target': 'de',
      'model': _ende.model,
      'shortlist': _ende.shortlist,
      'sourceVocab': _ende.sourceVocab,
    });
    expect(
      WorkerBergamotEngine.modelSpec(_zhen),
      containsPair('source', 'zh_hant'),
    );
    expect(
      WorkerBergamotEngine.modelSpec(_zhen),
      containsPair('targetVocab', _zhen.targetVocab),
    );
    const odd = ModelPaths(
      key: 'x',
      model: 'm',
      shortlist: 's',
      sourceVocab: 'v',
    );
    expect(WorkerBergamotEngine.modelSpec(odd), containsPair('source', 'und'));
  });

  test('configures the worker once, before the first request', () async {
    engine = WorkerBergamotEngine(worker, maxLoadedModels: 3, workspaceMb: 16);
    await engine.translate([_ende], 'hello');
    await engine.translate([_ende], 'again');
    expect(worker.ops.where((op) => op == 'configure'), hasLength(1));
    expect(worker.ops.first, 'configure');
    expect(worker.maxModels, 3);
    expect(worker.workspace, 16);
  });

  test('a failed configuration is tried again', () async {
    worker.failNext['configure'] = const BergamotWorkerException(
      BergamotWorkerErrorKind.protocol,
      'busy',
    );
    await expectLater(
      engine.translate([_ende], 'hello'),
      throwsA(isA<BergamotEngineException>()),
    );
    expect(await engine.translate([_ende], 'hello'), 'HELLO');
    expect(worker.ops.where((op) => op == 'configure'), hasLength(2));
  });

  test('translate and translateBatch parse the engine JSON', () async {
    expect(await engine.translate([_ende], 'hello'), 'HELLO');
    final batch = await engine.translateBatch(
      [_ende],
      ['one', 'two'],
      details: true,
      html: true,
    );
    expect([for (final result in batch) result.text], ['ONE', 'TWO']);
    expect(batch.first.sentences.single.words.single.alignment, 0.9);
    final (_, arguments) = worker.requests.last;
    expect(arguments['html'], isTrue);
    expect(arguments['details'], isTrue);
    expect(arguments['texts'], ['one', 'two']);
  });

  test('an empty batch sends nothing', () async {
    expect(await engine.translateBatch([_ende], const []), isEmpty);
    expect(worker.requests, isEmpty);
  });

  test('a non-JSON answer is an engine error', () async {
    final strange = _Answering('translate', 42);
    engine = WorkerBergamotEngine(strange);
    await expectLater(
      engine.translate([_ende], 'x'),
      throwsA(isA<BergamotEngineException>()),
    );
  });

  test('worker errors become BergamotEngineException', () async {
    worker.failNext['translate'] = const BergamotWorkerException(
      BergamotWorkerErrorKind.engine,
      'Engine aborted: OOM',
    );
    await expectLater(
      engine.translate([_ende], 'x'),
      throwsA(
        isA<BergamotEngineException>().having(
          (error) => error.message,
          'message',
          'engine: Engine aborted: OOM',
        ),
      ),
    );
    // The next request works again.
    expect(await engine.translate([_ende], 'x'), 'X');
  });

  test('other errors pass through', () async {
    engine = WorkerBergamotEngine(_Throwing(StateError('boom')));
    await expectLater(
      engine.translate([_ende], 'x'),
      throwsA(isA<StateError>()),
    );
  });

  test('requests go one at a time, in order', () async {
    final hold = worker.holds['translate'] = Completer<void>();
    final first = engine.translate([_ende], 'first');
    final second = engine.translate([_ende], 'second');
    await pumpEventQueue();
    expect(worker.ops.where((op) => op == 'translate'), hasLength(1));
    hold.complete();
    expect(await first, 'FIRST');
    expect(await second, 'SECOND');
  });

  test('an aborted waiting request never reaches the worker', () async {
    final hold = worker.holds['translate'] = Completer<void>();
    final first = engine.translate([_ende], 'first');
    final abort = Completer<void>();
    final second = engine.translateBatch(
      [_ende],
      ['second'],
      abort: abort.future,
    );
    await pumpEventQueue();
    abort.complete();
    await expectLater(
      second,
      throwsA(isA<OfflineTranslationCancelledException>()),
    );
    hold.complete();
    expect(await first, 'FIRST');
    final texts = [
      for (final (op, arguments) in worker.requests)
        if (op == 'translate') arguments['texts'],
    ];
    expect(texts, [
      ['first'],
    ]);
  });

  test('an aborted running request releases its caller at once', () async {
    final hold = worker.holds['translate'] = Completer<void>();
    final abort = Completer<void>();
    final running = engine.translateBatch(
      [_ende],
      ['slow'],
      abort: abort.future,
    );
    await pumpEventQueue();
    abort.completeError(StateError('cancelled'));
    await expectLater(
      running,
      throwsA(isA<OfflineTranslationCancelledException>()),
    );
    hold.complete();
    // The engine goes on with the next request.
    expect(await engine.translate([_ende], 'next'), 'NEXT');
  });

  test('an abort after the answer changes nothing', () async {
    final abort = Completer<void>();
    final result = await engine.translateBatch(
      [_ende],
      ['done'],
      abort: abort.future,
    );
    abort.complete();
    await pumpEventQueue();
    expect(result.single.text, 'DONE');
  });

  test('preload, trim, release and dispose reach the worker', () async {
    await engine.preload([_ende]);
    expect(worker.loaded, ['en-de/run1']);
    await engine.trim();
    await engine.release('en-de/run1');
    expect(worker.loaded, isEmpty);
    await engine.preload([_zhen]);
    await engine.dispose();
    expect(worker.loaded, isEmpty);
    expect(worker.ops, [
      'configure',
      'preload',
      'trim',
      'release',
      'preload',
      'dispose',
    ]);
  });
}

/// A worker that answers [op] with [answer].
class _Answering implements BergamotWorkerChannel {
  new(this.op, this.answer);

  final String op;
  final Object? answer;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async => op == this.op ? answer : null;

  @override
  void terminate() {}
}

/// A worker whose requests throw [error].
class _Throwing implements BergamotWorkerChannel {
  new(this.error);

  final Error error;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (op == 'configure') return null;
    throw error;
  }

  @override
  void terminate() {}
}
