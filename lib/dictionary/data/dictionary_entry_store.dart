import 'dart:convert';

import 'package:translation_repository/translation_repository.dart';

/// Longest [encodeDictionaryEntry] output kept with a history entry
/// (`HistoryEntry.dictionaryJson`); a larger entry is not kept (opening it
/// looks the word up again).
const int maxStoredDictionaryEntryLength = 64 * 1024;

/// [entry] as JSON in the dictionary prompt's own format, which
/// [decodeDictionaryEntry] (`ResponseParsers.parseDictionary`) reads back.
/// Null when it is longer than [maxStoredDictionaryEntryLength].
String? encodeDictionaryEntry(DictionaryEntry entry) {
  final json = jsonEncode({
    'word': entry.word,
    if (entry.pronunciation.isNotEmpty) 'pronunciation': entry.pronunciation,
    if (entry.partsOfSpeech.isNotEmpty) 'parts_of_speech': entry.partsOfSpeech,
    'senses': [
      for (final sense in entry.senses)
        {
          'definition': sense.definition,
          if (sense.partOfSpeech.isNotEmpty)
            'part_of_speech': sense.partOfSpeech,
          if (sense.translations.isNotEmpty) 'translations': sense.translations,
          if (sense.usage.isNotEmpty) 'usage': sense.usage,
        },
    ],
    if (entry.examples.isNotEmpty)
      'examples': [
        for (final example in entry.examples)
          {
            'source': example.source,
            if (example.translation.isNotEmpty)
              'translation': example.translation,
          },
      ],
    if (entry.synonyms.isNotEmpty) 'synonyms': entry.synonyms,
    if (entry.etymology.isNotEmpty) 'etymology': entry.etymology,
    if (entry.notes.isNotEmpty) 'notes': entry.notes,
    if (entry.relatedWords.isNotEmpty) 'related_words': entry.relatedWords,
    if (entry.didYouMean case final didYouMean? when didYouMean.isNotEmpty)
      'did_you_mean': didYouMean,
  });
  return json.length > maxStoredDictionaryEntryLength ? null : json;
}

/// The entry [json] ([encodeDictionaryEntry]) holds; null for null, blank
/// or unreadable JSON and for an entry without a word or senses.
DictionaryEntry? decodeDictionaryEntry(String? json) {
  if (json == null || json.trim().isEmpty) return null;
  try {
    final entry = ResponseParsers.parseDictionary(json);
    if (entry.word.trim().isEmpty && entry.senses.isEmpty) return null;
    return entry;
  } on Object {
    return null;
  }
}

/// The first translation of [entry] into the target language (trimmed),
/// or null when its senses have none.
String? firstDictionaryTranslation(DictionaryEntry entry) {
  for (final sense in entry.senses) {
    for (final value in sense.translations) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
  }
  return null;
}

/// The latest AI dictionary entries, in memory only (never stored), so
/// that looking a word up again (or opening it from another screen, see
/// the word look-up) does not ask the AI again: one store per
/// [TranslationRepository] ([DictionaryEntryCache.of]), keyed by the
/// word, its languages, the detail level, the engine and the context
/// sentence. The least recently used entries make room for new ones
/// beyond [capacity].
class DictionaryEntryCache {
  new({this.capacity = 64});

  /// The store of [repository]'s look-ups.
  factory of(TranslationRepository repository) =>
      _stores[repository] ??= DictionaryEntryCache();

  static final _stores = Expando<DictionaryEntryCache>('dictionary cache');

  /// Most entries kept.
  final int capacity;

  /// In use order (insertion-ordered: the least recently used first).
  final _entries = <String, DictionaryEntry>{};

  /// Number of entries kept.
  int get length => _entries.length;

  static final _spaces = RegExp(r'\s+');

  static String _key(
    String word, {
    required Language source,
    required Language target,
    required DictionaryVerbosity verbosity,
    required String engineId,
    String context = '',
  }) => [
    word.trim().replaceAll(_spaces, ' '),
    source.code,
    target.code,
    verbosity.name,
    engineId,
    context.trim(),
  ].join('\u001f');

  /// The entry kept for this look-up (now the most recently used), or null.
  DictionaryEntry? get(
    String word, {
    required Language source,
    required Language target,
    required DictionaryVerbosity verbosity,
    required String engineId,
    String context = '',
  }) {
    final key = _key(
      word,
      source: source,
      target: target,
      verbosity: verbosity,
      engineId: engineId,
      context: context,
    );
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  /// Keeps [entry] for this look-up.
  void put(
    String word,
    DictionaryEntry entry, {
    required Language source,
    required Language target,
    required DictionaryVerbosity verbosity,
    required String engineId,
    String context = '',
  }) {
    final key = _key(
      word,
      source: source,
      target: target,
      verbosity: verbosity,
      engineId: engineId,
      context: context,
    );
    _entries
      ..remove(key)
      ..[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Forgets every entry.
  void clear() => _entries.clear();
}
