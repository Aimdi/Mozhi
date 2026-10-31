import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';

/// One History entry's worth of a transcript: its text and translation.
typedef TranscriptPart = ({String text, String translation});

/// Saves a transcript (Transcribe, live captions) to History.
///
/// History keeps at most [HistoryRepository.maxTextLength] characters of
/// an entry's text and of its translation (20,000), so a longer transcript
/// is saved as numbered parts instead of being cut: "(1/3) …", "(2/3) …",
/// split between phrases (a phrase longer than a part on its own is split
/// at a space). A transcript that fits is one entry, without a number.
abstract final class TranscriptHistory {
  /// Room kept for the part number, `(9999/9999) `.
  static const _numberRoom = 12;

  /// The parts of [entries] (the phrases with text, as
  /// [TranscriptExport.plain] and [TranscriptExport.plainTranslation] join
  /// them), each text and translation at most [maxLength] characters.
  static List<TranscriptPart> parts(
    List<TranscriptEntry> entries, {
    int maxLength = HistoryRepository.defaultMaxTextLength,
  }) {
    assert(maxLength > _numberRoom * 2, 'maxLength is too small');
    final text = TranscriptExport.plain(entries);
    final translation = TranscriptExport.plainTranslation(entries);
    if (text.length <= maxLength && translation.length <= maxLength) {
      return [(text: text, translation: translation)];
    }
    final budget = maxLength - _numberRoom;
    final groups = <_Group>[];
    var current = _Group();
    for (final entry in entries) {
      if (!entry.hasText) continue;
      final translated = entry.isTranslated ? entry.translation : null;
      for (final (words, translationWords) in _pieces(
        entry.text,
        translated,
        budget,
      )) {
        if (!current.fits(words, translationWords, budget)) {
          groups.add(current);
          current = _Group();
        }
        current.add(words, translationWords);
      }
    }
    if (!current.isEmpty) groups.add(current);
    final total = groups.length;
    return [
      for (final (index, group) in groups.indexed)
        (
          text: '(${index + 1}/$total) ${group.texts.join('\n\n')}',
          translation: group.translations.isEmpty
              ? ''
              : '(${index + 1}/$total) ${group.translations.join('\n\n')}',
        ),
    ];
  }

  /// The id of part [index] (from 0) of a transcript saved as [id]: the
  /// first part keeps [id].
  static String partId(String id, int index) =>
      index == 0 ? id : '$id.${index + 1}';

  /// Saves the transcript [entries] as [template] (its id, languages,
  /// engine, time, favourite), in [parts] when it is too long: part 1
  /// first in the list, the others with the ids of [partId]. Parts of an
  /// earlier save of the same transcript ([savedParts] of them) that are
  /// no longer needed are deleted. Returns how many parts were saved.
  static Future<int> save(
    HistoryCubit history,
    HistoryEntry template,
    List<TranscriptEntry> entries, {
    int savedParts = 0,
    int maxLength = HistoryRepository.defaultMaxTextLength,
  }) async {
    final split = parts(entries, maxLength: maxLength);
    // History lists the newest first: the last part goes in first.
    for (var index = split.length - 1; index >= 0; index--) {
      final part = split[index];
      await history.add(
        HistoryEntry(
          id: partId(template.id, index),
          text: part.text,
          translation: part.translation,
          source: template.source,
          target: template.target,
          engineId: template.engineId,
          engineName: template.engineName,
          // A microsecond apart, part 1 the newest: in the list's order.
          createdAt: template.createdAt.subtract(Duration(microseconds: index)),
          detectedSource: template.detectedSource,
          isFavorite: template.isFavorite,
        ),
      );
    }
    for (var index = split.length; index < savedParts; index++) {
      await history.delete(partId(template.id, index));
    }
    return split.length;
  }

  /// [text] and its [translation] in pieces of at most [budget]
  /// characters each (one piece when both fit).
  static List<(String, String?)> _pieces(
    String text,
    String? translation,
    int budget,
  ) {
    if (text.length <= budget && (translation?.length ?? 0) <= budget) {
      return [(text, translation)];
    }
    final texts = _chunks(text, budget);
    final translations = translation == null
        ? const <String>[]
        : _chunks(translation, budget);
    final count = texts.length > translations.length
        ? texts.length
        : translations.length;
    return [
      for (var i = 0; i < count; i++)
        (
          i < texts.length ? texts[i] : '',
          translation == null
              ? null
              : i < translations.length
              ? translations[i]
              : '',
        ),
    ];
  }

  /// [value] cut into pieces of at most [budget] characters, at a space
  /// in the second half of a piece when there is one, never within a
  /// surrogate pair.
  static List<String> _chunks(String value, int budget) {
    final chunks = <String>[];
    var rest = value;
    while (rest.length > budget) {
      var cut = rest.lastIndexOf(' ', budget);
      if (cut < budget ~/ 2) {
        cut = budget;
        if (_isHighSurrogate(rest.codeUnitAt(cut - 1))) cut--;
      }
      chunks.add(rest.substring(0, cut).trimRight());
      rest = rest.substring(cut).trimLeft();
    }
    if (rest.isNotEmpty || chunks.isEmpty) chunks.add(rest);
    return chunks;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
}

/// The phrases of one part.
final class _Group {
  final texts = <String>[];
  final translations = <String>[];
  int _textLength = 0;
  int _translationLength = 0;

  bool get isEmpty => texts.isEmpty;

  bool fits(String text, String? translation, int budget) {
    if (isEmpty) return true;
    if (_textLength + 2 + text.length > budget) return false;
    if (translation == null) return true;
    final separator = translations.isEmpty ? 0 : 2;
    return _translationLength + separator + translation.length <= budget;
  }

  void add(String text, String? translation) {
    _textLength += (texts.isEmpty ? 0 : 2) + text.length;
    texts.add(text);
    if (translation == null) return;
    _translationLength += (translations.isEmpty ? 0 : 2) + translation.length;
    translations.add(translation);
  }
}
