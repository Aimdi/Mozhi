import 'dart:math' as math;

import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/language.dart';
import 'package:translation_repository/src/models/translation_warning.dart';
import 'package:translation_repository/src/quality/protected_patterns.dart';
import 'package:translation_repository/src/quality/text_masker.dart';
import 'package:translation_repository/src/quality/writing_script.dart';

/// Local checks of a finished translation (no request, no model): what of
/// the input must come back unchanged, and whether the output is a
/// translation at all.
///
/// Format checks (every input): placeholders (`%s`, `{x}`, `{{x}}`,
/// `${x}`, masked `⟨1⟩` tokens), HTML/XML tags and entities, URLs, e-mail
/// addresses and numbers of two or more digits must appear in the output as
/// often as in the input, and the targets of glossary terms that occur in
/// the input must appear in the output.
///
/// Suspect checks ([TranslationWarningKind.isSuspect]), skipped for inputs
/// of [maxSkippedTokens] or fewer tokens, inputs without letters and
/// inputs that look like names or codes rather than prose (see
/// [checksSuspects]):
/// * echo: the normalised output equals the input while the source
///   (explicit or detected; by its script when unknown) is not the target;
/// * wrong language: most output letters are in a script the target is not
///   written in;
/// * length: the output is far shorter or longer than translations are
///   (CJK characters weigh more);
/// * not a translation (AI engines only): the output starts like a chat
///   reply ("Sure! Here is…", "As an AI…", a refusal), or answers a
///   question (the input asks one, the output asks none and is almost
///   twice as long or longer).
abstract final class TranslationQa {
  /// Inputs with at most this many tokens get no suspect checks.
  static const maxSkippedTokens = 3;

  /// Most items a warning lists.
  static const maxItems = 5;

  /// Output shorter than this share of the input's weighted length (or
  /// longer than [maxLengthRatio] times it) is suspect.
  static const minLengthRatio = 0.2;

  /// See [minLengthRatio].
  static const maxLengthRatio = 5.0;

  /// Inputs shorter than this (weighted) are not length-checked.
  static const minCheckedLength = 24;

  /// Least share of the output's letters in the target's script.
  static const minScriptShare = 0.2;

  /// Least letters of output for the script check.
  static const minScriptLetters = 8;

  /// Checks [output], the translation of [source] from [sourceLanguage]
  /// (may be auto: [detectedSource] is then the detected language, if any)
  /// into [target]. [glossary] is `TranslationOptions.glossary`; [ai] adds
  /// the chat-reply checks of AI engines.
  static List<TranslationWarning> check({
    required String source,
    required String output,
    required Language sourceLanguage,
    required Language target,
    String? detectedSource,
    Map<String, String> glossary = const {},
    bool ai = false,
  }) {
    if (source.trim().isEmpty || output.trim().isEmpty) return const [];
    final warnings = <TranslationWarning>[];
    void add(TranslationWarningKind kind, [List<String> items = const []]) =>
        warnings.add(
          TranslationWarning(
            kind,
            items: List.unmodifiable(items.take(maxItems)),
          ),
        );

    final placeholders = _missing(_placeholders(source), _placeholders(output));
    if (placeholders.isNotEmpty) {
      add(TranslationWarningKind.placeholders, placeholders);
    }
    final markup = _missing(_markup(source), _markup(output));
    if (markup.isNotEmpty) add(TranslationWarningKind.markup, markup);
    final links = _missing(_all(_url, source), _all(_url, output));
    if (links.isNotEmpty) add(TranslationWarningKind.links, links);
    final emails = _missing(
      [for (final email in _all(_email, source)) email.toLowerCase()],
      [for (final email in _all(_email, output)) email.toLowerCase()],
    );
    if (emails.isNotEmpty) add(TranslationWarningKind.emails, emails);
    final numbers = _missingNumbers(source, output);
    if (numbers.isNotEmpty) add(TranslationWarningKind.numbers, numbers);
    final terms = missingGlossaryTargets(source, output, glossary);
    if (terms.isNotEmpty) add(TranslationWarningKind.glossary, terms);

    if (checksSuspects(source)) {
      final from = sourceLanguage.isAuto ? detectedSource : sourceLanguage.code;
      if (_isEcho(source, output, from, sourceLanguage, target)) {
        add(TranslationWarningKind.echo);
      } else if (_wrongScript(output, target)) {
        add(TranslationWarningKind.wrongLanguage);
      }
      if (_extremeLength(source, output)) add(TranslationWarningKind.length);
      if (ai && looksLikeReply(source, output)) {
        add(TranslationWarningKind.notATranslation);
      }
    }
    return List.unmodifiable(warnings);
  }

