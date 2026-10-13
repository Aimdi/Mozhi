import 'dart:convert';

import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/prompt_sanitizer.dart';

/// Lenient parsers for LLM output.
abstract final class ResponseParsers {
  /// Extracts the first JSON object from [text]: strips ```json fences,
  /// leading prose and `<think>` blocks, tolerates trailing commas and
  /// smart quotes around keys. Throws [FormatException] when nothing
  /// parseable is found.
  ///
  /// Also repairs raw line breaks inside strings, invalid escapes such as
  /// `\'`, Python literals (`True`/`False`/`None`) and output truncated by a
  /// token limit (the incomplete tail is dropped). When the first JSON value
  /// is an array, its first object is returned.
  static Map<String, dynamic> extractJsonObject(String text) =>
      _stringKeyed(_rootObject(_extractJson(text)));

  /// Splits a leading `[[lang:xx]]` marker (also tolerating `[lang:xx]`,
  /// `⟦xx⟧`, `[[xx]]`, surrounding whitespace, and a newline after it).
  /// Returns (code or null, remaining text). While streaming, call with the
  /// accumulated text; [isMarkerPending] tells whether the prefix could
  /// still become a marker (so the UI should not show it yet).
  ///
  /// The returned code is normalised with [LanguageMatcher.normalize]
  /// (`FR` -> `fr`, `iw` -> `he`). A `[[lang:xx]]` marker that a model put on
  /// the last line instead (or repeated there) is accepted and removed too.
  ///
  /// A marker holding a placeholder instead of a real code (a literally
  /// echoed `[[lang:xx]]`, `und`, `auto`; see [isPlaceholderLanguageCode])
  /// is still removed from the text, but its language is null.
  static ({String? language, String text}) splitLanguageMarker(String text) {
    final leading = _leadingMarker.firstMatch(text);
    if (leading != null) {
      final code = leading.group(1) ?? leading.group(2) ?? leading.group(3);
      var rest = text
          .substring(leading.end)
          .replaceFirst(_leadingBlankLines, '');
      var language = _markerLanguage(code!);
      // A model that also repeated the marker on the last line.
      final trailing = _trailingMarker.firstMatch(rest);
      if (trailing != null) {
        language ??= _markerLanguage(trailing.group(1)!);
        rest = rest.substring(0, trailing.start).trimRight();
      }
      return (language: language, text: rest);
    }
    final trailing = _trailingMarker.firstMatch(text);
    if (trailing != null && trailing.start > 0) {
      return (
        language: _markerLanguage(trailing.group(1)!),
        text: text.substring(0, trailing.start).trimRight(),
      );
    }
    return (language: null, text: text);
  }

  /// Whether a streaming snapshot of [accumulated] text should be held
  /// back because it could still turn into a language marker:
  ///
  /// * the text so far could still become a leading marker (`[[lan`), or
  /// * it ends with an unfinished trailing `[[lang:xx]]` marker
  ///   (`Hallo\n[[lang:`), which [splitLanguageMarker] would remove once
  ///   complete.
  ///
  /// A complete marker is not pending: [splitLanguageMarker] removes it.
  static bool isMarkerPending(String accumulated) {
    final s = accumulated.trimLeft();
    if (s.isEmpty) return true;
    return _isLeadingMarkerPending(s) || _isTrailingMarkerPending(s);
  }

  /// Whether [code] is a placeholder rather than a real language: `xx`,
  /// `xx-XX`, `xxx`, `und` (and its subtags), `auto`, or a schema word
  /// echoed from a prompt (`code`, `iso`, `lang`, `language`). Empty codes
  /// count as placeholders. Case-insensitive; `_` equals `-`.
  static bool isPlaceholderLanguageCode(String code) {
    final key = code.trim().toLowerCase().replaceAll('_', '-');
    if (key.isEmpty) return true;
    final primary = key.split('-').first;
    return const {'xx', 'xxx', 'und'}.contains(primary) ||
        const {'auto', 'code', 'iso', 'lang', 'language'}.contains(key);
  }

