import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bergamot_worker.dart';

void main() {
  group('BergamotWebSupport.fromProbe', () {
    final complete = FakeBergamotWorker().probe;

    test('a browser with everything is supported', () {
      final support = BergamotWebSupport.fromProbe(complete);
      expect(support.isSupported, isTrue);
      expect(support.reason, isNull);
      expect(support.persisted, isFalse);
      expect(support.toString(), 'BergamotWebSupport(supported)');
    });

    test('reports what is missing, the most actionable first', () {
      final support = BergamotWebSupport.fromProbe({
        ...complete,
        'simd': false,
        'segmenter': false,
        'decompression': false,
        'persisted': true,
      });
      expect(support.missing, {
        BergamotWebRequirement.wasmSimd,
        BergamotWebRequirement.decompression,
        BergamotWebRequirement.segmenter,
      });
      expect(support.reason, BergamotWebRequirement.wasmSimd);
      expect(support.persisted, isTrue);
      expect(support.isSupported, isFalse);
    });

    test('an insecure page needs HTTPS, not storage', () {
      final support = BergamotWebSupport.fromProbe({
        ...complete,
        'secure': false,
        'opfs': false,
        'digest': false,
      });
      expect(support.missing, {BergamotWebRequirement.secureContext});
    });

    test('no private storage or sync access is a storage problem', () {
      expect(
        BergamotWebSupport.fromProbe({...complete, 'opfs': false}).missing,
        {BergamotWebRequirement.storage},
      );
      expect(
        BergamotWebSupport.fromProbe({...complete, 'syncAccess': false})
            .missing,
        {BergamotWebRequirement.storage},
      );
    });

    test('a build without the engine files says so first', () {
      final support = BergamotWebSupport.fromProbe({
        ...complete,
        'engine': false,
        'simd': false,
      });
      expect(support.reason, BergamotWebRequirement.engineFiles);
    });

    test('nonsense means nothing is there', () {
      expect(
        BergamotWebSupport.fromProbe('nonsense').reason,
        BergamotWebRequirement.engineFiles,
      );
    });

    test('equality ignores order', () {
      expect(
        const BergamotWebSupport(
          missing: {
            BergamotWebRequirement.wasmSimd,
            BergamotWebRequirement.storage,
          },
        ),
        const BergamotWebSupport(
          missing: {
            BergamotWebRequirement.storage,
            BergamotWebRequirement.wasmSimd,
          },
        ),
      );
      expect(
        const BergamotWebSupport().hashCode,
        const BergamotWebSupport().hashCode,
      );
      expect(
        const BergamotWebSupport(),
        isNot(const BergamotWebSupport(persisted: true)),
      );
    });
  });

  group('probeBergamotWorker', () {
    test('asks the worker', () async {
      final worker = FakeBergamotWorker();
      expect((await probeBergamotWorker(worker)).isSupported, isTrue);
      expect(worker.ops, ['probe']);
    });

    test('a failing worker is unavailable', () async {
      final worker = FakeBergamotWorker()
        ..failNext['probe'] = const BergamotWorkerException(
          BergamotWorkerErrorKind.unsupported,
          'Cannot start bergamot/worker.js',
        );
      expect(
        await probeBergamotWorker(worker),
        const BergamotWebSupport.unavailable(),
      );
    });

    test('a silent worker is unavailable after the timeout', () async {
      final worker = FakeBergamotWorker()..holds['probe'] = Completer<void>();
      expect(
        await probeBergamotWorker(
          worker,
          timeout: const Duration(milliseconds: 10),
        ),
        const BergamotWebSupport.unavailable(),
      );
    });
  });

  test('BergamotWorkerErrorKind.of reads the worker names', () {
    for (final kind in BergamotWorkerErrorKind.values) {
      expect(BergamotWorkerErrorKind.of(kind.name), kind);
    }
    expect(
      BergamotWorkerErrorKind.of('nonsense'),
      BergamotWorkerErrorKind.protocol,
    );
    expect(
      const BergamotWorkerException(
        BergamotWorkerErrorKind.storage,
        'full',
      ).toString(),
      'BergamotWorkerException(storage: full)',
    );
  });

  test('outside a browser there is no worker and no persistence', () async {
    expect(openBergamotWorker(), isNull);
    expect(await requestPersistentBrowserStorage(), isFalse);
  });
}