  /// Whether [source] is long enough, and prose enough, for the suspect
  /// checks: more than [maxSkippedTokens] tokens, with letters and, in
  /// scripts with case, at least two lower-case words (so that names,
  /// product names and codes, which engines rightly keep, are not
  /// flagged).
  static bool checksSuspects(String source) {
    final text = _withoutProtected(source).trim();
    if (text.split(_space).length <= maxSkippedTokens) return false;
    if (!_letterPattern.hasMatch(text)) return false;
    final cased = _casedLetter.allMatches(text).length;
    final letters = _letterPattern.allMatches(text).length;
    if (cased * 2 < letters) return true;
    return _lowerWord.allMatches(text).length >= 2;
  }

  /// Whether [warnings] are worth one more AI attempt with a corrective
  /// note: lost placeholders, tags, links, e-mail addresses or glossary
  /// terms, and every suspect kind. Numbers are not (spelled out numbers
  /// and other date formats are often right).
  static bool worthRetrying(Iterable<TranslationWarning> warnings) =>
      warnings.any(
        (warning) => switch (warning.kind) {
          TranslationWarningKind.numbers => false,
          _ => true,
        },
      );

  /// The corrective note an AI model gets after an attempt with
  /// [warnings] (see `TranslationRepository.translate`): English, without
  /// the user's text, like the JSON retry note.
  static String correctiveNote(
    Iterable<TranslationWarning> warnings, {
    required Language target,
  }) {
    final problems = {
      for (final warning in warnings)
        switch (warning.kind) {
          TranslationWarningKind.placeholders =>
            'placeholders or ⟨n⟩ tokens were lost or changed',
          TranslationWarningKind.markup =>
            'HTML tags or entities were lost or changed',
          TranslationWarningKind.links => 'URLs were lost or changed',
          TranslationWarningKind.emails =>
            'e-mail addresses were lost or changed',
          TranslationWarningKind.numbers => 'numbers were changed',
          TranslationWarningKind.glossary =>
            'the required glossary terms were not used',
          TranslationWarningKind.echo =>
            'it repeats the source text instead of translating it',
          TranslationWarningKind.wrongLanguage =>
            'it is not written in the target language',
          TranslationWarningKind.length =>
            'its length does not match the source text',
          TranslationWarningKind.notATranslation =>
            'it answers or comments instead of translating',
          TranslationWarningKind.personalDataLost =>
            'placeholders or ⟨n⟩ tokens were lost or changed',
        },
    };
    final language = target.isCustom ? 'the requested style' : target.name;
    return 'Your previous reply was not a correct translation: '
        '${problems.join('; ')}. Translate the source text again into '
        '$language. Reply with the translation only (no answer, comment or '
        'explanation), and keep every placeholder, tag, URL, e-mail address, '
        'number and ⟨n⟩ token exactly as written in the source.';
  }

  /// The targets of [glossary] entries whose source term occurs in
  /// [source] (ignoring case) but that do not occur in [output] (ignoring
  /// case; an inflected ending of a term of five or more characters is
  /// accepted).
  static List<String> missingGlossaryTargets(
    String source,
    String output,
    Map<String, String> glossary,
  ) {
    if (glossary.isEmpty) return const [];
    final lowerSource = source.toLowerCase();
    final lowerOutput = output.toLowerCase();
    return [
      for (final MapEntry(key: term, value: wanted) in glossary.entries)
        if (term.trim().isNotEmpty &&
            wanted.trim().isNotEmpty &&
            lowerSource.contains(term.trim().toLowerCase()) &&
            !_containsTerm(lowerOutput, wanted.trim().toLowerCase()))
          wanted.trim(),
    ];
  }

  static bool _containsTerm(String output, String term) =>
      output.contains(term) ||
      (term.runes.length >= 5 &&
          output.contains(
            String.fromCharCodes(term.runes.toList()..removeLast()),
          ));