  /// Removes wrapping quotes / `<translation>` / `<source>` tags /
  /// "Translation:" prefixes that models sometimes add, only when the
  /// source text itself did not have them.
  ///
  /// Also unwraps a code fence around the whole output, drops a trailing
  /// "Note: ..." paragraph when the source has no notes, and removes the
  /// zero-width space the prompts insert into data tags (`<\u200Bsource>` ->
  /// `<source>`) when the model copied it.
  static String cleanTranslation(String output, {required String source}) {
    final src = source.trim();
    final srcLower = src.toLowerCase();
    final keepIndent = RegExp(r'^[ \t]')
        .hasMatch(source.replaceFirst(RegExp(r'^(?:[ \t]*\r?\n)+'), ''));
    // Tags such as an HTML `<source>` element were defused in the prompt;
    // undo it where the model copied the zero-width space.
    var text = PromptSanitizer.restoreTags(
      output,
      original: source,
    ).trimRight();
    text = keepIndent
        ? text.replaceFirst(_leadingBlankLines, '')
        : text.trimLeft();

    for (var i = 0; i < 4; i++) {
      final before = text;
      text = _unwrapTags(text, srcLower);
      text = _stripLabel(text, src);
      text = _unwrapFence(text, src);
      text = _unwrapQuotes(text, src);
      if (text == before) break;
    }
    return _stripTrailingNote(text, srcLower);
  }

  static AlternativeTranslations parseAlternatives(String output) {
    final value = _extractJson(output);
    final root = value is Map ? value : null;
    final items = value is List
        ? value
        : _findList(root!, const [
            'alternatives',
            'elements',
            'translations',
            'options',
            'items',
          ]);
    final seen = <String>{};
    final alternatives = <Alternative>[
      for (final item in items)
        if (_alternative(item) case final alternative?)
          if (seen.add(alternative.text)) alternative,
    ];
    return AlternativeTranslations(
      description: root == null
          ? ''
          : _string(root, const [
              'description',
              'original_description',
              'summary',
              'main_description',
            ]),
      alternatives: alternatives,
    );
  }

  /// Drops insights whose `target` is not a substring of [translation].
  ///
  /// A `target` that only matches after trimming quotes/punctuation or
  /// ignoring case is replaced by the exact substring of [translation].
  static List<WordInsight> parseInsights(
    String output, {
    required String translation,
  }) {
    final value = _extractJson(output);
    final items = value is List
        ? value
        : _findList(value as Map, const ['insights', 'items', 'words']);
    final seen = <String>{};
    final insights = <WordInsight>[];
    for (final item in items) {
      if (item is! Map) continue;
      final rawTarget = _string(item, const [
        'target',
        'target_text',
        'translated_text',
        'translation',
        'text',
      ]);
      final target = _locate(
        PromptSanitizer.restoreTags(rawTarget, original: translation),
        translation,
      );
      if (target == null || !seen.add(target)) continue;
      final variations = <Alternative>[
        for (final variation in _list(item, const [
          'variations',
          'alternatives',
          'options',
        ]))
          if (_alternative(variation) case final alternative?)
            if (alternative.text != target) alternative,
      ];
      final type = _string(item, const ['type', 'category', 'kind']);
      insights.add(
        WordInsight(
          sourceText: _string(item, const [
            'source',
            'source_text',
            'original',
            'original_text',
          ]),
          targetText: target,
          type: type.isEmpty ? 'nuance' : type.toLowerCase(),
          explanation: _string(item, const [
            'explanation',
            'description',
            'insight',
            'note',
          ]),
          variations: variations,
        ),
      );
    }
    return insights;
  }

  /// Longest [RefinementSuggestion.instruction] kept by [parseSuggestions].
  static const maxSuggestionInstructionLength = 200;

  /// Model-generated refinement chips. The model read the (possibly
  /// hostile) source text, so every `instruction` is sanitised: a single
  /// line without control characters or `<`/`>`, at most
  /// [maxSuggestionInstructionLength] characters.
  static List<RefinementSuggestion> parseSuggestions(String output) {
    final value = _extractJson(output);
    final items = value is List
        ? value
        : _findList(value as Map, const [
            'suggestions',
            'refinements',
            'items',
          ]);
    final seen = <String>{};
    final suggestions = <RefinementSuggestion>[];
    for (final item in items) {
      if (item is! Map) continue;
      final label = _string(item, const ['label', 'title', 'name']);
      if (label.isEmpty || !seen.add(label.toLowerCase())) continue;
      final description = _string(item, const [
        'description',
        'tooltip',
        'details',
      ]);
      final instruction = _instruction(
        _string(item, const [
          'instruction',
          'instructions',
          'prompt',
          'action',
        ]),
      );
      final fallback = _instruction(description);
      suggestions.add(
        RefinementSuggestion(
          label: label,
          instruction: instruction.isNotEmpty
              ? instruction
              : fallback.isNotEmpty
              ? fallback
              : _instruction(label),
          description: description,
          icon: _icon(_string(item, const ['icon', 'category', 'type'])),
        ),
      );
    }
    return suggestions;
  }

