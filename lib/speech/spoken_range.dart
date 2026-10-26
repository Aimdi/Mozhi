import 'package:equatable/equatable.dart';

/// The part of a text being read aloud: [start] to [end] (UTF-16 offsets,
/// end exclusive) into the text given to `SpeechService.speak` or
/// `SpeechService.toggle` (see `SpeechService.spokenRanges`).
class SpokenRange extends Equatable {
  const new(this.start, this.end);

  final int start;
  final int end;

  /// Whether the range is empty.
  bool get isEmpty => end <= start;

  /// This range moved [offset] code units on.
  SpokenRange shift(int offset) => SpokenRange(start + offset, end + offset);

  @override
  List<Object?> get props => [start, end];

  @override
  String toString() => 'SpokenRange($start, $end)';
}

/// A speech engine that tells which part of the current utterance it is
/// reading (`flutter_tts`'s progress handler: Android's `onRangeStart`,
/// the web's `boundary` events). Engines without it (audio files, most
/// online voices) never report a range.
abstract interface class DeviceTtsProgress {
  /// The range of the text given to the latest `speak` being read now
  /// (offsets into that text), cleaned with [cleanSpokenRange].
  Stream<SpokenRange> get onProgress;
}

/// White space and punctuation: a spoken word does not run across them,
/// but for the apostrophes and hyphens inside words ([_joiners]).
final _wordEnd = RegExp(r'[\s\p{P}]', unicode: true);

/// Apostrophes and hyphens, which join the parts of a word.
const _joiners = {"'", '’', 'ʼ', '-', '‐', '‑'};

/// The word an engine reports from [start] to [end] in [text] (the text of
/// its utterance) as a [SpokenRange], or null when there is nothing to
/// highlight:
///
/// * the offsets are clamped to [text], and a range without a letter,
///   digit or symbol is dropped;
/// * the range ends at the first space or punctuation after its first
///   character: the web plugin runs a word on to the next ASCII space or
///   punctuation, which in Chinese or Thai can be a whole clause;
/// * a range over the whole of a text of several words is dropped:
///   Android before 8.0 reports only that, as the utterance starts.
SpokenRange? cleanSpokenRange(String text, int start, int end) {
  final from = start.clamp(0, text.length);
  var to = end.clamp(from, text.length);
  if (to <= from) return null;
  if (from == 0 && to == text.length && text.trim().contains(_spaces)) {
    return null;
  }
  for (final cut in _wordEnd.allMatches(text, from + 1)) {
    if (cut.start >= to) break;
    if (_joiners.contains(cut[0])) continue;
    to = cut.start;
    break;
  }
  // Never split a surrogate pair.
  if (to < text.length && _isLowSurrogate(text.codeUnitAt(to))) to++;
  if (!_pronounceable.hasMatch(text.substring(from, to))) return null;
  return SpokenRange(from, to);
}

final _spaces = RegExp(r'\s');

final _pronounceable = RegExp(r'[\p{L}\p{N}\p{S}]', unicode: true);

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
