import 'dart:io' show FileSystemException;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/translate/cubit/on_device_ai_offer_cubit.dart';

import '../helpers/fake_on_device_models.dart';

class _UnreadyModels extends FakeOnDeviceModels {
  new(super.models);

  @override
  Future<void> get ready async => throw const FileSystemException('unreadable');
}

class _ThrowingStore extends Fake implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('locked');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('locked');
}

final _now = DateTime(2026, 10, 22, 12);

void main() {
  late FakeOnDeviceModels models;
  late MemoryStore store;

  setUp(() {
    models = FakeOnDeviceModels([
      catalogModel('hy-mt2', size: 1100000000),
      catalogModel('gemma', size: 2600000000, role: LlamaModelRole.assistant),
      catalogModel('qwen', size: 1200000000, role: LlamaModelRole.assistant),
    ]);
    store = MemoryStore();
    addTearDown(models.controller.close);
  });

  OnDeviceAiOfferCubit build({DateTime? now, KeyValueStore? on}) =>
      OnDeviceAiOfferCubit(
        models: models,
        store: on ?? store,
        clock: () => now ?? _now,
      );

  const hidden = OnDeviceAiOfferState(status: OnDeviceAiOfferStatus.hidden);

  group(OnDeviceAiOfferCubit, () {
    test('starts undecided', () {
      expect(build().state.status, OnDeviceAiOfferStatus.checking);
      expect(build().state.shown, isFalse);
    });

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'offers it with the smallest download that fits',
      setUp: () => models.fits = {'hy-mt2': OnDeviceFit.tooBig},
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [
        OnDeviceAiOfferState(
          status: OnDeviceAiOfferStatus.shown,
          smallestDownload: 1200000000,
        ),
      ],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'counts a model that may be slow as fitting, sizes unknown as null',
      setUp: () {
        models = FakeOnDeviceModels([catalogModel('hy-mt2')])
          ..fits = {'hy-mt2': OnDeviceFit.slow};
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [
        OnDeviceAiOfferState(status: OnDeviceAiOfferStatus.shown),
      ],
    );

    for (final fit in [OnDeviceFit.tooBig, OnDeviceFit.unknown]) {
      blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
        'stays away when nothing fits (${fit.name})',
        setUp: () => models.fits = {'hy-mt2': fit, 'gemma': fit, 'qwen': fit},
        build: build,
        act: (cubit) => cubit.load(),
        expect: () => const [hidden],
      );
    }

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'stays away with an empty catalogue',
      setUp: () => models = FakeOnDeviceModels(const []),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [hidden],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'stays away once a model is installed',
      setUp: () => models.assistantModel = 'qwen',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [hidden],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'goes away when a model gets installed',
      build: build,
      act: (cubit) async {
        await cubit.load();
        models.controller.add(null);
        await Future<void>.delayed(Duration.zero);
        models.translationModel = 'hy-mt2';
        models.controller.add(null);
        await Future<void>.delayed(Duration.zero);
      },
      skip: 1,
      expect: () => const [hidden],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'not now hides it for a month',
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.notNow();
      },
      skip: 1,
      expect: () => const [hidden],
      verify: (_) async {
        final until = int.parse(store.values[OnDeviceAiOfferCubit.storeKey]!);
        expect(
          DateTime.fromMillisecondsSinceEpoch(until),
          _now.add(OnDeviceAiOfferCubit.snooze),
        );
        // Still away the next day, back after the month.
        final tomorrow = build(now: _now.add(const Duration(days: 1)));
        await tomorrow.load();
        expect(tomorrow.state, hidden);
        final later = build(now: _now.add(const Duration(days: 31)));
        await later.load();
        expect(later.state.shown, isTrue);
      },
    );

    for (final (name, action) in [
      ('don’t show again', (OnDeviceAiOfferCubit c) => c.never()),
      ('opening the models', (OnDeviceAiOfferCubit c) => c.opened()),
    ]) {
      blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
        '$name hides it for good',
        build: build,
        act: (cubit) async {
          await cubit.load();
          await action(cubit);
        },
        skip: 1,
        expect: () => const [hidden],
        verify: (_) async {
          expect(store.values[OnDeviceAiOfferCubit.storeKey], 'never');
          final years = build(now: _now.add(const Duration(days: 999)));
          await years.load();
          expect(years.state, hidden);
        },
      );
    }

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'counts an unreadable stored value as put away',
      setUp: () => store.values[OnDeviceAiOfferCubit.storeKey] = 'garbage',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [hidden],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'does not nag when the preferences fail, and hides on a tap anyway',
      build: () => build(on: _ThrowingStore()),
      act: (cubit) async {
        await cubit.load();
        await cubit.never();
      },
      expect: () => const [hidden],
      errors: () => [isA<StateError>(), isA<StateError>()],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'decides with what it has when the models could not be read',
      setUp: () => models = _UnreadyModels(testCatalog),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<OnDeviceAiOfferState>().having(
          (state) => state.shown,
          'shown',
          isTrue,
        ),
      ],
      errors: () => [isA<FileSystemException>()],
    );

    blocTest<OnDeviceAiOfferCubit, OnDeviceAiOfferState>(
      'emits nothing once closed',
      build: build,
      act: (cubit) async {
        final loading = cubit.load();
        await cubit.close();
        await loading;
        await cubit.notNow();
      },
      expect: () => const <OnDeviceAiOfferState>[],
    );
  });
}