  static DictionaryEntry parseDictionary(String output) {
    final value = _extractJson(output);
    final root = _rootObject(value);

    final senses = <DictionarySense>[
      for (final item in _list(root, const [
        'senses',
        'meanings',
        'definitions',
      ]))
        ?_sense(item),
      // Kagi-style {"primary_meaning": {...}}.
      if (_get(root, const ['primary_meaning'])
          case final Map<dynamic, dynamic> primary)
        ?_sense(primary),
    ];

    var partsOfSpeech = _strings(
      _get(root, const ['parts_of_speech', 'part_of_speech', 'pos']),
    );
    if (partsOfSpeech.isEmpty) {
      partsOfSpeech = <String>{
        for (final sense in senses)
          if (sense.partOfSpeech.isNotEmpty) sense.partOfSpeech,
      }.toList();
    }

    return DictionaryEntry(
      word: _string(root, const ['word', 'headword', 'term', 'lemma']),
      pronunciation: _string(root, const [
        'pronunciation',
        'ipa',
        'phonetic',
        'transcription',
      ]),
      partsOfSpeech: partsOfSpeech,
      senses: senses,
      examples: [
        for (final item in _list(root, const ['examples', 'example']))
          ?_example(item),
      ],
      synonyms: _strings(_get(root, const ['synonyms'])),
      etymology: _string(root, const ['etymology', 'origin']),
      notes: _string(root, const ['notes', 'note', 'usage_notes']),
    );
  }

  /// Drops edits whose `original` does not occur in [input].
  static ProofreadResult parseProofread(
    String output, {
    required String input,
  }) {
    final value = _extractJson(output);
    final root = value is Map ? value : <String, dynamic>{'edits': value};

    final edits = <ProofreadEdit>[];
    for (final item in _list(root, const ['edits', 'corrections', 'changes'])) {
      if (item is! Map) continue;
      final original = _locate(
        _rawString(item, const ['original', 'from', 'before', 'error']),
        input,
        allowEmptyTrim: false,
      );
      if (original == null) continue;
      final replacement =
          _rawString(item, const [
            'replacement',
            'corrected',
            'correction',
            'to',
            'after',
            'suggestion',
          ]) ??
          '';
      if (replacement == original) continue;
      edits.add(
        ProofreadEdit(
          original: original,
          replacement: replacement,
          explanation: _string(item, const ['explanation', 'reason', 'note']),
          category: _category(_string(item, const ['category', 'type'])),
        ),
      );
    }

    var corrected = _rawString(root, const [
      'corrected',
      'corrected_text',
      'correction',
      'text',
      'result',
    ]);
    if (corrected == null || corrected.trim().isEmpty) {
      corrected = input;
      for (final edit in edits) {
        corrected = corrected!.replaceFirst(edit.original, edit.replacement);
      }
    }

    final language = _languageCode(
      _string(root, const ['language', 'detected_language', 'lang', 'iso']),
    );
    return ProofreadResult(
      correctedText: corrected!,
      edits: edits,
      detectedLanguage: language.isEmpty ? null : language,
      summary: _string(root, const ['summary', 'analysis', 'feedback']),
    );
  }

  static DetectedLanguage parseDetectedLanguage(String output) {
    Object? value;
    try {
      value = _extractJson(output);
    } on FormatException {
      // Plain answers such as "fr", "[[lang:fr]]" or "French".
      final plain = _stripThink(output).trim();
      final marker = splitLanguageMarker(plain).language;
      final code = marker ?? _languageCode(plain.split(RegExp(r'\s')).first);
      if (code.isEmpty || plain.length > 40) rethrow;
      return DetectedLanguage(code: code);
    }
    final root = _rootObject(value);
    final code = _languageCode(
      _string(root, const [
        'language',
        'iso',
        'code',
        'lang',
        'detected_language',
      ]),
    );
    if (code.isEmpty) {
      throw FormatException('No language in detection result', output);
    }
    final alternatives = <String>[];
    for (final item in _list(root, const ['alternatives', 'candidates'])) {
      final raw = item is Map
          ? _string(item, const ['iso', 'code', 'language'])
          : item is String
          ? item
          : '';
      final alternative = _languageCode(raw);
      if (alternative.isNotEmpty &&
          alternative != code &&
          !alternatives.contains(alternative)) {
        alternatives.add(alternative);
      }
    }
    return DetectedLanguage(
      code: code,
      isUncertain: _bool(_get(root, const ['uncertain', 'is_uncertain'])),
      isMixed: _bool(_get(root, const ['mixed', 'is_mixed'])),
      alternatives: alternatives,
    );
  }

