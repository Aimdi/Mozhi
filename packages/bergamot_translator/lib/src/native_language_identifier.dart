import 'package:bergamot_translator/src/language_identifier.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/translation_repository.dart'
    show OfflineTranslator;

/// One language CLD2 found in a text (`MozhiBergamotLanguage` in
/// `native/src/mozhi_bergamot.h`).
@immutable
final class Cld2Language {
  const new(this.code, {required this.percent, required this.score});

  /// CLD2's code: ISO 639-1 where there is one, `iw` (Hebrew), `jw`
  /// (Javanese), `zh-Hant`, `xx-<Script>` (a script, no language), `un`.
  final String code;

  /// Share of the scored text, 0-100.
  final int percent;

  /// CLD2's normalized score: the language's score per KB of its text,
  /// around 1000-2000 for ordinary text, low for atypical or ambiguous text.
  final int score;

  @override
  bool operator ==(Object other) =>
      other is Cld2Language &&
      other.code == code &&
      other.percent == percent &&
      other.score == score;

  @override
  int get hashCode => Object.hash(code, percent, score);

  @override
  String toString() => 'Cld2Language($code, $percent%, $score)';
}

/// One CLD2 pass over a text (`MozhiBergamotDetection`).
@immutable
final class Cld2Result {
  const new({
    this.language = 'un',
    this.languages = const [],
    this.textBytes = 0,
    this.reliable = false,
  });

  /// CLD2's answer for the whole text, `un` when it cannot tell.
  final String language;

  /// Up to three languages by share of the text, best first (no `un`).
  final List<Cld2Language> languages;

  /// Bytes of letters CLD2 scored.
  final int textBytes;

  /// CLD2's `is_reliable`.
  final bool reliable;

  /// The score of [language] (0 when it is not among [languages]).
  int get score {
    for (final candidate in languages) {
      if (candidate.code == language) return candidate.score;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Cld2Result &&
      other.language == language &&
      other.textBytes == textBytes &&
      other.reliable == reliable &&
      _listEquals(other.languages, languages);

  @override
  int get hashCode =>
      Object.hash(language, Object.hashAll(languages), textBytes, reliable);

  @override
  String toString() =>
      'Cld2Result($language${reliable ? '' : '?'}, $languages, '
      '$textBytes bytes)';

  static bool _listEquals(List<Cld2Language> a, List<Cld2Language> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What CLD2 says about a text: its normal answer ([precise]: `un` for
/// short or ambiguous text) and its best-effort guess ([bestEffort], which
/// always names a language when the text has letters).
@immutable
final class Cld2Detection {
  const new({required this.precise, required this.bestEffort});

  final Cld2Result precise;
  final Cld2Result bestEffort;

  @override
  bool operator ==(Object other) =>
      other is Cld2Detection &&
      other.precise == precise &&
      other.bestEffort == bestEffort;

  @override
  int get hashCode => Object.hash(precise, bestEffort);

  @override
  String toString() => 'Cld2Detection($precise, guess: $bestEffort)';
}

/// The on-device language identifier compiled into `libmozhi_bergamot`
/// (CLD2, `mozhi_bergamot_detect`). Implementations run it off the UI
/// isolate.
abstract interface class NativeLanguageIdentifier {
  /// CLD2's [Cld2Detection] of [text], or null when there is no native
  /// identifier here (web, a library built without it, a library that
  /// cannot be loaded). [hints] bias CLD2 towards these codes. Throws
  /// `BergamotEngineException` when the identifier fails.
  Future<Cld2Detection?> identify(String text, {List<String> hints = const []});
}

/// Turns a [Cld2Detection] into the language [OfflineTranslator] reports.
///
/// CLD2 is precise but declines on a word or two ("Bom dia", "Danke");
/// its best-effort guesses are mostly right but sometimes far off ("Sí":
/// Irish). [choose] therefore accepts, in this order:
///
/// 1. `ug` when the [LanguageIdentifier] heuristic finds Uyghur letters
///    (CLD2's 83-language tables have no Uyghur);
/// 2. CLD2's reliable [Cld2Detection.precise] answer (any language);
/// 3. the heuristic's answer when a script used by only one language
///    decides it (Hangul, kana, Han without kana: `zh`, Greek, Hebrew,
///    Thai and the Indic scripts other than Devanagari);
/// 4. CLD2's reliable best-effort guess when the heuristic agrees, or when
///    its score is at least [minGuessScore] and it is one of the
///    `preferred` languages (those the offline engine translates from).
///
/// Otherwise null (the app then asks for the source language). On 238
/// phrases of one to six words in the 55 offline languages this answered
/// 84% correctly and 9% wrongly (mostly close languages: id/ms, cs/sk,
/// da/no/sv), against 52%/5% for CLD2 alone and 32%/10% for the
/// heuristic alone.
abstract final class Cld2Decision {
  /// Minimum [Cld2Result.score] of a best-effort guess that the heuristic
  /// does not confirm. Wrong guesses on single words mostly score lower.
  static const minGuessScore = 500;

  /// The app's code for the language of the text CLD2 saw in [detection],
  /// or null when undetermined. [heuristic] is
  /// `LanguageIdentifier.identify` of the same text; [preferred] languages
  /// may be answered on weaker evidence (empty: every language).
  static String? choose(
    Cld2Detection detection, {
    required String? heuristic,
    Set<String> preferred = const {},
  }) {
    if (heuristic == 'ug') return heuristic;
    final precise = detection.precise;
    final exact = precise.reliable ? appCode(precise.language) : null;
    if (exact != null) return exact;
    if (scriptLanguages.contains(heuristic)) return heuristic;
    final guess = detection.bestEffort;
    if (!guess.reliable) return null;
    final code = _guessCode(guess.language);
    if (code == null) return null;
    if (code == heuristic) return code;
    if (guess.score < minGuessScore) return null;
    return preferred.isEmpty || preferred.contains(code) ? code : null;
  }

  /// Languages the heuristic identifies by script alone.
  @visibleForTesting
  static const scriptLanguages = {
    'ko',
    'ja',
    'zh',
    'el',
    'he',
    'th',
    'bn',
    'gu',
    'kn',
    'ml',
    'ta',
    'te',
    'ug',
  };

  /// The app's BCP-47 code for a CLD2 code, or null for "no language"
  /// (`un`, CLD2's script-only `xx-Latn` etc., its joke languages `zz*`).
  ///
  /// CLD2's legacy codes become the current ones (`iw` -> `he`, `jw` ->
  /// `jv`, `tw` -> `ak`) and Montenegrin (`sr-ME`) Serbian; `zh-Hant`
  /// (Traditional Chinese, which has its own models) is kept.
  static String? appCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty ||
        trimmed == 'un' ||
        trimmed == 'xxx' ||
        trimmed.startsWith('xx-') ||
        trimmed.startsWith('zz') ||
        int.tryParse(trimmed) != null) {
      return null;
    }
    return _aliases[trimmed] ?? trimmed;
  }

  static const _aliases = {'iw': 'he', 'jw': 'jv', 'tw': 'ak', 'sr-ME': 'sr'};

  /// Best-effort guesses tell Simplified from Traditional Chinese by
  /// characters both share ("你好" is guessed Traditional), so a guess is
  /// only "Chinese".
  static String? _guessCode(String code) {
    final app = appCode(code);
    return app == 'zh-Hant' ? 'zh' : app;
  }
}
