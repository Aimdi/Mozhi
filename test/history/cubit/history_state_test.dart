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
        ),
        equals(
          HistoryState(
            status: HistoryStatus.ready,
            entries: entries,
            query: 'q',
            favoritesOnly: true,
          ),
        ),
      );
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
  });
}
