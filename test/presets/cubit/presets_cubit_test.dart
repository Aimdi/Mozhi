import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockStore extends Mock implements KeyValueStore {}

const _a = Preset(id: 'a', name: 'A');
const _b = Preset(
  id: 'b',
  name: 'B',
  options: TranslationOptions(formality: Formality.more),
);
const _c = Preset(
  id: 'c',
  name: 'C',
  options: TranslationOptions(readingLevel: ReadingLevel.a1),
);

PresetsState _ready(List<Preset> presets, {String? defaultId}) => PresetsState(
  status: PresetsStatus.ready,
  presets: presets,
  defaultId: defaultId,
);

void main() {
  late MemoryStore store;
  late PresetsRepository repository;
  late int counter;

  setUp(() {
    store = MemoryStore();
    counter = 0;
    repository = PresetsRepository(
      store: store,
      generateId: () => 'new${counter++}',
    );
  });

  PresetCollection stored() => PresetCollection.tryParse(
    jsonDecode(store.values[PresetsRepository.storageKey]!),
  )!;

  PresetsCubit build() => PresetsCubit(repository: repository);

  group('PresetsCubit', () {
    test('defaults to an empty initial state', () {
      expect(PresetsCubit().state, const PresetsState());
    });

    blocTest<PresetsCubit, PresetsState>(
      'load emits loading then the examples on first launch',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const PresetsState(status: PresetsStatus.loading),
        _ready(PresetCollection.examples().presets),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'load emits the stored presets',
      setUp: () => store.values[PresetsRepository.storageKey] = jsonEncode(
        const PresetCollection(presets: [_a, _b], defaultId: 'b').toJson(),
      ),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        _ready(const [_a, _b], defaultId: 'b'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'load emits failure and reports storage errors',
      build: () {
        final failing = _MockStore();
        when(() => failing.read(any())).thenThrow(StateError('io'));
        return PresetsCubit(repository: PresetsRepository(store: failing));
      },
      act: (cubit) => cubit.load(),
      expect: () => [
        const PresetsState(status: PresetsStatus.loading),
        const PresetsState(status: PresetsStatus.failure),
      ],
      errors: () => [isA<StateError>()],
    );

    blocTest<PresetsCubit, PresetsState>(
      'add appends a preset, strips extras and can make it the default',
      build: build,
      seed: () => _ready(const [_a]),
      act: (cubit) async {
        final preset = await cubit.add(
          name: '  Formal  ',
          options: const TranslationOptions(
            formality: Formality.more,
            glossary: {'x': 'y'},
            instructions: 'z',
          ),
          makeDefault: true,
        );
        expect(preset.id, 'new0');
        expect(stored().defaultId, 'new0');
      },
      expect: () => [
        _ready(const [
          _a,
          Preset(
            id: 'new0',
            name: 'Formal',
            options: TranslationOptions(formality: Formality.more),
          ),
        ], defaultId: 'new0'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'add keeps the current default',
      build: build,
      seed: () => _ready(const [_a], defaultId: 'a'),
      act: (cubit) => cubit.add(name: 'X', options: const TranslationOptions()),
      expect: () => [
        _ready(const [_a, Preset(id: 'new0', name: 'X')], defaultId: 'a'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'update replaces by id and ignores unknown ids',
      build: build,
      seed: () => _ready(const [_a, _b], defaultId: 'b'),
      act: (cubit) async {
        await cubit.update(_a.copyWith(name: ' Renamed '));
        await cubit.update(const Preset(id: 'zz'));
      },
      expect: () => [
        _ready(const [Preset(id: 'a', name: 'Renamed'), _b], defaultId: 'b'),
      ],
      verify: (_) => expect(stored().presets.first.name, 'Renamed'),
    );

    blocTest<PresetsCubit, PresetsState>(
      'delete removes the preset and clears the default',
      build: build,
      seed: () => _ready(const [_a, _b], defaultId: 'b'),
      act: (cubit) async {
        await cubit.delete('b');
        await cubit.delete('zz');
      },
      expect: () => [
        _ready(const [_a]),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'restore puts a preset back (clamped) and restores the default',
      build: build,
      seed: () => _ready(const [_a]),
      act: (cubit) async {
        await cubit.restore(_b, index: 0, makeDefault: true);
        await cubit.restore(_c, index: 99);
      },
      expect: () => [
        _ready(const [_b, _a], defaultId: 'b'),
        _ready(const [_b, _a, _c], defaultId: 'b'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'setDefault sets, clears and ignores unknown or unchanged ids',
      build: build,
      seed: () => _ready(const [_a, _b]),
      act: (cubit) async {
        await cubit.setDefault('b');
        await cubit.setDefault('b');
        await cubit.setDefault('zz');
        await cubit.setDefault(null);
      },
      expect: () => [
        _ready(const [_a, _b], defaultId: 'b'),
        _ready(const [_a, _b]),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'move reorders and ignores invalid indexes',
      build: build,
      seed: () => _ready(const [_a, _b, _c], defaultId: 'c'),
      act: (cubit) async {
        await cubit.move(0, 2);
        await cubit.move(2, 0);
        await cubit.move(1, 1);
        await cubit.move(-1, 0);
        await cubit.move(0, 3);
      },
      expect: () => [
        _ready(const [_b, _c, _a], defaultId: 'c'),
        _ready(const [_a, _b, _c], defaultId: 'c'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'duplicate inserts a copy after the original',
      build: build,
      seed: () => _ready(const [_a, _b, _c], defaultId: 'b'),
      act: (cubit) async {
        final copy = await cubit.duplicate('b', name: 'B (copy)');
        expect(copy?.id, 'new0');
        expect(await cubit.duplicate('zz'), isNull);
        await cubit.duplicate('a');
      },
      expect: () => [
        _ready([
          _a,
          _b,
          _b.copyWith(id: 'new0', name: 'B (copy)'),
          _c,
        ], defaultId: 'b'),
        _ready([
          _a,
          _a.copyWith(id: 'new1'),
          _b,
          _b.copyWith(id: 'new0', name: 'B (copy)'),
          _c,
        ], defaultId: 'b'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'restoreExamples adds missing built-ins with free ids',
      build: build,
      seed: () => _ready([
        Preset.example(BuiltInPreset.chatCasual),
        // Occupies the id of another example.
        const Preset(id: 'builtin-emailFormal', name: 'Mine'),
      ]),
      act: (cubit) async {
        expect(await cubit.restoreExamples(), 2);
        expect(await cubit.restoreExamples(), 0);
      },
      expect: () => [
        _ready([
          Preset.example(BuiltInPreset.chatCasual),
          const Preset(id: 'builtin-emailFormal', name: 'Mine'),
          Preset.example(BuiltInPreset.emailFormal).copyWith(id: 'new0'),
          Preset.example(BuiltInPreset.simpleA2),
        ]),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'importJson appends presets with fresh ids',
      build: build,
      seed: () => _ready(const [_a], defaultId: 'a'),
      act: (cubit) async {
        final json = jsonEncode(
          const PresetCollection(presets: [_b, _c], defaultId: 'b').toJson(),
        );
        expect(await cubit.importJson(json), 2);
        expect(await cubit.importJson('[]'), 0);
        await expectLater(cubit.importJson('nope'), throwsFormatException);
      },
      expect: () => [
        _ready([
          _a,
          _b.copyWith(id: 'new0'),
          _c.copyWith(id: 'new1'),
        ], defaultId: 'a'),
      ],
    );

    blocTest<PresetsCubit, PresetsState>(
      'exportJson exports all or selected presets',
      build: build,
      seed: () => _ready(const [_a, _b], defaultId: 'b'),
      act: (cubit) {
        final all = jsonDecode(cubit.exportJson()) as Map;
        expect(all['presets'], hasLength(2));
        expect(all['defaultId'], 'b');
        final one = jsonDecode(cubit.exportJson(ids: {'a'})) as Map;
        expect(one['presets'], hasLength(1));
      },
      expect: () => <PresetsState>[],
    );

    blocTest<PresetsCubit, PresetsState>(
      'keeps the new state and reports storage errors on save',
      build: () {
        final failing = _MockStore();
        when(() => failing.write(any(), any())).thenThrow(StateError('io'));
        return PresetsCubit(repository: PresetsRepository(store: failing));
      },
      seed: () => _ready(const [_a, _b]),
      act: (cubit) => cubit.delete('a'),
      expect: () => [
        _ready(const [_b]),
      ],
      errors: () => [isA<StateError>()],
    );

    test('does not emit after close', () async {
      final cubit = build();
      await cubit.close();
      await cubit.load();
      await cubit.setDefault(null);
      expect(cubit.state, const PresetsState());
    });
  });

  group('PresetsState', () {
    test('defaultPreset, collection and byId', () {
      final state = _ready(const [_a, _b], defaultId: 'b');
      expect(state.defaultPreset, _b);
      expect(state.byId('a'), _a);
      expect(state.byId(null), isNull);
      expect(
        state.collection,
        const PresetCollection(presets: [_a, _b], defaultId: 'b'),
      );
    });

    test('presetFor prefers the default preset', () {
      const twin = Preset(
        id: 'twin',
        options: TranslationOptions(formality: Formality.more),
      );
      final state = _ready(const [_a, _b, twin], defaultId: 'twin');
      expect(
        state.presetFor(
          const TranslationOptions(
            formality: Formality.more,
            glossary: {'x': 'y'},
          ),
        ),
        twin,
      );
      expect(
        _ready(const [_a, _b, twin])
            .presetFor(const TranslationOptions(formality: Formality.more)),
        _b,
      );
      expect(
        state.presetFor(const TranslationOptions(context: 'unique')),
        isNull,
      );
    });

    test('copyWith', () {
      final state = _ready(const [_a], defaultId: 'a');
      expect(state.copyWith(), state);
      expect(state.copyWith(defaultId: () => null).defaultId, isNull);
      expect(
        state.copyWith(status: PresetsStatus.loading, presets: const []),
        const PresetsState(status: PresetsStatus.loading, defaultId: 'a'),
      );
    });
  });
}
