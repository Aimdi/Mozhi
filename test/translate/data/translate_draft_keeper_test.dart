import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/data/translate_draft_keeper.dart';

import '../cubit/translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  late MemoryStore store;
  late HistoryRepository repository;
  late TranslateCubit translate;
  late TranslateDraftKeeper keeper;

  void historyState({bool incognito = false, bool saveHistory = true}) => when(
    () => mocks.history.state,
  ).thenReturn(HistoryState(incognito: incognito, saveHistory: saveHistory));

  setUp(() {
    mocks = TranslateMocks();
    store = MemoryStore();
    repository = HistoryRepository(store: store, keyStore: MemoryStore());
    translate = mocks.build()..emit(readyState());
    keeper = TranslateDraftKeeper(
      translate: translate,
      history: mocks.history,
      store: repository,
    )..start();
    addTearDown(() async {
      keeper.dispose();
      await translate.close();
    });
  });

  bool stored() => store.values.containsKey(HistoryRepository.draftStorageKey);

  group('TranslateDraftKeeper', () {
    test('keeps the input and puts it back after the app was ended', () async {
      translate.setInput('Où est la gare ?');
      await keeper.save();
      expect(stored(), isTrue);

      // A cold start: a new translator with an empty input.
      final next = mocks.build()..emit(readyState());
      addTearDown(next.close);
      final restarted = TranslateDraftKeeper(
        translate: next,
        history: mocks.history,
        store: HistoryRepository(store: store, keyStore: repository.keyStore),
      )..start();
      addTearDown(restarted.dispose);
      await restarted.restore();

      expect(next.state.input, 'Où est la gare ?');
      // Not translated by itself.
      verifyNever(() => mocks.repository.translate(any(), any()));
      // The empty input of the start did not delete it.
      expect(stored(), isTrue);
    });

    test('clearing the input deletes the draft', () async {
      translate.setInput('Hallo');
      await keeper.save();
      translate.setInput('');
      await Future<void>.delayed(Duration.zero);
      expect(stored(), isFalse);
    });

    test('a blank input deletes it', () async {
      translate.setInput('Hallo');
      await keeper.save();
      translate.emit(translate.state.copyWith(input: ' '));
      await keeper.save();
      expect(stored(), isFalse);
    });

    for (final (name, incognito, save) in [
      ('incognito', true, true),
      ('"Save history" off', false, false),
    ]) {
      test('keeps nothing while $name, and deletes what was kept', () async {
        translate.setInput('Hallo');
        await keeper.save();
        historyState(incognito: incognito, saveHistory: save);

        await keeper.save();
        expect(stored(), isFalse);

        await repository.saveDraft('earlier');
        final next = mocks.build()..emit(readyState());
        addTearDown(next.close);
        await TranslateDraftKeeper(
          translate: next,
          history: mocks.history,
          store: repository,
        ).restore();
        expect(next.state.input, isEmpty);
        expect(stored(), isFalse);
      });
    }

    test('text from outside the app wins', () async {
      await repository.saveDraft('draft');
      translate.setExternalInput('shared');
      await keeper.restore();
      expect(translate.state.input, 'shared');
    });

    test('storage errors are ignored', () async {
      final broken = TranslateDraftKeeper(
        translate: translate,
        history: mocks.history,
        store: HistoryRepository(
          store: _BrokenStore(),
          keyStore: _BrokenStore(),
        ),
      );
      translate.setInput('Hallo');
      await expectLater(broken.save(), completes);
      await expectLater(broken.restore(), completes);
    });
  });

  group('TranslateCubit.restoreDraft', () {
    test('fills an empty input only', () {
      expect(translate.restoreDraft('Hallo'), isTrue);
      expect(translate.state.input, 'Hallo');
      expect(translate.restoreDraft('Other'), isFalse);
      expect(translate.state.input, 'Hallo');
    });

    test('ignores a blank draft and a closed translator', () async {
      expect(translate.restoreDraft('  '), isFalse);
      await translate.close();
      expect(translate.restoreDraft('Hallo'), isFalse);
    });
  });
}

class _BrokenStore implements KeyValueStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('broken'));

  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('broken'));

  @override
  Future<void> delete(String key) => Future.error(StateError('broken'));
}