  // ---------------------------------------------------------------------
  // Language marker.
  // ---------------------------------------------------------------------

  /// A language code, or the placeholder `auto` (so an echoed
  /// `[[lang:auto]]` is still removed).
  static const _codePattern = '([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*|auto)';
  static const _keyword = r'lang(?:uage)?\s*[:=]\s*';
  static const _markerBody =
      '\\[\\[\\s*(?:$_keyword)?$_codePattern\\s*\\]\\]'
      '|\\[\\s*$_keyword$_codePattern\\s*\\]'
      '|⟦\\s*(?:$_keyword)?$_codePattern\\s*⟧';

  static final _leadingMarker = RegExp(
    '^\\s*(?:$_markerBody)[ \\t]*(?:\\r?\\n)?',
    caseSensitive: false,
  );
  static final _wholeMarker = RegExp(
    '^\\s*(?:$_markerBody)\\s*\$',
    caseSensitive: false,
  );
  static final _trailingMarker = RegExp(
    '\\s*\\[\\[\\s*$_keyword$_codePattern\\s*\\]\\]\\s*\$',
    caseSensitive: false,
  );

  /// A whole trailing marker (anchored at both ends).
  static final _wholeTrailingMarker = RegExp(
    '^\\[\\[\\s*$_keyword$_codePattern\\s*\\]\\]\\s*\$',
    caseSensitive: false,
  );

  /// Longest text a (partial) marker is looked for in.
  static const _maxMarkerLength = 40;

  static String? _markerLanguage(String code) =>
      isPlaceholderLanguageCode(code) ? null : LanguageMatcher.normalize(code);

  static bool _isLeadingMarkerPending(String s) {
    if (s.length > _maxMarkerLength || s.contains('\n')) return false;
    if (_leadingMarker.hasMatch(s)) return false;
    // `s` is pending when some completion turns it into a whole marker.
    for (final keyword in _keywordTails) {
      for (final middle in const ['', 'x', 'fr', ':fr']) {
        for (final closer in const [']]', ']', '⟧']) {
          if (_wholeMarker.hasMatch('$s$keyword$middle$closer')) return true;
        }
      }
    }
    return false;
  }

  /// Whether [s] (trimmed at the start) ends with an unfinished trailing
  /// `[[lang:xx]]` marker: some `[` in the last [_maxMarkerLength]
  /// characters, after other text, starts a tail that a completion turns
  /// into a whole trailing marker.
  static bool _isTrailingMarkerPending(String s) {
    final from = s.length > _maxMarkerLength ? s.length - _maxMarkerLength : 1;
    for (var i = s.lastIndexOf('['); i >= from; i = s.lastIndexOf('[', i - 1)) {
      final tail = s.substring(i);
      if (_wholeTrailingMarker.hasMatch(tail)) return false;
      for (final opener in const ['', '[']) {
        for (final keyword in _keywordTails) {
          for (final middle in const ['', 'x', 'fr', ':fr']) {
            for (final closer in const [']]', ']']) {
              if (_wholeTrailingMarker.hasMatch(
                '$tail$opener$keyword$middle$closer',
              )) {
                return true;
              }
            }
          }
        }
      }
    }
    return false;
  }

  static final _leadingBlankLines = RegExp(r'^(?:[ \t]*\r?\n)+');

  /// Every suffix of `lang` and `language`, for prefix completion.
  static final _keywordTails = <String>{
    for (final word in const ['lang', 'language'])
      for (var i = 0; i <= word.length; i++) word.substring(i),
  };

  // ---------------------------------------------------------------------
  // cleanTranslation helpers.
  // ---------------------------------------------------------------------

  static const _wrapperTags = [
    'translation',
    'source',
    'target',
    'output',
    'result',
  ];

  static String _unwrapTags(String text, String sourceLower) {
    var t = text;
    if (!sourceLower.contains('<translation')) {
      final inner = RegExp(
        r'<translation(?:\s[^>]*)?>([\s\S]*?)</translation>',
        caseSensitive: false,
      ).firstMatch(t);
      if (inner != null && inner.group(1)!.trim().isNotEmpty) {
        t = inner.group(1)!.trim();
      }
    }
    for (final tag in _wrapperTags) {
      if (sourceLower.contains('<$tag') || sourceLower.contains('</$tag')) {
        continue;
      }
      t = t
          .replaceFirst(
            RegExp(
              '^\\s*<$tag(?:\\s[^>]*)?>[ \\t]*\\r?\\n?',
              caseSensitive: false,
            ),
            '',
          )
          .replaceFirst(
            RegExp('\\r?\\n?[ \\t]*</$tag>\\s*\$', caseSensitive: false),
            '',
          );
    }
    return t.trim().isEmpty ? text : t;
  }

