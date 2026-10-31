import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';

import '../../image_translate/helpers/fake_ocr.dart';

void main() {
  late CancellableOcrData data;
  late MemoryStore store;

  setUp(() {
    data = CancellableOcrData();
    store = MemoryStore();
  });

  OcrLanguagesCubit build({TextRecognitionLanguageData? using}) =>
      OcrLanguagesCubit(data: using ?? data, store: store);

  Future<OcrLanguagesCubit> downloadingFrench() async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.load();
    unawaited(cubit.download('fra'));
    await pumpEventQueue();
    return cubit;
  }

  group('OcrLanguagesCubit cancel', () {
    test('data with CancellableOcrDownloads can cancel', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.canCancel, isTrue);

      final plain = build(using: FakeOcrData());
      addTearDown(plain.close);
      await plain.load();
      expect(plain.state.canCancel, isFalse);
      expect(plain.state.canCancelDownload('fra'), isFalse);
    });

    test('cannot cancel where recognition cannot run', () async {
      data.isSupported = false;
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.canCancel, isFalse);
    });

    test('stops a running download quietly, installing nothing', () async {
      final cubit = await downloadingFrench();
      expect(cubit.state.pending, {'fra': OfflineModelOperation.download});
      expect(cubit.state.canCancelDownload('fra'), isTrue);
      final states = <OcrLanguagesState>[];
      final subscription = cubit.stream.listen(states.add);
      addTearDown(subscription.cancel);

      await cubit.cancelDownload('fra');
      expect(cubit.state.cancelling, {'fra'});
      expect(cubit.state.canCancelDownload('fra'), isFalse);
      await pumpEventQueue();

      expect(data.cancelled, ['fra']);
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.cancelling, isEmpty);
      expect(cubit.state.outcome, isNull);
      expect(cubit.state.isInstalled('fra'), isFalse);
      expect(states.every((state) => state.outcome == null), isTrue);
    });

    test('a download that fails as it is cancelled stays quiet', () async {
      data.stopWith = Exception('connection closed');
      final cubit = await downloadingFrench();
      await cubit.cancelDownload('fra');
      await pumpEventQueue();
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.outcome, isNull);
    });

    test('does nothing without a running download', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.cancelDownload('fra');
      expect(data.cancelled, isEmpty);
      expect(cubit.state.cancelling, isEmpty);

      final plain = build(using: FakeOcrData());
      addTearDown(plain.close);
      await plain.load();
      await plain.cancelDownload('fra');
      expect(plain.state.cancelling, isEmpty);
    });

    test('a finished download still reports its outcome', () async {
      data.downloadGate = Completer<void>()..complete();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.download('fra');
      expect(cubit.state.outcome?.succeeded, isTrue);
      expect(cubit.state.isInstalled('fra'), isTrue);
    });

    blocTest<OcrLanguagesCubit, OcrLanguagesState>(
      'reports a cancel that fails',
      setUp: () => data.cancelError = Exception('gone'),
      build: build,
      act: (cubit) async {
        await cubit.load();
        unawaited(cubit.download('fra'));
        await pumpEventQueue();
        await cubit.cancelDownload('fra');
      },
      skip: 4,
      expect: () => [
        isA<OcrLanguagesState>().having(
          (state) => state.cancelling,
          'cancelling',
          {'fra'},
        ),
      ],
      errors: () => [isA<Exception>()],
    );

    test('the error of a failed download is still reported', () async {
      data.stopWith = Exception('reset');
      final cubit = await downloadingFrench();
      // Not cancelled by the user: the download fails on its own.
      unawaited(data.cancelOcrDownload('fra'));
      await pumpEventQueue();
      expect(cubit.state.outcome?.succeeded, isFalse);
      expect(cubit.state.outcome?.error?.kind, OfflineModelErrorKind.unknown);
    });
  });
}
