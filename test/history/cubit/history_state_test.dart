import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/cubit/history_state.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

HistoryEntry _entry(
  String id, {
  required String text,
  required String translation,
  Language source = const Language(code: 'en', name: 'English'),
  Language target = const Language(code: 'fr', name: 'French'),
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: text,
  translation: translation,
  source: source,
  target: target,
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026),
  isFavorite: isFavorite,
);

final HistoryEntry _hello = _entry('1', text: 'Hello', translation: 'Bonjour');
final HistoryEntry _cat = _entry(
  '2',
  text: 'The cat',
  translation: 'Die Katze',
  target: const Language(code: 'de', name: 'German', nativeName: 'Deutsch'),
  isFavorite: true,
);
final HistoryEntry _thanks = _entry(
  '3',
  text: 'Gracias',
  translation: 'Thanks',
  source: const Language(code: 'es', name: 'Spanish', nativeName: 'Español'),
  target: const Language(code: 'en', name: 'English'),
);

void main() {
  group(HistoryState, () {
    final entries = [_hello, _cat, _thanks];

    test('has sensible defaults', () {
      const state = HistoryState();

      expect(state.status, HistoryStatus.initial);
      expect(state.entries, isEmpty);
      expect(state.query, isEmpty);
      expect(state.favoritesOnly, isFalse);
      expect(state.incognito, isFalse);
      expect(state.visible, isEmpty);
    });

    test('supports value equality and copyWith', () {
      expect(const HistoryState(), equals(const HistoryState()));
      expect(
        const HistoryState().copyWith(
          status: HistoryStatus.ready,
          entries: entries,
          query: 'q',
          favoritesOnly: true,
          incognito: true,
        ),
        equals(
          HistoryState(
            status: HistoryStatus.ready,
            entries: entries,
            query: 'q',
            favoritesOnly: true,
            incognito: true,
          ),
        ),
      );
      expect(const HistoryState(incognito: true), isNot(const HistoryState()));
    });

    test('expiredCount counts the non-favourites older than maxAge', () {
      // All entries were created at the start of 2026; _cat is a favourite.
      final state = HistoryState(entries: entries);
      final now = DateTime(2026, 1, 8);

      expect(state.expiredCount(const Duration(days: 30), now: now), 0);
      expect(state.expiredCount(const Duration(days: 7), now: now), 0);
      expect(state.expiredCount(const Duration(days: 6), now: now), 2);
      expect(state.expiredCount(Duration.zero, now: now), 2);
      expect(const HistoryState().expiredCount(Duration.zero, now: now), 0);
    });

    group('visible', () {
      test('returns all entries without filters', () {
        expect(HistoryState(entries: entries).visible, entries);
      });

      test('filters favourites', () {
        expect(HistoryState(entries: entries, favoritesOnly: true).visible, [
          _cat,
        ]);
      });

      test('searches the text case-insensitively', () {
        expect(HistoryState(entries: entries, query: 'HELLO').visible, [
          _hello,
        ]);
      });

      test('searches the translation', () {
        expect(HistoryState(entries: entries, query: 'katze').visible, [_cat]);
      });

      test('searches language names', () {
        expect(HistoryState(entries: entries, query: 'french').visible, [
          _hello,
        ]);
        expect(HistoryState(entries: entries, query: 'german').visible, [_cat]);
        expect(HistoryState(entries: entries, query: 'spanish').visible, [
          _thanks,
        ]);
        expect(HistoryState(entries: entries, query: 'english').visible, [
          _hello,
          _cat,
          _thanks,
        ]);
      });

      test('searches native language names', () {
        expect(HistoryState(entries: entries, query: 'deutsch').visible, [
          _cat,
        ]);
        expect(HistoryState(entries: entries, query: 'español').visible, [
          _thanks,
        ]);
      });

      test('ignores surrounding whitespace in the query', () {
        expect(HistoryState(entries: entries, query: '  cat ').visible, [_cat]);
        expect(HistoryState(entries: entries, query: '   ').visible, entries);
      });

      test('combines the query with the favourites filter', () {
        expect(
          HistoryState(
            entries: entries,
            query: 'hello',
            favoritesOnly: true,
          ).visible,
          isEmpty,
        );
        expect(
          HistoryState(
            entries: entries,
            query: 'cat',
            favoritesOnly: true,
          ).visible,
          [_cat],
        );
      });
    });

    group('dictionary look-ups', () {
      const spanish = Language(code: 'es', name: 'Spanish');
      const english = Language(code: 'en', name: 'English');
      final gato = HistoryEntry(
        id: 'dictionary:1',
        kind: HistoryEntryKind.dictionary,
        text: 'gato',
        translation: 'noun · A small domesticated feline.',
        source: spanish,
        target: english,
        engineId: 'ai:ollama',
        engineName: 'Ollama',
        createdAt: DateTime(2026),
        isFavorite: true,
      );
      final state = HistoryState(entries: [_hello, gato, _thanks]);

      test('lookUpOf finds the look-up of a word and its languages', () {
        expect(
          state.lookUpOf(' gato ', source: spanish, target: english),
          gato,
        );
        expect(
          state.lookUpOf('perro', source: spanish, target: english),
          isNull,
        );
        // A translation of the same text is not a look-up.
        expect(
          state.lookUpOf('Gracias', source: spanish, target: english),
          isNull,
        );
      });

      test('hasLookUps tells whether there are any', () {
        expect(state.hasLookUps, isTrue);
        expect(HistoryState(entries: entries).hasLookUps, isFalse);
      });

      test('search the word and the summary', () {
        expect(state.copyWith(query: 'GATO').visible, [gato]);
        expect(state.copyWith(query: 'feline').visible, [gato]);
      });

      test('count in the pairs and the favourites', () {
        expect(state.pairs, contains((HistoryPair.of(gato), 2)));
        expect(state.copyWith(favoritesOnly: true).visible, [gato]);
        expect(state.copyWith(pair: () => HistoryPair.of(gato)).visible, [
          gato,
          _thanks,
        ]);
      });

      test('go to the destination of their AI engine', () {
        const local = AiProviderConfig(
          id: 'ollama',
          name: 'Ollama',
          provider: LlmProvider.ollama,
          baseUrl: 'http://localhost:11434',
          model: 'llama3',
        );
        HistoryDestination? destinationOf(String engineId) =>
            historyDestinationOf(engineId, providers: const [local]);

        expect(destinationOf(gato.engineId), HistoryDestination.selfHosted);
        expect(
          state
              .copyWith(destination: () => HistoryDestination.selfHosted)
              .visibleWith(destinationOf),
          [gato],
        );
        // A provider that no longer exists counts as the cloud.
        expect(historyDestinationOf(gato.engineId), HistoryDestination.cloud);
      });
    });
  });
}
