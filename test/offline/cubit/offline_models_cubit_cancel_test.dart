import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

OfflineLanguage _describe(String code) => OfflineLanguage(
  code: code,
  name: switch (code) {
    'de' => 'German',
    'fr' => 'French',
    _ => code,
  },
);

void main() {
  late CancellableTranslatorStub stub;
  late MemoryStore store;

  setUp(() {
    stub = CancellableTranslatorStub();
    store = MemoryStore();
  });

  OfflineModelsCubit build({OfflineModelDetails? details}) =>
      OfflineModelsCubit(
        translator: stub.translator,
        store: store,
        details: details,
        describe: _describe,
      );

  /// Loads [cubit] and starts downloading French.
  Future<void> startFrench(OfflineModelsCubit cubit) async {
    await cubit.load();
    unawaited(cubit.download('fr'));
    await pumpEventQueue();
  }

  group('OfflineModelsCubit cancel', () {
    test('a translator with CancellableDownloads can cancel', () async {
      final cubit = build();
      await cubit.load();
      expect(cubit.state.canCancel, isTrue);
      await cubit.close();

      final plain = OfflineModelsCubit(
        translator: stubOfflineTranslator(),
        store: store,
        describe: _describe,
      );
      await plain.load();
      expect(plain.state.canCancel, isFalse);
      await plain.close();

      final unavailable = OfflineModelsCubit(
        translator: CancellableTranslatorStub(available: false).translator,
        store: store,
        describe: _describe,
      );
      await unavailable.load();
      expect(unavailable.state.canCancel, isFalse);
      await unavailable.close();
    });

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'stops the download quietly: no outcome, still not downloaded',
      build: build,
      act: (cubit) async {
        await startFrench(cubit);
        await cubit.cancelDownload('fr');
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        isA<OfflineModelsState>()
            .having((s) => s.pending, 'pending', {
              'fr': OfflineModelOperation.download,
            })
            .having((s) => s.outcome, 'outcome', isNull),
        isA<OfflineModelsState>()
            .having((s) => s.cancelling, 'cancelling', {'fr'})
            .having((s) => s.canCancelDownload('fr'), 'can cancel', isFalse),
        isA<OfflineModelsState>()
            .having((s) => s.pending, 'pending', isEmpty)
            .having((s) => s.cancelling, 'cancelling', isEmpty)
            .having((s) => s.outcome, 'outcome', isNull)
            .having((s) => s.downloaded, 'downloaded', {'en', 'de'}),
      ],
      errors: () => <Object>[],
      verify: (_) => expect(stub.cancelled, ['fr']),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'with details: re-reads the models and reports nothing',
      build: () => build(details: _CancelledDetails(stub)),
      act: (cubit) async {
        await startFrench(cubit);
        await cubit.cancelDownload('fr');
        await pumpEventQueue();
      },
      verify: (cubit) {
        expect(cubit.state.pending, isEmpty);
        expect(cubit.state.progress, isEmpty);
        expect(cubit.state.outcome, isNull);
        expect(cubit.state.isDownloaded('fr'), isFalse);
        expect(stub.cancelled, ['fr']);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'a failure while cancelling is quiet too',
      build: build,
      act: (cubit) async {
        await startFrench(cubit);
        when(() => stub.translator.cancelDownload(any()))
            .thenAnswer((_) async {});
        await cubit.cancelDownload('fr');
        stub.finishDownload(
          'fr',
          error: const ModelDownloadException('en-fr', 'connection closed'),
        );
        await pumpEventQueue();
      },
      verify: (cubit) {
        expect(cubit.state.pending, isEmpty);
        expect(cubit.state.cancelling, isEmpty);
        expect(cubit.state.outcome, isNull);
      },
      errors: () => [isA<ModelDownloadException>()],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'a download that finished before the cancel is reported as done',
      build: build,
      act: (cubit) async {
        await startFrench(cubit);
        when(() => stub.translator.cancelDownload(any()))
            .thenAnswer((_) async {});
        await cubit.cancelDownload('fr');
        stub.finishDownload('fr');
        await pumpEventQueue();
      },
      verify: (cubit) {
        expect(cubit.state.outcome?.succeeded, isTrue);
        expect(cubit.state.isDownloaded('fr'), isTrue);
        expect(cubit.state.cancelling, isEmpty);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'a failed download still says why',
      build: build,
      act: (cubit) async {
        await startFrench(cubit);
        stub.finishDownload(
          'fr',
          error: const ModelDownloadException('en-fr', 'offline'),
        );
        await pumpEventQueue();
      },
      verify: (cubit) {
        final outcome = cubit.state.outcome!;
        expect(outcome.succeeded, isFalse);
        expect(outcome.error?.kind, OfflineModelErrorKind.network);
      },
      errors: () => [isA<ModelDownloadException>()],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'does nothing without a running download or twice',
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.cancelDownload('fr');
        unawaited(cubit.delete('de'));
        await cubit.cancelDownload('de');
        await pumpEventQueue();
        unawaited(cubit.download('fr'));
        await pumpEventQueue();
        when(() => stub.translator.cancelDownload(any()))
            .thenAnswer((_) async {});
        await cubit.cancelDownload('fr');
        await cubit.cancelDownload('fr');
        stub.finishDownload('fr');
        await pumpEventQueue();
      },
      verify: (_) =>
          verify(() => stub.translator.cancelDownload('fr')).called(1),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'does nothing for a translator without CancellableDownloads',
      build: () => OfflineModelsCubit(
        translator: stubOfflineTranslator(),
        store: store,
        describe: _describe,
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.cancelDownload('fr');
      },
      skip: 2,
      expect: () => <OfflineModelsState>[],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reports a cancel that throws',
      build: build,
      act: (cubit) async {
        await startFrench(cubit);
        when(() => stub.translator.cancelDownload(any()))
            .thenThrow(StateError('stuck'));
        await cubit.cancelDownload('fr');
        stub.finishDownload(
          'fr',
          error: const OfflineDownloadCancelledException(),
        );
        await pumpEventQueue();
      },
      verify: (cubit) => expect(cubit.state.outcome, isNull),
      errors: () => [isStateError],
    );
  });

  group('OfflineModelsState.canCancelDownload', () {
    test('only for a running download or update that is not stopping', () {
      const state = OfflineModelsState(
        canCancel: true,
        pending: {
          'de': OfflineModelOperation.download,
          'fr': OfflineModelOperation.update,
          'ja': OfflineModelOperation.delete,
          'xx': OfflineModelOperation.download,
        },
        cancelling: {'xx'},
      );
      expect(state.canCancelDownload('de'), isTrue);
      expect(state.canCancelDownload('fr'), isTrue);
      expect(state.canCancelDownload('ja'), isFalse);
      expect(state.canCancelDownload('xx'), isFalse);
      expect(state.canCancelDownload('en'), isFalse);
      expect(state.copyWith(canCancel: false).canCancelDownload('de'), isFalse);
    });
  });
}

/// Details whose downloads go to the stub's translator (as
/// `BergamotModelDetails` does), reporting some progress first.
class _CancelledDetails implements OfflineModelDetails {
  new(this.stub);

  final CancellableTranslatorStub stub;

  @override
  int downloadSize(String code) => testDownloadSizes[code] ?? 0;

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async => testStorage;

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) {
    onProgress?.call(0.3);
    return stub.translator.downloadLanguage(code, wifiOnly: wifiOnly);
  }
}
