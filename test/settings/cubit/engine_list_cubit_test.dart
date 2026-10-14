import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/cubit/engine_list_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

final _google = TranslationEngine.mozhi('google', 'Google');
const _claude = TranslationEngine(
  id: 'ai:p1',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
);

void main() {
  late TranslationRepository repository;

  setUp(() {
    repository = _MockTranslationRepository();
  });

  EngineListCubit buildCubit() => EngineListCubit(repository: repository);

  group(EngineListState, () {
    test('starts without engines', () {
      expect(const EngineListState().status, EngineListStatus.initial);
      expect(const EngineListState().engines, isEmpty);
    });

    test('finds engines by id', () {
      final state = EngineListState(engines: [_google, _claude]);

      expect(state.engine('ai:p1'), _claude);
      expect(state.engine('mozhi:deepl'), isNull);
      expect(state.engine(null), isNull);
    });

    test('copyWith keeps what is not given', () {
      final state = EngineListState(engines: [_google]);

      expect(state.copyWith(), state);
      expect(
        state.copyWith(status: EngineListStatus.ready),
        EngineListState(status: EngineListStatus.ready, engines: [_google]),
      );
      expect(state.copyWith(engines: const [_claude]).engines, const [_claude]);
    });
  });

  group(EngineListCubit, () {
    test('starts in the initial state', () {
      expect(buildCubit().state, const EngineListState());
    });

    blocTest<EngineListCubit, EngineListState>(
      'load emits the engines',
      setUp: () =>
          when(() => repository.getEngines())
              .thenAnswer((_) async => [_google, _claude]),
      build: buildCubit,
      act: (cubit) => cubit.load(),
      expect: () => [
        const EngineListState(status: EngineListStatus.loading),
        EngineListState(
          status: EngineListStatus.ready,
          engines: [_google, _claude],
        ),
      ],
    );

    blocTest<EngineListCubit, EngineListState>(
      'load(refresh: true) reloads and keeps the engines while loading',
      setUp: () =>
          when(() => repository.getEngines(refresh: true))
              .thenAnswer((_) async => [_claude]),
      build: buildCubit,
      seed: () =>
          EngineListState(status: EngineListStatus.failure, engines: [_google]),
      act: (cubit) => cubit.load(refresh: true),
      expect: () => [
        EngineListState(status: EngineListStatus.loading, engines: [_google]),
        const EngineListState(
          status: EngineListStatus.ready,
          engines: [_claude],
        ),
      ],
    );

    blocTest<EngineListCubit, EngineListState>(
      'load emits failure and reports the error',
      setUp: () =>
          when(() => repository.getEngines()).thenThrow(StateError('offline')),
      build: buildCubit,
      act: (cubit) => cubit.load(),
      expect: () => const [
        EngineListState(status: EngineListStatus.loading),
        EngineListState(status: EngineListStatus.failure),
      ],
      errors: () => [isA<StateError>()],
    );

    blocTest<EngineListCubit, EngineListState>(
      'does not emit after close',
      setUp: () =>
          when(() => repository.getEngines())
              .thenAnswer((_) async => [_google]),
      build: buildCubit,
      act: (cubit) async {
        final load = cubit.load();
        await cubit.close();
        await load;
      },
      expect: () => const [EngineListState(status: EngineListStatus.loading)],
    );

    blocTest<EngineListCubit, EngineListState>(
      'reports a failure after close without emitting',
      setUp: () =>
          when(() => repository.getEngines())
              .thenAnswer((_) => Future.error(StateError('offline'))),
      build: buildCubit,
      act: (cubit) async {
        final load = cubit.load();
        await cubit.close();
        await load;
      },
      expect: () => const [EngineListState(status: EngineListStatus.loading)],
      errors: () => [isA<StateError>()],
    );
  });
}