  /// Whether [output] reads like a chat reply to [source] rather than its
  /// translation (see the class documentation).
  static bool looksLikeReply(String source, String output) {
    final start = output.trimLeft();
    final head = start.substring(0, math.min(start.length, 160));
    for (final pattern in _replyOpenings) {
      if (pattern.hasMatch(head) && !pattern.hasMatch(source.trimLeft())) {
        return true;
      }
    }
    if (_question.hasMatch(source) && !_question.hasMatch(output)) {
      return _weightedLength(output) > 1.8 * _weightedLength(source) + 10;
    }
    return false;
  }

  /// Not followed by a letter (a word end in any script).
  static const _end = r'(?![\p{L}\p{N}])';

  static final _replyOpenings = [
    RegExp(
      '^(?:sure|certainly|of course|absolutely|okay|ok|great)$_end[!,.:]?'
      r"\s+(?:here|i(?:'ll|’ll| will| can)?)"
      '$_end',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r"^here(?:'s|’s| is| are)\s+(?:the|your|a|my)\s+(?:\S+\s+){0,2}"
      'translat',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      r'(?<![\p{L}])as an ai(?![\p{L}])|'
      r'(?<![\p{L}])as a (?:large )?language model(?![\p{L}])',
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      "^i(?:'m|’m| am) (?:sorry|unable|not able)$_end|"
      "^i can(?:not|'t|’t) (?:help|assist|translate|do)$_end",
      caseSensitive: false,
      unicode: true,
    ),
    RegExp(
      '^(?:claro|por supuesto|bien sûr|bien sur|natürlich|gerne|certo|'
      'certamente|конечно)$_end[!,.:]?'
      r'\s+(?:aquí|voici|hier|ecco|вот)'
      '$_end',
      caseSensitive: false,
      unicode: true,
    ),
  ];

  static final _question = RegExp('[?？؟]');
  static final _space = RegExp(r'\s+');
  static final _letterPattern = RegExp(r'\p{L}', unicode: true);
  static final _casedLetter = RegExp(r'[\p{Lu}\p{Ll}]', unicode: true);
  static final _lowerWord = RegExp(
    r'(?<![\p{L}\p{N}])\p{Ll}{2,}(?![\p{L}\p{N}])',
    unicode: true,
  );
  static final _wordOrDigit = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static final _url = RegExp(ProtectedPatterns.url);
  static final _email = RegExp(ProtectedPatterns.email);
  static final _tag = RegExp(ProtectedPatterns.htmlTag);
  static final _entity = RegExp(ProtectedPatterns.htmlEntity);
  static final _tagName = RegExp(r'^<(/?)([A-Za-z][\w:.-]*)');
  static final _fence = RegExp(r'```[\s\S]*?```|`[^`\n]+`');

  /// A number: digits (any script) with grouping or decimal separators
  /// between them.
  static final _number = RegExp(
    r"\p{Nd}+(?:[.,'’\u00A0\u202F]\p{Nd}+)*",
    unicode: true,
  );

  static List<String> _all(RegExp pattern, String text) => [
    for (final match in pattern.allMatches(text)) match.group(0)!,
  ];

  /// Placeholders, with masked tokens normalised to `⟨n⟩`.
  static List<String> _placeholders(String text) => [
    ..._all(ProtectedPatterns.placeholders, text),
    for (final match in TextMasker.bracketToken.allMatches(text))
      '⟨${match.group(1)}⟩',
  ];

  /// Tags by kind and name (`<b`, `</b`; attributes may be translated),
  /// comments and entities as they are.
  static List<String> _markup(String text) => [
    for (final tag in _all(_tag, text))
      if (_tagName.firstMatch(tag) case final name?)
        '<${name.group(1)}${name.group(2)!.toLowerCase()}'
      else
        tag,
    ..._all(_entity, text),
  ];

  /// The items of [expected] that [actual] has fewer of (each once).
  static List<String> _missing(List<String> expected, List<String> actual) {
    if (expected.isEmpty) return const [];
    final available = <String, int>{};
    for (final item in actual) {
      available[item] = (available[item] ?? 0) + 1;
    }
    final missing = <String>[];
    for (final item in expected) {
      final left = available[item] ?? 0;
      if (left > 0) {
        available[item] = left - 1;
      } else if (!missing.contains(item)) {
        missing.add(item);
      }
    }
    return missing;
  }