  static final _labelPattern = RegExp(
    r'^\s*(?:(?:sure|okay|ok|certainly|of course)[!,.]?\s*)?'
    r'(?:\*\*|__)?'
    "(?:here(?:'s| is) (?:the |your |my )?(?:translation|translated text|"
    r'rewritten text|improved text)[^\n:：]{0,60}'
    r'|(?:the )?translation(?: in(?:to)? [^\n:：]{1,40}| \([^\n)]{1,40}\))?'
    '|translated text)'
    r'\s*(?:\*\*|__)?\s*[:：]\s*(?:\*\*|__)?[ \t]*(?:\r?\n)?',
    caseSensitive: false,
  );

  /// "Word:" at the start of a text (a label such as "Traducción:").
  static final _anyLabel = RegExp(r'^\s*[^\s:：][^\n:：]{0,40}[:：]');

  static String _stripLabel(String text, String source) {
    // A source that starts with a label of its own (in any language) may
    // legitimately translate to "Translation:".
    if (_anyLabel.hasMatch(source)) return text;
    final match = _labelPattern.firstMatch(text);
    if (match == null) return text;
    final rest = text.substring(match.end).trim();
    return rest.isEmpty ? text : rest;
  }

  static final _fence = RegExp(r'^```[\w-]*[ \t]*\r?\n([\s\S]*?)\r?\n?```$');

  static String _unwrapFence(String text, String source) {
    if (source.startsWith('```')) return text;
    final match = _fence.firstMatch(text.trim());
    if (match == null) return text;
    final inner = match.group(1)!.trim();
    return inner.isEmpty ? text : inner;
  }

  static const _quotePairs = {
    '"': '"',
    "'": "'",
    '“': '”',
    '”': '”',
    '„': '“',
    '‘': '’',
    '«': '»',
    '»': '«',
    '‹': '›',
    '「': '」',
    '『': '』',
  };
  static final Set<String> _quoteChars = {
    ..._quotePairs.keys,
    ..._quotePairs.values,
    '‚',
    '〝',
    '〞',
  };

  static String _unwrapQuotes(String text, String source) {
    final t = text.trim();
    if (t.length < 2) return text;
    if (source.isNotEmpty && _quoteChars.contains(source[0])) return text;
    final open = t[0];
    final close = _quotePairs[open];
    if (close == null || t[t.length - 1] != close) return text;
    final inner = t.substring(1, t.length - 1);
    if (inner.trim().isEmpty || inner.contains(open) || inner.contains(close)) {
      return text;
    }
    return inner.trim();
  }

  static final _notePattern = RegExp(
    r"^\s*[(\[]?\s*(?:\*\*|__|\*|_)?(?:note|translator'?s? note|n\.b\.)"
    r'(?:\*\*|__|\*|_)?\s*[:：]',
    caseSensitive: false,
  );

  static final _paragraphBreak = RegExp(r'\r?\n[ \t]*\r?\n');

  /// Drops a final "Note: ..." paragraph that the source has no counterpart
  /// for (the output has more paragraphs than the source).
  static String _stripTrailingNote(String text, String sourceLower) {
    if (sourceLower.contains('note') || sourceLower.contains('n.b.')) {
      return text;
    }
    final paragraphs = text.split(_paragraphBreak);
    final sourceParagraphs = sourceLower.trim().split(_paragraphBreak).length;
    if (paragraphs.length <= sourceParagraphs ||
        !_notePattern.hasMatch(paragraphs.last)) {
      return text;
    }
    final index = text.lastIndexOf(paragraphs.last);
    final kept = text.substring(0, index).trimRight();
    return kept.isEmpty ? text : kept;
  }

  // ---------------------------------------------------------------------
  // JSON extraction.
  // ---------------------------------------------------------------------

  /// The first JSON object (or array of objects) in [text].
  static Object _extractJson(String text) {
    final stripped = _stripThink(text);
    final value =
        _findJson(stripped) ?? (stripped == text ? null : _findJson(text));
    if (value == null) throw FormatException('No JSON found', text);
    return value;
  }

