import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  List<TranslationEngine> comparedEngines() =>
      verify(() => mocks.repository.compare(captureAny(), any()))
              .captured
              .single
          as List<TranslationEngine>;

  final googleEntry = CompareEntry.success(resultOf('Hallo'));
  final deeplEntry = CompareEntry.success(resultOf('Hallo!', engine: deepl));
  final claudeFailure = CompareEntry.failure(
    engineId: claude.id,
    engineName: claude.name,
    error: Exception('quota'),
  );

  group('setCompareMode', () {
    blocTest<TranslateCubit, TranslateState>(
      'toggles compare mode',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit
        ..setCompareMode(enabled: true)
        ..setCompareMode(enabled: true)
        ..setCompareMode(enabled: false),
      expect: () => [readyState().copyWith(compareMode: true), readyState()],
    );

    blocTest<TranslateCubit, TranslateState>(
      'disabling cancels a running compare and drops its entries',
      setUp: () {
        final controller = StreamController<CompareEntry>();
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => controller.stream);
        unawaited(
          Future<void>(() async {
            controller.add(googleEntry);
            await Future<void>.delayed(const Duration(milliseconds: 5));
            expect(controller.hasListener, isFalse);
          }),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello').copyWith(compareMode: true),
      act: (cubit) async {
        final done = cubit.runCompare();
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.compareEntries, [googleEntry]);
        cubit.setCompareMode(enabled: false);
        await done;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      verify: (cubit) {
        expect(cubit.state.compareMode, isFalse);
        expect(cubit.state.comparing, isFalse);
        expect(cubit.state.compareEntries, isEmpty);
      },
    );
  });

  group('runCompare', () {
    blocTest<TranslateCubit, TranslateState>(
      'runs all engines and collects entries progressively',
      setUp: () {
        when(() => mocks.repository.compare(any(), any())).thenAnswer(
          (_) => Stream.fromIterable([googleEntry, deeplEntry, claudeFailure]),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hello',
        target: de,
      ).copyWith(compareMode: true, error: () => 'old'),
      act: (cubit) => cubit.runCompare(),
      expect: () {
        final base = readyState(
          input: 'Hello',
          target: de,
        ).copyWith(compareMode: true);
        return [
          base.copyWith(comparing: true),
          base.copyWith(comparing: true, compareEntries: [googleEntry]),
          base.copyWith(
            comparing: true,
            compareEntries: [googleEntry, deeplEntry],
          ),
          base.copyWith(
            comparing: true,
            compareEntries: [googleEntry, deeplEntry, claudeFailure],
          ),
          base.copyWith(
            compareEntries: [googleEntry, deeplEntry, claudeFailure],
          ),
        ];
      },
      verify: (_) {
        final captured = verify(
          () => mocks.repository.compare(captureAny(), captureAny()),
        ).captured;
        expect(captured.first, allEngines);
        expect(
          captured.last,
          const TranslationRequest(
            text: 'Hello',
            source: Language.auto,
            target: de,
          ),
        );
        verifyNever(() => mocks.history.add(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'runs only the configured engines',
      setUp: () {
        mocks.stubSettings(
          const AppSettings(compareEngineIds: ['ai:claude', 'mozhi:deepl']),
        );
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) => cubit.runCompare(),
      verify: (_) => expect(comparedEngines(), [deepl, claude]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'falls back to all engines when none of the configured exist',
      setUp: () {
        mocks.stubSettings(const AppSettings(compareEngineIds: ['ai:gone']));
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) => cubit.runCompare(),
      verify: (_) => expect(comparedEngines(), allEngines),
    );

    blocTest<TranslateCubit, TranslateState>(
      'excludes Mozhi engines for custom targets',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: claude,
        input: 'Hello',
        target: pirate,
        engines: [google, claude, local],
      ),
      act: (cubit) => cubit.runCompare(),
      verify: (_) => expect(comparedEngines(), [claude, local]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without input or eligible engines',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(engines: [google], target: pirate),
      act: (cubit) async {
        await cubit.runCompare();
        cubit.setInputAndTranslate('Hello');
        await cubit.runCompare();
      },
      verify: (_) {
        verifyNever(() => mocks.repository.compare(any(), any()));
      },
    );

    final compareError = Exception('boom');

    blocTest<TranslateCubit, TranslateState>(
      'stops comparing on a stream error',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) async* {
              yield googleEntry;
              throw compareError;
            });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) => cubit.runCompare(),
      verify: (cubit) {
        expect(cubit.state.comparing, isFalse);
        expect(cubit.state.error, compareError);
        expect(cubit.state.compareEntries, [googleEntry]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'stops comparing when the repository throws',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenThrow(compareError);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) => cubit.runCompare(),
      expect: () => [
        readyState(input: 'Hello').copyWith(comparing: true),
        readyState(input: 'Hello').copyWith(error: () => compareError),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'a new run cancels the previous one',
      setUp: () {
        final first = StreamController<CompareEntry>();
        var calls = 0;
        when(() => mocks.repository.compare(any(), any())).thenAnswer((_) {
          calls++;
          return calls == 1 ? first.stream : Stream.value(deeplEntry);
        });
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            expect(first.hasListener, isFalse);
            first.add(googleEntry);
          }),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) async {
        final firstDone = cubit.runCompare();
        await Future<void>.delayed(Duration.zero);
        await cubit.runCompare();
        await firstDone;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      verify: (cubit) {
        expect(cubit.state.compareEntries, [deeplEntry]);
        expect(cubit.state.comparing, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'typing drops the running compare',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => StreamController<CompareEntry>().stream);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello').copyWith(compareMode: true),
      act: (cubit) async {
        final done = cubit.runCompare();
        cubit.setInput('Hello!');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.comparing, isFalse);
        expect(cubit.state.compareEntries, isEmpty);
      },
    );
  });

  group('useCompareEntry', () {
    blocTest<TranslateCubit, TranslateState>(
      'uses the entry and switches to its engine without translating',
      setUp: () {
        mocks.stubSettings(const AppSettings(target: de));
        when(() => mocks.repository.getTargetLanguages(deepl))
            .thenAnswer((_) async => [en, de, ja]);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hello',
        target: de,
      ).copyWith(compareMode: true, compareEntries: [googleEntry, deeplEntry]),
      act: (cubit) async {
        cubit.useCompareEntry(deeplEntry);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.compareMode, isFalse);
        expect(cubit.state.compareEntries, isEmpty);
        expect(cubit.state.result, same(deeplEntry.result));
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.engine, deepl);
        expect(cubit.state.target, de);
        expect(cubit.state.targetLanguages, [en, de, ja]);
        verify(() => mocks.settings.setEngine(deepl.id)).called(1);
        verifyNever(() => mocks.repository.translate(any(), any()));
        final entry = mocks.historyEntries().single;
        expect(entry.engineId, deepl.id);
        expect(entry.translation, 'Hallo!');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the engine when the entry is from the selected engine',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello').copyWith(compareMode: true),
      act: (cubit) => cubit.useCompareEntry(googleEntry),
      verify: (cubit) {
        expect(cubit.state.result, same(googleEntry.result));
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores failures and unknown engines',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello', engines: [google]),
      act: (cubit) => cubit
        ..useCompareEntry(claudeFailure)
        ..useCompareEntry(deeplEntry),
      expect: () => <TranslateState>[],
    );
  });
}
