import 'package:flutter/widgets.dart' show StringCharacters;

/// Longest chunk [splitTextForSpeech] produces by default, in UTF-16 code
/// units.
///
/// Mozhi's `/api/tts` is GET-only and carries the text in the query string;
/// its server rejects request lines over about 4 KiB (431, which dart:io
/// usually reports as a reset connection). Google's own TTS endpoint reads
/// only about 200 characters per request anyway. 200 code units are at most
/// 600 UTF-8 bytes, so 1800 bytes once URL-encoded.
const maxSpeechChunkLength = 200;

/// How strongly a break position separates the text around it.
enum _Level { word, clause, sentence }

/// Splits [text] into trimmed chunks of at most [maxLength] UTF-16 code
/// units, for text-to-speech engines that only read short texts.
///
/// Text that fits is returned as a single chunk. Otherwise each chunk ends at
/// the last break within [maxLength], preferring in this order:
/// 1. a sentence end: a line break, `.` `!` `?` `…` followed by whitespace,
///    or a full stop that needs no space (`。` `！` `？` `।` `။` `។` `؟` …);
/// 2. a clause end: `,` `;` `:` followed by whitespace, or `、` `，` `；`
///    `：` `،` `—` …;
/// 3. whitespace (not no-break spaces) or a zero-width space;
/// 4. any grapheme cluster boundary, so text without spaces (Chinese,
///    Japanese, Thai) is cut by length without separating combining marks
///    or emoji sequences.
///
/// Closing quotes and brackets stay with the punctuation they follow. A
/// single grapheme cluster longer than [maxLength] becomes a chunk of its
/// own. Chunks with nothing to pronounce (only punctuation) are dropped
/// unless nothing else is left. Blank [text] gives no chunks.
List<String> splitTextForSpeech(
  String text, {
  int maxLength = maxSpeechChunkLength,
}) {
  if (maxLength < 1) {
    throw ArgumentError.value(maxLength, 'maxLength', 'Must be positive');
  }
  final chunks = <String>[];
  var rest = text.trim();
  while (rest.length > maxLength) {
    final end = _chunkEnd(rest, maxLength);
    chunks.add(rest.substring(0, end).trimRight());
    rest = rest.substring(end).trimLeft();
  }
  if (rest.isNotEmpty) chunks.add(rest);
  final spoken = [
    for (final chunk in chunks)
      if (_pronounceable.hasMatch(chunk)) chunk,
  ];
  return spoken.isEmpty ? chunks : spoken;
}

/// Where the first chunk of [text] (trimmed, longer than [maxLength]) ends.
int _chunkEnd(String text, int maxLength) {
  // Last break of each level within maxLength (0 = none).
  final breaks = List.filled(_Level.values.length, 0);
  var lastCluster = 0;
  var offset = 0;
  // What the current word ends with, for a break at the next whitespace.
  var trailing = _Level.word;
  // Break right after punctuation that needs no space; closing quotes and
  // brackets that follow it move it along.
  _Level? attachedLevel;
  var attachedEnd = 0;

  for (final cluster in text.characters) {
    final start = offset;
    final end = offset = start + cluster.length;
    if (_isSpace(cluster)) {
      // Break before the whitespace; trimming drops it.
      final level = _isLineBreak(cluster) ? _Level.sentence : trailing;
      breaks[level.index] = start;
      trailing = _Level.word;
      attachedLevel = null;
      if (end > maxLength) break;
      continue;
    }
    if (end > maxLength) break;
    lastCluster = end;
    if (_closers.contains(cluster)) {
      if (attachedLevel != null && attachedEnd == start) {
        breaks[attachedLevel.index] = attachedEnd = end;
      }
      continue;
    }
    attachedLevel = _breaksAfter[cluster];
    if (attachedLevel != null) {
      breaks[attachedLevel.index] = attachedEnd = end;
    }
    trailing = _breaksBeforeSpace[cluster] ?? attachedLevel ?? _Level.word;
  }

  for (final level in _Level.values.reversed) {
    if (breaks[level.index] > 0) return breaks[level.index];
  }
  // A cluster longer than maxLength is kept whole.
  return lastCluster > 0 ? lastCluster : text.characters.first.length;
}

