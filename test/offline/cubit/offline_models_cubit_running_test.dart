import 'dart:async';

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

/// [FakeOfflineModelDetails] that lists [running] downloads (started on
/// another screen).
class _RunningDetails extends FakeOfflineModelDetails
    implements OfflineRunningDownloads {
  final running = <String, OfflineRunningDownload>{};
  Exception? runningError;

  @override
  Map<String, OfflineRunningDownload> get runningDownloads {
    if (runningError case final error?) throw error;
    return running;
  }
}

/// A download running in the engine: its progress and how it ends.
class _Running {
  final progress = StreamController<double>.broadcast();
  final _result = Completer<void>();

  OfflineRunningDownload download({double fraction = 0}) =>
      OfflineRunningDownload(
        progress: fraction,
        progressChanges: progress.stream,
        result: _result.future,
      );

  void end({Object? error}) {
    if (error == null) {
      _result.complete();
    } else {
      _result.completeError(error);
    }
  }
}

void main() {
  late MockOfflineTranslator translator;
  late _RunningDetails details;
  late OfflineDownloadNotices notices;
  late List<OfflineModelOutcome> told;

  setUp(() {
    translator = stubOfflineTranslator();
    details = _RunningDetails();
    notices = OfflineDownloadNotices();
    told = [];
    notices.failures.listen(told.add);
  });

  tearDown(() => notices.close());

  OfflineModelsCubit build() => OfflineModelsCubit(
    translator: translator,
    store: MemoryStore(),
    details: details,
    describe: _describe,
    notices: notices,
  );

  group('OfflineModelsCubit with downloads started elsewhere', () {
    test('load shows them pending, with their progress', () async {
      final running = _Running();
      details.running['fr'] = running.download(fraction: 0.25);
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.pending, {'fr': OfflineModelOperation.download});
      expect(cubit.state.progress, {'fr': 0.25});
      expect(cubit.state.canCancelDownload('fr'), isFalse);

      running.progress.add(0.5);
      await pumpEventQueue();
      expect(cubit.state.progress, {'fr': 0.5});
      running.end();
    });

    test('their outcome is shown here', () async {
      final running = _Running();
      details.running['fr'] = running.download();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de', 'fr'});
      running.end();
      await pumpEventQueue();

      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.downloaded, {'en', 'de', 'fr'});
      expect(
        cubit.state.outcome,
        OfflineModelOutcome(
          language: _describe('fr'),
          operation: OfflineModelOperation.download,
          succeeded: true,
        ),
      );
      // Nothing to tell app-wide: the screen showed it.
      expect(told, isEmpty);
    });

    test('a failure is shown here, not app-wide', () async {
      final running = _Running();
      details.running['fr'] = running.download();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      running.end(error: const SocketExceptionLike());
      await pumpEventQueue();

      final outcome = cubit.state.outcome!;
      expect(outcome.succeeded, isFalse);
      expect(outcome.error?.kind, isNot(OfflineModelErrorKind.metered));
      expect(told, isEmpty);
    });

    test('an outdated language updates', () async {
      details.storageValue = const OfflineStorage(outdated: {'de'});
      details.running['de'] = _Running().download();
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.pending, {'de': OfflineModelOperation.update});
    });

    test('download waits for the running one and starts none', () async {
      final running = _Running();
      details.running['fr'] = running.download();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      var done = false;
      unawaited(cubit.download('fr').then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse);

      running.end();
      await pumpEventQueue();
      expect(done, isTrue);
      expect(details.downloads, isEmpty);
      expect(cubit.state.outcome?.succeeded, isTrue);
    });

    test('loading again does not follow a download twice', () async {
      final running = _Running();
      details.running['fr'] = running.download();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.load();

      final outcomes = <OfflineModelOutcome>[];
      cubit.stream.listen((state) {
        if (state.outcome case final outcome?) outcomes.add(outcome);
      });
      running.end();
      await pumpEventQueue();
      expect(outcomes.toSet(), hasLength(1));
      expect(cubit.state.pending, isEmpty);
    });

    test('an engine that cannot tell them is reported, not fatal', () async {
      details.runningError = Exception('broken');
      final cubit = build();
      addTearDown(cubit.close);
      final errors = <Object>[];
      final listener = cubit.stream.listen((_) {}, onError: errors.add);
      addTearDown(listener.cancel);

      await cubit.load();

      expect(cubit.state.status, OfflineModelsStatus.ready);
      expect(cubit.state.pending, isEmpty);
    });

    test('without the engine nothing is followed', () async {
      when(() => translator.isAvailable).thenReturn(false);
      details.running['fr'] = _Running().download();
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.pending, isEmpty);
    });
  });

  group('OfflineModelsCubit after its screen closed', () {
    test('a failed download is told app-wide', () async {
      final hold = details.hold = Completer<void>();
      final cubit = build();
      await cubit.load();
      unawaited(cubit.download('fr'));
      await pumpEventQueue();
      await cubit.close();

      details.error = Exception('connection reset');
      hold.complete();
      await pumpEventQueue();

      expect(told, hasLength(1));
      expect(told.single.language, _describe('fr'));
      expect(told.single.operation, OfflineModelOperation.download);
      expect(told.single.succeeded, isFalse);
    });

    test('a failed update is told as an update', () async {
      details.storageValue = const OfflineStorage(outdated: {'de'});
      final hold = details.hold = Completer<void>();
      final cubit = build();
      await cubit.load();
      unawaited(cubit.download('de'));
      await pumpEventQueue();
      await cubit.close();

      details.error = Exception('connection reset');
      hold.complete();
      await pumpEventQueue();

      expect(told.single.operation, OfflineModelOperation.update);
    });

    test('a successful or cancelled download is not told', () async {
      final hold = details.hold = Completer<void>();
      final cubit = build();
      await cubit.load();
      unawaited(cubit.download('fr'));
      unawaited(cubit.download('ja'));
      await pumpEventQueue();
      await cubit.close();
      hold.complete();
      await pumpEventQueue();
      expect(told, isEmpty);

      final cancelled = details.hold = Completer<void>();
      details.error = const OfflineDownloadCancelledException('fr');
      final other = build();
      await other.load();
      unawaited(other.download('fr'));
      await pumpEventQueue();
      await other.close();
      cancelled.complete();
      await pumpEventQueue();
      expect(told, isEmpty);
    });

    test('a failed delete is not told', () async {
      final deleted = Completer<void>();
      when(() => translator.deleteLanguage(any()))
          .thenAnswer((_) => deleted.future);
      final cubit = build();
      await cubit.load();
      unawaited(cubit.delete('de'));
      await pumpEventQueue();
      await cubit.close();
      deleted.completeError(Exception('busy'));
      await pumpEventQueue();
      expect(told, isEmpty);
    });

    test('not told while another screen shows the download', () async {
      // Started here...
      final hold = details.hold = Completer<void>();
      final first = build();
      await first.load();
      unawaited(first.download('fr'));
      await pumpEventQueue();
      // ...shown on another screen too...
      final running = _Running();
      details.running['fr'] = running.download();
      final second = build();
      addTearDown(second.close);
      await second.load();
      expect(second.state.pending, contains('fr'));
      // ...and this one closes.
      await first.close();

      details.error = Exception('connection reset');
      hold.complete();
      running.end(error: Exception('connection reset'));
      await pumpEventQueue();

      expect(second.state.outcome?.succeeded, isFalse);
      expect(told, isEmpty);
    });

    test('told once when every screen showing it has closed', () async {
      final hold = details.hold = Completer<void>();
      final first = build();
      await first.load();
      unawaited(first.download('fr'));
      await pumpEventQueue();
      final running = _Running();
      details.running['fr'] = running.download();
      final second = build();
      await second.load();
      await first.close();
      await second.close();

      details.error = Exception('connection reset');
      hold.complete();
      running.end(error: Exception('connection reset'));
      await pumpEventQueue();

      expect(told, hasLength(1));
    });
  });
}

/// A network failure, as the engine reports it.
class SocketExceptionLike implements Exception {
  const new();
}
