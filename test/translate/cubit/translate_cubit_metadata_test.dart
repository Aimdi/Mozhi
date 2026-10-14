import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  late StreamController<void> changes;

  setUp(() {
    mocks = TranslateMocks();
    changes = StreamController<void>.broadcast();
    when(() => mocks.repository.metadataChanged)
        .thenAnswer((_) => changes.stream);
  });

  tearDown(() => changes.close());

  group('metadataChanged', () {
    test('is listened to from the first loadEngines on', () async {
      final cubit = mocks.build();
      verifyNever(() => mocks.repository.metadataChanged);
      expect(changes.hasListener, isFalse);

      await cubit.loadEngines();
      await cubit.loadEngines();

      verify(() => mocks.repository.metadataChanged).called(1);
      expect(changes.hasListener, isTrue);
      await cubit.close();
      expect(changes.hasListener, isFalse);
    });

    test('reloads the lists without the loading state', () async {
      final cubit = mocks.build();
      await cubit.loadEngines();
      expect(cubit.state.targetLanguages, targets);

      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => [google, deepl]);
      when(() => mocks.repository.getTargetLanguages(any()))
          .thenAnswer((_) async => [en, de, ja]);
      final statuses = <EnginesStatus>[];
      final subscription = cubit.stream.listen(
        (state) => statuses.add(state.enginesStatus),
      );
      changes.add(null);
      await pumpEventQueue();

      expect(statuses, isNot(contains(EnginesStatus.loading)));
      expect(cubit.state.enginesStatus, EnginesStatus.ready);
      expect(cubit.state.engines, [google, deepl]);
      expect(cubit.state.targetLanguages, [en, de, ja]);
      expect(cubit.state.engine, google);
      verify(() => mocks.repository.getEngines()).called(2);
      await subscription.cancel();
      await cubit.close();
    });

    test('keeps the shown lists when the reload fails', () async {
      final cubit = mocks.build();
      await cubit.loadEngines();
      final before = cubit.state;

      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenThrow(StateError('offline'));
      changes.add(null);
      await pumpEventQueue();

      expect(cubit.state, before);
      await cubit.close();
    });

    test('a repository without the stream is tolerated', () async {
      final repository = MockTranslationRepository();
      when(() => repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => allEngines);
      when(() => repository.getSourceLanguages(any()))
          .thenAnswer((_) async => sources);
      when(() => repository.getTargetLanguages(any()))
          .thenAnswer((_) async => targets);
      final cubit = TranslateCubit(
        repository: repository,
        settings: mocks.settings,
        history: mocks.history,
      );

      await cubit.loadEngines();

      expect(cubit.state.enginesStatus, EnginesStatus.ready);
      await cubit.close();
    });
  });
}
