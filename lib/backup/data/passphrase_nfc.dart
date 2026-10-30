import 'package:mozhi/backup/data/nfc_table.dart';

/// [text] in Unicode Normalization Form C (composed), for backup and sync
/// passphrases: "é" typed as one character and "e" followed by a combining
/// acute accent give the same key.
///
/// Covers what a passphrase realistically holds (tool/passphrase_nfc.py
/// generates the tables): Latin (with Vietnamese's stacked diacritics),
/// Greek, Cyrillic, kana voicing marks and Hangul syllables. Characters of
/// other scripts are left as they are (for them this is not NFC).
String passphraseNfc(String text) {
  // Nothing to do for ASCII (almost every passphrase).
  if (text.codeUnits.every((unit) => unit < 0x80)) return text;
  final decomposed = <int>[];
  for (final rune in text.runes) {
    _decompose(rune, decomposed);
  }
  _reorder(decomposed);
  return String.fromCharCodes(_compose(decomposed));
}

const _hangulBase = 0xAC00;
const _hangulCount = 11172;
const _leadBase = 0x1100;
const _leadCount = 19;
const _vowelBase = 0x1161;
const _vowelCount = 21;
const _trailBase = 0x11A7;
const _trailCount = 28;

int _combiningClass(int rune) => nfcCombiningClasses[rune] ?? 0;

/// Appends the full canonical decomposition of [rune] to [out].
void _decompose(int rune, List<int> out) {
  final syllable = rune - _hangulBase;
  if (syllable >= 0 && syllable < _hangulCount) {
    out
      ..add(_leadBase + syllable ~/ (_vowelCount * _trailCount))
      ..add(
        _vowelBase + (syllable % (_vowelCount * _trailCount)) ~/ _trailCount,
      );
    final trail = syllable % _trailCount;
    if (trail != 0) out.add(_trailBase + trail);
    return;
  }
  final parts = nfcDecompositions[rune];
  if (parts == null) {
    out.add(rune);
    return;
  }
  for (final part in parts) {
    _decompose(part, out);
  }
}

/// Canonical ordering: each run of marks sorted (stably) by combining
/// class.
void _reorder(List<int> runes) {
  for (var i = 1; i < runes.length; i++) {
    final rune = runes[i];
    final value = _combiningClass(rune);
    if (value == 0) continue;
    var j = i;
    while (j > 0 && _combiningClass(runes[j - 1]) > value) {
      runes[j] = runes[j - 1];
      j--;
    }
    runes[j] = rune;
  }
}

/// Canonical composition of decomposed, reordered [runes].
List<int> _compose(List<int> runes) {
  final out = <int>[];
  var starter = -1;
  var lastClass = 0;
  for (final rune in runes) {
    final value = _combiningClass(rune);
    // Not blocked: right after the starter, or after marks of a lower class.
    if (starter >= 0 &&
        (out.length - 1 == starter || (lastClass != 0 && lastClass < value))) {
      final composed = _pair(out[starter], rune);
      if (composed != null) {
        out[starter] = composed;
        continue;
      }
    }
    if (value == 0) starter = out.length;
    lastClass = value;
    out.add(rune);
  }
  return out;
}

/// What [first] and [second] compose to, if anything.
int? _pair(int first, int second) {
  final lead = first - _leadBase;
  if (lead >= 0 && lead < _leadCount) {
    final vowel = second - _vowelBase;
    if (vowel < 0 || vowel >= _vowelCount) return null;
    return _hangulBase + (lead * _vowelCount + vowel) * _trailCount;
  }
  final syllable = first - _hangulBase;
  if (syllable >= 0 && syllable < _hangulCount && syllable % _trailCount == 0) {
    final trail = second - _trailBase;
    if (trail <= 0 || trail >= _trailCount) return null;
    return first + trail;
  }
  return nfcCompositions[first]?[second];
}
