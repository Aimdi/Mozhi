import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bergamot_worker.dart';

void main() {
  late FakeBergamotWorker worker;

  setUp(() => worker = FakeBergamotWorker());

  test('reads both passes and drops "un" slots', () async {
    final detection = await WorkerLanguageIdentifier(worker)
        .identify('Guten Morgen', hints: ['de', 'en']);
    const expected = Cld2Result(
      language: 'de',
      languages: [Cld2Language('de', percent: 97, score: 1345)],
      textBytes: 36,
      reliable: true,
    );
    expect(
      detection,
      const Cld2Detection(precise: expected, bestEffort: expected),
    );
    final (op, arguments) = worker.requests.single;
    expect(op, 'identify');
    expect(arguments, {'text': 'Guten Morgen', 'hints': 'de,en'});
  });

  test('sends no hints when there are none', () async {
    await WorkerLanguageIdentifier(worker).identify('x');
    expect(worker.requests.single.$2, {'text': 'x'});
  });

  test('worker errors become BergamotEngineException', () async {
    worker.failNext['identify'] = const BergamotWorkerException(
      BergamotWorkerErrorKind.engine,
      'detect: failed',
    );
    await expectLater(
      WorkerLanguageIdentifier(worker).identify('x'),
      throwsA(isA<BergamotEngineException>()),
    );
  });

  test('readWorkerDetection tolerates missing and odd values', () {
    expect(readWorkerDetection(null), const Cld2Result());
    expect(
      readWorkerDetection({
        'language': 'pt',
        'languages': [
          {'code': 'pt', 'percent': 88.0, 'score': 1792.0},
          {'code': '', 'percent': 1, 'score': 1},
          'nonsense',
        ],
        'textBytes': 9.0,
        'reliable': 1,
      }),
      const Cld2Result(
        language: 'pt',
        languages: [Cld2Language('pt', percent: 88, score: 1792)],
        textBytes: 9,
      ),
    );
  });
}