  static String _stripThink(String text) {
    const tags = 'think|thinking|reasoning|thought';
    var s = text.replaceAll(
      RegExp('<($tags)\\b[^>]*>[\\s\\S]*?</\\1\\s*>', caseSensitive: false),
      '',
    );
    // A closing tag whose opening tag was swallowed by the server.
    final closing = RegExp(
      '</(?:$tags)\\s*>',
      caseSensitive: false,
    ).allMatches(s).lastOrNull;
    if (closing != null) s = s.substring(closing.end);
    // An unterminated block (e.g. cut off by a token limit).
    final opening = RegExp(
      '<(?:$tags)\\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(s);
    if (opening != null) s = s.substring(0, opening.start);
    return s;
  }

  static Object? _findJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (_acceptable(_decode(trimmed)) case final value?) return value;

    for (final fence in RegExp(
      r'```[\w-]*[ \t]*\r?\n?([\s\S]*?)```',
    ).allMatches(trimmed)) {
      final inner = fence.group(1)!.trim();
      if (_acceptable(_decode(inner)) case final value?) return value;
    }

    // Scan for the first balanced object/array that decodes. An opening
    // bracket that is never closed may be output truncated by a token
    // limit: close what is open, dropping an incomplete tail.
    for (var i = 0; i < trimmed.length; i++) {
      final c = trimmed[i];
      if (c != '{' && c != '[') continue;
      final end = _balancedEnd(trimmed, i);
      final candidate = end < 0
          ? _decodeTruncated(trimmed.substring(i))
          : _decode(trimmed.substring(i, end + 1));
      if (_acceptable(candidate) case final value?) return value;
    }
    return null;
  }

  /// [value] itself, or the first map of a list (see [_acceptable]).
  static Map<dynamic, dynamic> _rootObject(Object value) => value is Map
      ? value
      : (value as List).whereType<Map<dynamic, dynamic>>().first;

  /// Maps, and lists containing at least one map.
  static Object? _acceptable(Object? value) => switch (value) {
    final Map<dynamic, dynamic> map => map,
    final List<dynamic> list when list.any((e) => e is Map) => list,
    _ => null,
  };

  static Object? _decode(String candidate) {
    try {
      return jsonDecode(candidate);
    } on FormatException {
      try {
        return jsonDecode(_repair(candidate));
      } on FormatException {
        return null;
      }
    }
  }

