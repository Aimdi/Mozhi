import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/data/transcript_history.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _FakeHistoryEntry extends Fake implements HistoryEntry;

TranscriptEntry _phrase(
  int id,
  String text, {
  String? translation,
  PhraseStatus status = PhraseStatus.transcribed,
}) => TranscriptEntry(
  id: id,
  start: Duration(seconds: id),
  end: Duration(seconds: id + 1),
  text: text,
  status: status,
  translation: translation ?? '',
  translationStatus: translation == null
      ? null
      : TranscriptTranslationStatus.done,
);

final _template = HistoryEntry(
  id: '42',
  text: 'unused',
  translation: 'unused',
  source: const Language(code: 'en', name: 'English'),
  target: const Language(code: 'de', name: 'German'),
  engineId: 'offline',
  engineName: 'Whisper',
  createdAt: DateTime.utc(2026, 10, 30, 9),
  detectedSource: 'en',
  isFavorite: true,
);

void main() {
  group('TranscriptHistory.parts', () {
    test('a transcript that fits is one part, as before', () {
      final entries = [
        _phrase(1, 'One.', translation: 'Eins.'),
        _phrase(2, '', status: PhraseStatus.skipped),
        _phrase(3, 'Two.'),
      ];
      expect(TranscriptHistory.parts(entries), [
        (
          text: TranscriptExport.plain(entries),
          translation: TranscriptExport.plainTranslation(entries),
        ),
      ]);
      expect(TranscriptHistory.parts(const []), [(text: '', translation: '')]);
    });

    test('a long one is split between phrases into numbered parts', () {
      final entries = [
        for (var i = 0; i < 30; i++)
          _phrase(i, 'Phrase $i ${'x' * 20}.', translation: 'Satz $i.'),
      ];
      final parts = TranscriptHistory.parts(entries, maxLength: 100);
      expect(parts.length, greaterThan(1));
      for (final (index, part) in parts.indexed) {
        final number = '(${index + 1}/${parts.length}) ';
        expect(part.text, startsWith(number));
        expect(part.translation, startsWith(number));
        expect(part.text.length, lessThanOrEqualTo(100));
        expect(part.translation.length, lessThanOrEqualTo(100));
      }
      // Nothing is lost, nothing is cut.
      String strip(String value) =>
          value.replaceFirst(RegExp(r'^\(\d+/\d+\) '), '');
      expect(
        parts.map((part) => strip(part.text)).join('\n\n'),
        TranscriptExport.plain(entries),
      );
      expect(
        parts.map((part) => strip(part.translation)).join('\n\n'),
        TranscriptExport.plainTranslation(entries),
      );
    });

    test('a long translation alone splits it too', () {
      final entries = [
        for (var i = 0; i < 6; i++) _phrase(i, 'Hi', translation: 'y' * 40),
      ];
      final parts = TranscriptHistory.parts(entries, maxLength: 100);
      expect(parts, hasLength(3));
      expect(parts.first.text, '(1/3) Hi\n\nHi');
    });

    test('untranslated parts keep an empty translation', () {
      final entries = [for (var i = 0; i < 6; i++) _phrase(i, 'z' * 40)];
      final parts = TranscriptHistory.parts(entries, maxLength: 100);
      expect(parts.map((part) => part.translation), everyElement(isEmpty));
    });

    test('a phrase longer than a part is split at spaces', () {
      final words = List.generate(60, (i) => 'word$i').join(' ');
      final parts = TranscriptHistory.parts([
        _phrase(1, words, translation: 'short'),
      ], maxLength: 100);
      expect(parts.length, greaterThan(3));
      for (final part in parts) {
        expect(part.text.length, lessThanOrEqualTo(100));
        expect(part.text, isNot(endsWith(' ')));
      }
      expect(parts.first.translation, endsWith(' short'));
      // Parts past the translation's end have none.
      expect(parts.last.translation, matches(RegExp(r'^\(\d+/\d+\) $')));
      final joined = parts
          .map((part) => part.text.replaceFirst(RegExp(r'^\(\d+/\d+\) '), ''))
          .join(' ');
      expect(joined, words);
    });

    test('a phrase without spaces is cut, not within a surrogate pair', () {
      // 88 is the room per part; the emoji's first half is the 88th unit.
      final text = '${'a' * 87}\u{1F600}${'b' * 100}';
      final parts = TranscriptHistory.parts([_phrase(1, text)], maxLength: 100);
      expect(parts.first.text, '(1/3) ${'a' * 87}');
      expect(parts[1].text, startsWith('(2/3) \u{1F600}'));
      expect(parts.last.text, startsWith('(3/3) b'));
    });

    test("the default is History's limit", () {
      final entries = [for (var i = 0; i < 3; i++) _phrase(i, 'w' * 9000)];
      final parts = TranscriptHistory.parts(entries);
      expect(parts, hasLength(2));
      expect(
        parts.map((part) => part.text.length),
        everyElement(lessThanOrEqualTo(HistoryRepository.defaultMaxTextLength)),
      );
      expect(HistoryRepository().maxTextLength, 20000);
    });
  });

  group('TranscriptHistory.save', () {
    late MockHistoryCubit history;

    setUpAll(() => registerFallbackValue(_FakeHistoryEntry()));

    setUp(() {
      history = MockHistoryCubit();
      when(() => history.add(any())).thenAnswer((_) async {});
      when(() => history.delete(any())).thenAnswer((_) async {});
    });

    List<HistoryEntry> added() =>
        verify(() => history.add(captureAny())).captured.cast<HistoryEntry>();

    test("one entry with the template's id and details", () async {
      final count = await TranscriptHistory.save(history, _template, [
        _phrase(1, 'One.', translation: 'Eins.'),
      ]);
      expect(count, 1);
      final entry = added().single;
      expect(entry.id, '42');
      expect(entry.text, 'One.');
      expect(entry.translation, 'Eins.');
      expect(entry.source, _template.source);
      expect(entry.target, _template.target);
      expect(entry.engineId, 'offline');
      expect(entry.engineName, 'Whisper');
      expect(entry.createdAt, _template.createdAt);
      expect(entry.detectedSource, 'en');
      expect(entry.isFavorite, isTrue);
      verifyNever(() => history.delete(any()));
    });

    test('parts are added last first, so part 1 is on top', () async {
      final entries = [for (var i = 0; i < 6; i++) _phrase(i, 'z' * 40)];
      final count = await TranscriptHistory.save(
        history,
        _template,
        entries,
        maxLength: 100,
      );
      expect(count, 3);
      final saved = added();
      expect(saved.map((entry) => entry.id), ['42.3', '42.2', '42']);
      expect(saved.last.text, startsWith('(1/3) '));
      expect(saved.first.text, startsWith('(3/3) '));
      expect(saved.last.createdAt.isAfter(saved.first.createdAt), isTrue);
    });

    test('parts no longer needed are deleted', () async {
      final count = await TranscriptHistory.save(
        history,
        _template,
        [_phrase(1, 'Short now.')],
        savedParts: 3,
        maxLength: 100,
      );
      expect(count, 1);
      verify(() => history.delete('42.2')).called(1);
      verify(() => history.delete('42.3')).called(1);
      verifyNever(() => history.delete('42'));
    });

    test('partId keeps the first id', () {
      expect(TranscriptHistory.partId('7', 0), '7');
      expect(TranscriptHistory.partId('7', 1), '7.2');
    });
  });
}