  /// Numbers of [source] (two or more digits, separators ignored, any
  /// script's digits) that [output] has fewer of, also accepting a number
  /// that appears inside the output's digits (`1.000,50` for `1,000.50`,
  /// `10:30` for `10.30`).
  static List<String> _missingNumbers(String source, String output) {
    final expected = [
      for (final number in _numbers(_withoutProtected(source)))
        if (number.length >= 2) number,
    ];
    if (expected.isEmpty) return const [];
    final found = _numbers(_withoutProtected(output));
    final digits = found.join(' ');
    final concatenated = found.join();
    return [
      for (final number in _missing(expected, found))
        if (!digits.contains(number) && !concatenated.contains(number)) number,
    ];
  }

  static List<String> _numbers(String text) => [
    for (final match in _number.allMatches(text)) _asciiDigits(match.group(0)!),
  ];

  /// The digits of [number] as ASCII digits (other scripts' digits mapped
  /// where their block is known; separators dropped).
  static String _asciiDigits(String number) {
    final buffer = StringBuffer();
    for (final rune in number.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        buffer.writeCharCode(rune);
        continue;
      }
      final zero = _digitZeros.lastWhere(
        (zero) => zero <= rune && rune <= zero + 9,
        orElse: () => -1,
      );
      if (zero >= 0) {
        buffer.writeCharCode(0x30 + rune - zero);
      } else if (!_separators.contains(rune)) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static const _separators = {0x2E, 0x2C, 0x27, 0x2019, 0xA0, 0x202F};

  /// The zero of decimal digit blocks other than ASCII (Arabic-Indic,
  /// Persian, Devanagari, Bengali, ..., full width).
  static const _digitZeros = [
    0x0660,
    0x06F0,
    0x07C0,
    0x0966,
    0x09E6,
    0x0A66,
    0x0AE6,
    0x0B66,
    0x0BE6,
    0x0C66,
    0x0CE6,
    0x0D66,
    0x0DE6,
    0x0E50,
    0x0ED0,
    0x0F20,
    0x1040,
    0x1090,
    0x17E0,
    0x1810,
    0xFF10,
  ];

  /// [text] without URLs, e-mail addresses, tags, placeholders and code
  /// (spans an engine keeps as they are).
  static String _withoutProtected(String text) => text
      .replaceAll(_fence, ' ')
      .replaceAll(ProtectedPatterns.translation, ' ')
      .replaceAll(TextMasker.bracketToken, ' ');

  static String _normalized(String text) => _wordOrDigit
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0))
      .join(' ');

  static bool _isEcho(
    String source,
    String output,
    String? from,
    Language sourceLanguage,
    Language target,
  ) {
    if (target.isCustom) return false;
    final normalized = _normalized(source);
    if (normalized.isEmpty || normalized != _normalized(output)) return false;
    if (from != null && !sourceLanguage.isCustom) {
      return !_sameLanguage(from, target.code);
    }
    // Unknown source language: an echo when its script does not fit.
    final expected = WritingScript.expectedFor(target);
    final script = WritingScript.dominant(_withoutProtected(source));
    return expected != null && script != null && !expected.contains(script);
  }

  static bool _wrongScript(String output, Language target) {
    final expected = WritingScript.expectedFor(target);
    if (expected == null) return false;
    final counts = WritingScript.count(_withoutProtected(output));
    final letters = counts.values.fold(0, (sum, count) => sum + count);
    if (letters < minScriptLetters) return false;
    final fitting = expected.fold(
      0,
      (sum, script) => sum + (counts[script] ?? 0),
    );
    return fitting < letters * minScriptShare;
  }

  static bool _extremeLength(String source, String output) {
    final input = _weightedLength(source);
    if (input < minCheckedLength) return false;
    final ratio = _weightedLength(output) / input;
    return ratio < minLengthRatio || ratio > maxLengthRatio;
  }

  /// Non-space characters, CJK characters weighing 2.5 and Hangul 1.6
  /// (they carry more per character).
  static double _weightedLength(String text) {
    var length = 0.0;
    for (final rune in text.runes) {
      if (rune == 0x20 || rune == 0x0A || rune == 0x09 || rune == 0x0D) {
        continue;
      }
      length += switch (WritingScript.of(rune)) {
        WritingScript.han || WritingScript.kana => 2.5,
        WritingScript.hangul => 1.6,
        _ => 1,
      };
    }
    return length;
  }

  static bool _sameLanguage(String a, String b) => _primary(a) == _primary(b);

  static String _primary(String code) =>
      LanguageMatcher.normalize(code).split('-').first.toLowerCase();
}