bool _isSpace(String cluster) =>
    cluster == '​' ||
    (cluster.trim().isEmpty && !_noBreakSpaces.contains(cluster));

bool _isLineBreak(String cluster) => _lineBreak.hasMatch(cluster);

final _lineBreak = RegExp('[\n\r\u000B\u000C\u0085  ]');

/// Something an engine reads out: a letter, digit or symbol (emoji).
final _pronounceable = RegExp(r'[\p{L}\p{N}\p{S}]', unicode: true);

/// Whitespace that must not be broken at.
const _noBreakSpaces = {' ', ' ', ' ', '﻿'};

/// Punctuation that ends a sentence or clause only when whitespace follows
/// (`3.14`, `1,000`, `e.g.x`, `10:30` are not breaks).
const Map<String, _Level> _breaksBeforeSpace = {
  '.': _Level.sentence,
  '!': _Level.sentence,
  '?': _Level.sentence,
  '…': _Level.sentence,
  ';': _Level.sentence, // Greek question mark.
  ',': _Level.clause,
  ';': _Level.clause,
  ':': _Level.clause,
  '–': _Level.clause,
};

/// Punctuation that ends a sentence, clause or word right after it, as used
/// by scripts written without spaces (or never inside a word).
const Map<String, _Level> _breaksAfter = {
  // CJK full stops, question and exclamation marks.
  '。': _Level.sentence,
  '｡': _Level.sentence,
  '．': _Level.sentence,
  '！': _Level.sentence,
  '？': _Level.sentence,
  '︒': _Level.sentence,
  '﹒': _Level.sentence,
  '﹖': _Level.sentence,
  '﹗': _Level.sentence,
  '‼': _Level.sentence,
  '⁇': _Level.sentence,
  '⁈': _Level.sentence,
  '⁉': _Level.sentence,
  '؟': _Level.sentence, // Arabic question mark.
  '۔': _Level.sentence, // Urdu full stop.
  '։': _Level.sentence, // Armenian full stop.
  '।': _Level.sentence, // Devanagari danda.
  '॥': _Level.sentence,
  '።': _Level.sentence, // Ethiopic full stop.
  '፧': _Level.sentence,
  '။': _Level.sentence, // Myanmar section mark.
  '។': _Level.sentence, // Khmer khan.
  '៕': _Level.sentence,
  '།': _Level.sentence, // Tibetan shad.
  '๚': _Level.sentence, // Thai angkhankhu.
  '๛': _Level.sentence,
  // Commas, semicolons, colons and dashes.
  '、': _Level.clause,
  '､': _Level.clause,
  '，': _Level.clause,
  '；': _Level.clause,
  '：': _Level.clause,
  '﹐': _Level.clause,
  '﹑': _Level.clause,
  '﹔': _Level.clause,
  '﹕': _Level.clause,
  '،': _Level.clause, // Arabic comma.
  '؛': _Level.clause,
  '፣': _Level.clause, // Ethiopic comma.
  '፤': _Level.clause,
  '၊': _Level.clause, // Myanmar little section.
  '—': _Level.clause,
  // Tibetan tsheg separates syllables.
  '་': _Level.word,
};

/// Closing quotes and brackets, kept with the punctuation before them.
const _closers = {
  '"',
  "'",
  ')',
  ']',
  '}',
  '»',
  '›',
  '’',
  '”',
  '」',
  '』',
  '）',
  '］',
  '｝',
  '〕',
  '〉',
  '》',
  '】',
  '〗',
  '〙',
  '〛',
  '＂',
  '＇',
  '｣',
};
