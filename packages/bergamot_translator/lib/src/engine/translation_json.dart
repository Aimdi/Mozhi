import 'dart:convert';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:translation_repository/translation_repository.dart';

/// Reads what `mozhi_bergamot_translate_ex` returns (see
/// `native/src/mozhi_bergamot.h`): a JSON array with one object per text.
///
/// Throws [BergamotEngineException] when it is not what the library
/// writes, or does not hold [count] results.
List<OfflineTranslation> parseBergamotTranslations(
  String json, {
  required int count,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (error) {
    throw BergamotEngineException('Invalid engine output: ${error.message}');
  }
  if (decoded is! List || decoded.length != count) {
    throw BergamotEngineException(
      'Engine output has ${decoded is List ? decoded.length : 'no'} '
      'results, expected $count',
    );
  }
  return [for (final result in decoded) _translation(result)];
}

OfflineTranslation _translation(Object? json) {
  if (json is! Map || json['text'] is! String) _invalid('result');
  final text = json['text'] as String;
  final sentences = json['sentences'];
  if (sentences == null) return OfflineTranslation(text: text);
  if (sentences is! List) _invalid('sentences');
  return OfflineTranslation(
    text: text,
    sentences: [for (final sentence in sentences) _sentence(sentence)],
  );
}

OfflineSentence _sentence(Object? json) {
  if (json is! Map) _invalid('sentence');
  final (sourceStart, sourceEnd) = _range(json['source'], 'source');
  final (targetStart, targetEnd) = _range(json['target'], 'target');
  final words = json['words'];
  if (words != null && words is! List) _invalid('words');
  return OfflineSentence(
    sourceStart: sourceStart,
    sourceEnd: sourceEnd,
    targetStart: targetStart,
    targetEnd: targetEnd,
    score: _number(json['score'], 'score'),
    words: [
      if (words is List)
        for (final word in words) _word(word),
    ],
  );
}

OfflineWord _word(Object? json) {
  if (json is! Map) _invalid('word');
  final (targetStart, targetEnd) = _range(json['target'], 'target');
  final source = json['source'];
  final (sourceStart, sourceEnd) = source == null
      ? (null, null)
      : _range(source, 'source');
  return OfflineWord(
    targetStart: targetStart,
    targetEnd: targetEnd,
    sourceStart: sourceStart,
    sourceEnd: sourceEnd,
    alignment: _number(json['p'], 'p'),
    score: _number(json['score'], 'score'),
  );
}

(int, int) _range(Object? json, String name) {
  if (json case [final int start, final int end]
      when start >= 0 && end >= start) {
    return (start, end);
  }
  _invalid(name);
}

double? _number(Object? json, String name) => switch (json) {
  null => null,
  final num value => value.toDouble(),
  _ => _invalid(name),
};

Never _invalid(String what) =>
    throw BergamotEngineException('Invalid engine output: bad $what');