  /// Index of the bracket closing the one at [start], or -1.
  static int _balancedEnd(String s, int start) {
    final stack = <String>[];
    var inString = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case '"':
          inString = true;
        case '{':
          stack.add('}');
        case '[':
          stack.add(']');
        case '}' || ']':
          if (stack.isEmpty || stack.removeLast() != c) return -1;
          if (stack.isEmpty) return i;
      }
    }
    return -1;
  }

  static const _smartOpen = {'“', '„', '‟', '”', '″'};
  static const _smartClose = {'”', '“', '″'};

  /// Fixes common LLM JSON mistakes (see [extractJsonObject]).
  static String _repair(String s) {
    final out = StringBuffer();
    var inString = false;
    var smart = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (c == r'\') {
          final next = i + 1 < s.length ? s[i + 1] : '';
          if (next.isNotEmpty && r'"\/bfnrtu'.contains(next)) {
            out.write('$c$next');
          } else if (next.isNotEmpty) {
            out.write(next == '\n' ? r'\n' : next);
          }
          i++;
        } else if (c == '"' || (smart && _smartClose.contains(c))) {
          inString = false;
          out.write('"');
        } else if (c == '\n') {
          out.write(r'\n');
        } else if (c == '\r') {
          out.write(r'\r');
        } else if (c == '\t') {
          out.write(r'\t');
        } else {
          out.write(c);
        }
        continue;
      }
      if (c == '"' || _smartOpen.contains(c)) {
        inString = true;
        smart = c != '"';
        out.write('"');
      } else if (c == ',') {
        var j = i + 1;
        while (j < s.length && s[j].trim().isEmpty) {
          j++;
        }
        if (j < s.length && (s[j] == '}' || s[j] == ']')) continue;
        out.write(c);
      } else if (_isWordStart(s, i)) {
        final literal = _pythonLiteral(s, i);
        if (literal != null) {
          out.write(literal.$2);
          i += literal.$1.length - 1;
        } else {
          out.write(c);
        }
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  static bool _isWordStart(String s, int i) =>
      i == 0 || !RegExp(r'\w').hasMatch(s[i - 1]);

  static (String, String)? _pythonLiteral(String s, int i) {
    for (final (python, json) in const [
      ('True', 'true'),
      ('False', 'false'),
      ('None', 'null'),
    ]) {
      if (s.startsWith(python, i)) {
        final after = i + python.length;
        if (after >= s.length || !RegExp(r'\w').hasMatch(s[after])) {
          return (python, json);
        }
      }
    }
    return null;
  }

  /// Closes an unterminated JSON prefix, retrying at earlier commas so a
  /// half-written trailing element is dropped.
  static Object? _decodeTruncated(String s) {
    final cuts = <(int, List<String>)>[];
    final stack = <String>[];
    var inString = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case '"':
          inString = true;
        case '{':
          stack.add('}');
        case '[':
          stack.add(']');
        case '}' || ']':
          if (stack.isEmpty) return null;
          stack.removeLast();
          if (stack.isEmpty) return null; // Balanced: not truncated.
          cuts.add((i + 1, List.of(stack)));
        case ',':
          cuts.add((i, List.of(stack)));
      }
    }
    if (stack.isEmpty) return null;
    String close(String prefix, List<String> open) =>
        prefix + open.reversed.join();
    final attempts = [
      close(inString ? '$s"' : s, stack),
      for (final (index, open) in cuts.reversed.take(12))
        close(s.substring(0, index), open),
    ];
    for (final attempt in attempts) {
      final value = _decode(attempt);
      if (value is Map && value.isNotEmpty) return value;
      if (value is List && value.isNotEmpty) return value;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Tolerant field access.
  // ---------------------------------------------------------------------

  static String _keyOf(Object? key) =>
      '$key'.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  static Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> map) => {
    for (final MapEntry(:key, :value) in map.entries) '$key': value,
  };

  /// The value of the first of [names] present in [map], comparing keys
  /// case-insensitively and ignoring `_`/`-` (so `partsOfSpeech` matches
  /// `parts_of_speech`).
  static Object? _get(Map<dynamic, dynamic> map, List<String> names) {
    for (final name in names) {
      final wanted = _keyOf(name);
      for (final MapEntry(:key, :value) in map.entries) {
        if (value != null && _keyOf(key) == wanted) return value;
      }
    }
    return null;
  }

  static String? _rawString(Map<dynamic, dynamic> map, List<String> names) =>
      switch (_get(map, names)) {
        final String s => s,
        final num n => '$n',
        _ => null,
      };

  static String _string(Map<dynamic, dynamic> map, List<String> names) =>
      switch (_get(map, names)) {
        final String s => s.trim(),
        final num n => '$n',
        final bool b => '$b',
        final List<dynamic> l => _strings(l).join(', '),
        _ => '',
      };

  static List<dynamic> _list(Map<dynamic, dynamic> map, List<String> names) =>
      switch (_get(map, names)) {
        final List<dynamic> l => l,
        final Map<dynamic, dynamic> m => [m],
        _ => const [],
      };

  /// Like [_list], falling back to the only list-valued field.
  static List<dynamic> _findList(
    Map<dynamic, dynamic> map,
    List<String> names,
  ) {
    final named = _get(map, names);
    if (named is List) return named;
    final lists = map.values.whereType<List<dynamic>>().toList();
    return lists.length == 1 ? lists.single : const [];
  }

  static List<String> _strings(Object? value) => switch (value) {
    final List<dynamic> l => [
      for (final e in l)
        if (e is String && e.trim().isNotEmpty)
          e.trim()
        else if (e is num)
          '$e'
        else if (e is Map)
          if (_string(e, const ['word', 'text', 'value', 'name']) case final s
              when s.isNotEmpty)
            s,
    ],
    final String s when s.trim().isNotEmpty => [
      for (final part in s.split(RegExp(r'\s*[,;、，]\s*')))
        if (part.trim().isNotEmpty) part.trim(),
    ],
    _ => const [],
  };

  static bool _bool(Object? value) => switch (value) {
    final bool b => b,
    final num n => n != 0,
    final String s => const {'true', 'yes', '1'}.contains(s.toLowerCase()),
    _ => false,
  };

  static Alternative? _alternative(Object? item) {
    final (text, explanation) = switch (item) {
      final String s => (s.trim(), ''),
      final Map<dynamic, dynamic> m => (
        _string(m, const ['text', 'translation', 'alternative', 'value']),
        _string(m, const ['explanation', 'description', 'note', 'reason']),
      ),
      _ => ('', ''),
    };
    return text.isEmpty
        ? null
        : Alternative(
            text: PromptSanitizer.restoreTags(text),
            explanation: explanation,
          );
  }

  static DictionarySense? _sense(Object? item) {
    if (item is String) {
      return item.trim().isEmpty ? null : DictionarySense(definition: item);
    }
    if (item is! Map) return null;
    final definition = _string(item, const [
      'definition',
      'meaning',
      'gloss',
      'description',
    ]);
    if (definition.isEmpty) return null;
    return DictionarySense(
      definition: definition,
      partOfSpeech: _string(item, const ['part_of_speech', 'pos']),
      translations: _strings(_get(item, const ['translations', 'translation'])),
      usage: _string(item, const ['usage', 'usage_level', 'register', 'label']),
    );
  }

  static DictionaryExample? _example(Object? item) {
    if (item is String) {
      return item.trim().isEmpty
          ? null
          : DictionaryExample(source: item.trim());
    }
    if (item is! Map) return null;
    final source = _string(item, const [
      'source',
      'sentence',
      'example',
      'text',
      'original',
    ]);
    if (source.isEmpty) return null;
    return DictionaryExample(
      source: source,
      translation: _string(item, const ['translation', 'target', 'meaning']),
    );
  }

  static const _icons = {
    'tune',
    'formal',
    'casual',
    'shorter',
    'longer',
    'simplify',
    'fluent',
    'literal',
  };

  static String _icon(String raw) {
    final key = raw.toLowerCase().trim();
    if (_icons.contains(key)) return key;
    return switch (key) {
      'formality' || 'polite' || 'professional' => 'formal',
      'informal' || 'friendly' || 'conversational' => 'casual',
      'short' || 'concise' || 'brevity' || 'condense' => 'shorter',
      'long' || 'expand' || 'detailed' || 'elaborate' => 'longer',
      'simple' || 'simpler' || 'simplicity' || 'clarity' => 'simplify',
      'natural' || 'idiomatic' || 'fluency' => 'fluent',
      'faithful' || 'accurate' || 'closer' => 'literal',
      _ => 'tune',
    };
  }

  static const _categories = {
    'grammar',
    'spelling',
    'punctuation',
    'style',
    'clarity',
    'word_choice',
    'tone',
    'repetition',
  };

  static String _category(String raw) {
    final key = raw.toLowerCase().trim().replaceAll(RegExp(r'[\s-]+'), '_');
    if (key.isEmpty) return 'grammar';
    if (_categories.contains(key)) return key;
    return switch (key) {
      'typo' || 'orthography' || 'capitalization' => 'spelling',
      'vocabulary' || 'wording' || 'word' || 'diction' => 'word_choice',
      'redundancy' || 'repeated_word' || 'repetitions' => 'repetition',
      'agreement' || 'syntax' || 'tense' => 'grammar',
      'formality' || 'register' => 'tone',
      'readability' || 'conciseness' || 'concision' => 'clarity',
      _ => 'style',
    };
  }

  /// Finds [candidate] in [haystack]: exactly, after trimming quotes and
  /// punctuation, or ignoring case. Returns the exact substring, or null.
  static String? _locate(
    String? candidate,
    String haystack, {
    bool allowEmptyTrim = true,
  }) {
    if (candidate == null || candidate.isEmpty) return null;
    if (haystack.contains(candidate)) return candidate;
    final trimmed = candidate.trim().replaceAll(_edgePunctuation, '');
    if (trimmed.isEmpty) return null;
    if (haystack.contains(trimmed)) return trimmed;
    final index = haystack.toLowerCase().indexOf(trimmed.toLowerCase());
    if (index < 0 || haystack.length != haystack.toLowerCase().length) {
      return null;
    }
    return haystack.substring(index, index + trimmed.length);
  }

  static final _edgePunctuation = RegExp(
    '^["\'“”„«»‘’「」『』*]+|["\'“”„«»‘’「」『』*]+\$',
  );

  /// A sanitised [RefinementSuggestion.instruction] (see [parseSuggestions]).
  static String _instruction(String raw) => PromptSanitizer.singleLine(
    raw,
    maxLength: maxSuggestionInstructionLength,
    stripAngleBrackets: true,
    atWordBoundary: true,
  );

  /// A catalogue code for a code or English language name; empty for
  /// placeholders (see [isPlaceholderLanguageCode]).
  static String _languageCode(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    final marker = splitLanguageMarker(s).language;
    if (marker != null) return marker;
    s = s.replaceAll(RegExp('^["\'`*]+|["\'`*.]+\$'), '').trim();
    if (s.isEmpty || isPlaceholderLanguageCode(s)) return '';
    final isCode = RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*$')
        .hasMatch(s);
    if (isCode) {
      final normalized = LanguageMatcher.normalize(s);
      if (LanguageCatalog.byCode(normalized) != null) return normalized;
    }
    final byName =
        LanguageCatalog.byName(s) ??
        LanguageCatalog.byName(s.split('(').first.trim());
    if (byName != null) return byName.code;
    return isCode ? LanguageMatcher.normalize(s) : '';
  }
}
