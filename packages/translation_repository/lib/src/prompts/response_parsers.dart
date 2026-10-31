import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/prompt_sanitizer.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';

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
  ///
  /// `exclusive_group` (or `exclusiveGroup`, `group`) becomes
  /// [RefinementSuggestion.exclusiveGroup]: lower-case letters, digits,
  /// `_` and `-` only, at most 30 characters; `null`, `none` and empty
  /// values mean no group. Without a group, the `formal`/`casual` icons
  /// imply [RefinementSuggestion.formalityGroup] and `shorter`/`longer`
  /// imply [RefinementSuggestion.lengthGroup].
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
      final icon = _icon(_string(item, const ['icon', 'category', 'type']));
      suggestions.add(
        RefinementSuggestion(
          label: label,
          instruction: instruction.isNotEmpty
              ? instruction
              : fallback.isNotEmpty
              ? fallback
              : _instruction(label),
          description: description,
          icon: icon,
          exclusiveGroup:
              _group(
                _string(item, const [
                  'exclusive_group',
                  'exclusiveGroup',
                  'group',
                ]),
              ) ??
              _groupOfIcon(icon),
        ),
      );
    }
    return suggestions;
  }

  /// Longest [DictionaryEntry.didYouMean] kept by [parseDictionary].
  static const maxDidYouMeanLength = 100;

  /// A dictionary entry. [query] is the looked-up text: a `did_you_mean`
  /// that merely repeats it (ignoring case and surrounding space) is
  /// dropped, as are `null`, `none` and empty values. `didYouMean` is
  /// reduced to one line of at most [maxDidYouMeanLength] characters
  /// without quotes or `<`/`>`. `related_words` (or `related`, `see_also`,
  /// `word_family`) are de-duplicated ignoring case.
  static DictionaryEntry parseDictionary(String output, {String query = ''}) {
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
      relatedWords: _distinct(
        _strings(
          _get(root, const [
            'related_words',
            'related',
            'see_also',
            'word_family',
          ]),
        ),
      ),
      didYouMean: _didYouMean(
        _get(root, const [
          'did_you_mean',
          'spelling_suggestion',
          'corrected_spelling',
          'suggestion',
        ]),
        query: query,
      ),
    );
  }

  /// Most items of an alignment that [parseAlignment] reads; later ones are
  /// ignored. Generous for the at most
  /// `TranslationPrompts.maxAlignmentChars` characters that are aligned,
  /// while bounding the work for a runaway or hostile reply.
  static const maxAlignmentPairs = 1000;

  /// Maps each `{"source": str, "target": str}` pair of the model's
  /// alignment (`pairs`, `alignment`, `alignments`, `spans`; or a bare
  /// list, also of `[source, target]` lists) to character offsets in
  /// [source] and [translation].
  ///
  /// A phrase is searched for exactly, then without surrounding quotes and
  /// punctuation, then ignoring case (offsets always refer to the original
  /// text). Of its occurrences, those at word boundaries (`cat` not inside
  /// `scattered`; any position in scripts written without spaces) come
  /// first, then those no earlier pair took (so repeated phrases map to
  /// successive occurrences). Pairs are listed in source order, so on the
  /// source side the next occurrence after the previous pair's phrase is
  /// preferred; translations reorder words (`red car` -> `voiture rouge`),
  /// so on the target side the occurrence nearest to the previous pair's
  /// phrase is. Pairs with a phrase not found on either side are dropped,
  /// as are duplicates. The result is sorted by source position.
  ///
  /// The work is bounded (this runs on the UI isolate): only the
  /// beginnings of [source] and [translation] that `TranslationPrompts
  /// .align` sends (at most `TranslationPrompts.maxAlignmentChars`
  /// characters each, cut at a word boundary) are searched, and only the
  /// first [maxAlignmentPairs] items of the output are read.
  static List<AlignedSpan> parseAlignment(
    String output, {
    required String source,
    required String translation,
  }) {
    final value = _extractJson(output);
    final items = value is List
        ? value
        : _findList(value as Map, const [
            'pairs',
            'alignment',
            'alignments',
            'spans',
            'items',
          ]);
    final spans = <AlignedSpan>[];
    final seen = <AlignedSpan>{};
    // The model saw only these beginnings; offsets into a prefix are
    // offsets into the whole text.
    final sourceText = _AlignmentText(
      PromptSanitizer.prefix(source, TranslationPrompts.maxAlignmentChars),
    );
    final targetText = _AlignmentText(
      PromptSanitizer.prefix(translation, TranslationPrompts.maxAlignmentChars),
    );
    final sourceLength = sourceText.text.length;
    var sourceFrom = 0;
    _Range? previousTarget;
    for (final item in items.take(maxAlignmentPairs)) {
      final (rawSource, rawTarget) = switch (item) {
        final Map<dynamic, dynamic> map => (
          _rawString(map, const [
            'source',
            'src',
            'source_text',
            'original',
            'from',
          ]),
          _rawString(map, const [
            'target',
            'tgt',
            'target_text',
            'translation',
            'to',
          ]),
        ),
        [final String s, final String t, ...] => (s, t),
        _ => (null, null),
      };
      if (rawSource == null || rawTarget == null) continue;
      final from = sourceFrom;
      final inSource = _find(
        sourceText.restoreTags(rawSource),
        sourceText,
        distance: _forwardDistance(from, sourceLength),
        increasingFrom: from,
        forwardFirst: true,
      );
      final near = previousTarget;
      final inTarget = _find(
        targetText.restoreTags(rawTarget),
        targetText,
        distance: _nearDistance(near),
        increasingFrom: near?.end ?? 0,
      );
      if (inSource == null || inTarget == null) continue;
      // Never move back after falling back to an earlier occurrence.
      if (inSource.end > sourceFrom) sourceFrom = inSource.end;
      previousTarget = inTarget;
      sourceText.markUsed(inSource);
      targetText.markUsed(inTarget);
      final span = AlignedSpan(
        sourceStart: inSource.start,
        sourceEnd: inSource.end,
        targetStart: inTarget.start,
        targetEnd: inTarget.end,
      );
      if (seen.add(span)) spans.add(span);
    }
    return spans..sort(
      (a, b) => a.sourceStart != b.sourceStart
          ? a.sourceStart.compareTo(b.sourceStart)
          : a.targetStart.compareTo(b.targetStart),
    );
  }

  /// Longest [MeaningIssue.problem] kept by [parseMeaningCheck].
  static const maxMeaningProblemLength = 300;

  /// Longest [MeaningIssue.suggestion] kept by [parseMeaningCheck].
  static const maxMeaningSuggestionLength = 500;

  /// Longest [MeaningCheck.backTranslation] kept by [parseMeaningCheck].
  static const maxBackTranslationLength = 8000;

  /// Most items of the issue list [parseMeaningCheck] reads (some may be
  /// dropped, so a few more than it keeps).
  static const _maxMeaningItems = 100;

  /// The model's meaning check of [translation] against [source] (see
  /// `TranslationPrompts.meaningCheck`).
  ///
  /// * `back_translation` keeps its lines; control and invisible format
  ///   characters are removed and it is capped at
  ///   [maxBackTranslationLength] characters.
  /// * `verdict` is `same`, `minor` or `major` (also common synonyms such
  ///   as `identical`, `slight`, `significant`). An unknown or missing
  ///   verdict, and `same` when the model listed differences, is
  ///   [MeaningVerdict.fallback] for the types of the listed differences:
  ///   `same` without any, `major` when one is a negation, a number or an
  ///   omission (also an inferred one), else `minor`. A difference counts
  ///   whether or not it can be located, so a reply that lists differences
  ///   is never `same`: an item with a `problem` (without a verdict also a
  ///   plain-text item that is not a note such as `none`); against an
  ///   explicit `same`, only an item with a span (not the prompt's example
  ///   copied with its `...` placeholders, nor a "no differences" note).
  ///   An explicit `minor` or `major` is kept.
  /// * Each issue's `source_span` and `translation_span` are located in
  ///   [source] and [translation] like the phrases of [parseAlignment]
  ///   (exactly, else without edge quotes and punctuation, else ignoring
  ///   case; occurrences at word boundaries first, then occurrences no
  ///   earlier issue took, so repeated spans map to successive
  ///   occurrences; on the source side the next occurrence after the
  ///   previous issue's span, on the translation side the nearest one).
  ///   A blank span (or a note such as `(none)` or `[omitted]` that is not
  ///   in the text) leaves that side unlocated; an issue is dropped when a
  ///   span cannot be located, when neither side is located, when its
  ///   `problem` is blank, or when it repeats an earlier issue (same
  ///   ranges and problem). Issues keep the model's order.
  /// * `problem` and `suggestion` become single lines of at most
  ///   [maxMeaningProblemLength] and [maxMeaningSuggestionLength]
  ///   characters; a suggestion equal to the translation span is dropped.
  ///   `type` is a [MeaningIssueType] (synonyms accepted); an unknown type
  ///   is an omission when only the source side is located, an addition
  ///   when only the translation side is, else `other`.
  /// * At most `TranslationPrompts.maxMeaningIssues` issues are kept, from
  ///   the first [_maxMeaningItems] items, and only the beginnings of the
  ///   texts the prompt sent (`TranslationPrompts.maxMeaningCheckChars`
  ///   characters each) are searched; [MeaningCheck.isPartial] tells
  ///   whether either text was longer.
  ///
  /// The issues may also come as a bare list, and the check wrapped in an
  /// object of its own (`{"result": {...}}`) or in an array
  /// (`[{"verdict": ..., "issues": [...]}]`). An array item is a check
  /// when it has an issue list, or a verdict or back-translation but no
  /// spans and no type; other items are issues. Several checks in an array
  /// are merged: the most severe verdict, the back-translations one per
  /// line, and all issues in array order. Throws a [FormatException] when
  /// the output holds no JSON, or an object with none of the verdict,
  /// back-translation and issue fields.
  static MeaningCheck parseMeaningCheck(
    String output, {
    required String source,
    required String translation,
  }) {
    final value = _extractJson(output);
    final verdicts = <MeaningVerdict>[];
    final backTranslations = <String>[];
    final items = <dynamic>[];
    void addCheck(Map<dynamic, dynamic> check) {
      final (rawVerdict, rawBack, rawIssues) = _meaningFields(check);
      if (_meaningVerdict(rawVerdict) case final verdict?) {
        verdicts.add(verdict);
      }
      final back = switch (rawBack) {
        final String text => text,
        final List<dynamic> lines => _strings(lines).join('\n'),
        _ => '',
      };
      if (back.trim().isNotEmpty) backTranslations.add(back);
      items.addAll(switch (rawIssues) {
        final List<dynamic> list => list,
        final Map<dynamic, dynamic> map => [map],
        _ => const <dynamic>[],
      });
    }

    if (value is Map) {
      addCheck(
        _meaningRoot(value) ??
            (throw FormatException('No meaning check found', output)),
      );
    } else {
      // A bare list of issues, or a check (or several) wrapped in an array.
      for (final item in value as List<dynamic>) {
        if (_arrayCheck(item) case final check?) {
          addCheck(check);
        } else {
          items.add(item);
        }
      }
    }
    final (:issues, :listed) = _meaningIssues(
      items,
      source: source,
      translation: translation,
    );
    // The most severe verdict (the values are ordered by severity).
    final verdict = verdicts.isEmpty
        ? null
        : verdicts.reduce((a, b) => b.index > a.index ? b : a);
    // Against an explicit `same`, only differences with a span count.
    final differences = [
      for (final (:type, :hasSpan) in listed)
        if (verdict == null || hasSpan) type,
    ];
    return MeaningCheck(
      verdict: verdict == null || verdict == MeaningVerdict.same
          ? MeaningVerdict.fallback(
              hasIssues: differences.isNotEmpty,
              issueTypes: differences,
            )
          : verdict,
      backTranslation: PromptSanitizer.multiLine(
        backTranslations.join('\n'),
        maxLength: maxBackTranslationLength,
      ),
      issues: List.unmodifiable(issues),
      isPartial:
          source.length > TranslationPrompts.maxMeaningCheckChars ||
          translation.length > TranslationPrompts.maxMeaningCheckChars,
    );
  }

  /// [map], or the check it wraps as its only value (`{"result": {...}}`);
  /// null when neither has a verdict, back-translation or issue field.
  static Map<dynamic, dynamic>? _meaningRoot(Map<dynamic, dynamic> map) {
    bool isCheck(Map<dynamic, dynamic> m) =>
        _meaningFields(m) != (null, null, null);
    final single = map.length == 1 ? map.values.single : null;
    if (single case final Map<dynamic, dynamic> inner when isCheck(inner)) {
      return inner;
    }
    return isCheck(map) ? map : null;
  }

  /// The check an [item] of an array holds (see [parseMeaningCheck]), or
  /// null when it is an issue (or neither). An issue may carry a severity
  /// or a back-translation of its own, but it has spans or a type and never
  /// an issue list.
  static Map<dynamic, dynamic>? _arrayCheck(Object? item) {
    if (item is! Map) return null;
    final check = _meaningRoot(item);
    if (check == null) return null;
    final (_, _, rawIssues) = _meaningFields(check);
    if (rawIssues is List || rawIssues is Map) return check;
    final issueKeys = _get(check, const [
      ..._sourceSpanKeys,
      ..._translationSpanKeys,
      ..._issueTypeKeys,
    ]);
    return issueKeys == null ? check : null;
  }

  /// The verdict, back-translation and issues of a meaning check [map]
  /// (null when absent).
  static (Object?, Object?, Object?) _meaningFields(
    Map<dynamic, dynamic> map,
  ) => (
    _get(map, const ['verdict', 'result', 'assessment', 'severity', 'rating']),
    _get(map, const [
      'back_translation',
      'backtranslation',
      'reverse_translation',
      'retranslation',
      'round_trip',
    ]),
    _get(map, const [
      'issues',
      'differences',
      'problems',
      'errors',
      'discrepancies',
    ]),
  );

  /// Keys of a meaning issue's fields.
  static const _problemKeys = [
    'problem',
    'explanation',
    'description',
    'issue',
    'reason',
    'note',
  ];
  static const _sourceSpanKeys = [
    'source_span',
    'source',
    'source_text',
    'original',
    'original_span',
  ];
  static const _translationSpanKeys = [
    'translation_span',
    'translation',
    'target_span',
    'target',
    'translated',
  ];
  static const _issueTypeKeys = ['type', 'category', 'kind'];
  static const _suggestionKeys = [
    'suggestion',
    'suggested_translation',
    'correction',
    'corrected',
    'fix',
  ];

  /// The issues of [parseMeaningCheck] that can be located, and every
  /// difference the model listed in [items] (located or not): its type and
  /// whether it has a span (found in its text or not).
  static ({
    List<MeaningIssue> issues,
    List<({MeaningIssueType type, bool hasSpan})> listed,
  })
  _meaningIssues(
    List<dynamic> items, {
    required String source,
    required String translation,
  }) {
    // The model saw only these beginnings; offsets into a prefix are
    // offsets into the whole text.
    final sourceText = _AlignmentText(
      PromptSanitizer.prefix(source, TranslationPrompts.maxMeaningCheckChars),
    );
    final targetText = _AlignmentText(
      PromptSanitizer.prefix(
        translation,
        TranslationPrompts.maxMeaningCheckChars,
      ),
    );
    final sourceLength = sourceText.text.length;
    var sourceFrom = 0;
    _Range? previousTarget;
    final issues = <MeaningIssue>[];
    final listed = <({MeaningIssueType type, bool hasSpan})>[];
    final seen = <(_Range?, _Range?, String)>{};
    for (final item in items.take(_maxMeaningItems)) {
      if (issues.length >= TranslationPrompts.maxMeaningIssues) break;
      if (item is String) {
        // A difference told in prose, without spans.
        if (!_isSpanNote(item)) {
          listed.add((type: MeaningIssueType.other, hasSpan: false));
        }
        continue;
      }
      if (item is! Map) continue;
      final problem = PromptSanitizer.singleLine(
        _string(item, _problemKeys),
        maxLength: maxMeaningProblemLength,
        atWordBoundary: true,
      );
      if (problem.isEmpty) continue;
      final from = sourceFrom;
      final (inSource, sourceMissing) = _spanIn(
        _rawString(item, _sourceSpanKeys),
        sourceText,
        distance: _forwardDistance(from, sourceLength),
        increasingFrom: from,
        forwardFirst: true,
      );
      final near = previousTarget;
      final (inTarget, targetMissing) = _spanIn(
        _rawString(item, _translationSpanKeys),
        targetText,
        distance: _nearDistance(near),
        increasingFrom: near?.end ?? 0,
      );
      // The sides the model gave a span for, found or not.
      final hasSource = inSource != null || sourceMissing;
      final hasTarget = inTarget != null || targetMissing;
      final type = _meaningIssueType(
        _string(item, _issueTypeKeys),
        inSource: hasSource,
        inTranslation: hasTarget,
      );
      listed.add((type: type, hasSpan: hasSource || hasTarget));
      if (sourceMissing ||
          targetMissing ||
          (inSource == null && inTarget == null)) {
        continue;
      }
      if (inSource != null) {
        // Never move back after falling back to an earlier occurrence.
        if (inSource.end > sourceFrom) sourceFrom = inSource.end;
        sourceText.markUsed(inSource);
      }
      if (inTarget != null) {
        previousTarget = inTarget;
        targetText.markUsed(inTarget);
      }
      if (!seen.add((inSource, inTarget, problem.toLowerCase()))) continue;
      final translationSpan = inTarget == null
          ? ''
          : targetText.text.substring(inTarget.start, inTarget.end);
      final suggestion = _noValue(
        PromptSanitizer.singleLine(
          _string(item, _suggestionKeys),
          maxLength: maxMeaningSuggestionLength,
          atWordBoundary: true,
        ),
      );
      issues.add(
        MeaningIssue(
          problem: problem,
          type: type,
          sourceSpan: inSource == null
              ? ''
              : sourceText.text.substring(inSource.start, inSource.end),
          translationSpan: translationSpan,
          suggestion: suggestion == translationSpan ? '' : suggestion,
          sourceStart: inSource?.start,
          sourceEnd: inSource?.end,
          translationStart: inTarget?.start,
          translationEnd: inTarget?.end,
        ),
      );
    }
    return (issues: issues, listed: listed);
  }

  /// Locates the span [raw] of a meaning issue in [text] (see [_find]):
  /// the range, or null with `missing` false when [raw] is blank or a note
  /// such as `(none)` that is not in [text], or null with `missing` true
  /// when a real span cannot be found.
  static (_Range?, bool missing) _spanIn(
    String? raw,
    _AlignmentText text, {
    required int Function(_Range range) distance,
    required int increasingFrom,
    bool forwardFirst = false,
  }) {
    if (raw == null || raw.trim().isEmpty) return (null, false);
    final range = _find(
      text.restoreTags(raw),
      text,
      distance: distance,
      increasingFrom: increasingFrom,
      forwardFirst: forwardFirst,
    );
    if (range != null) return (range, false);
    return (null, !_isSpanNote(raw));
  }

  /// Text in brackets as a whole, e.g. `(not translated)`.
  static final _bracketed = RegExp(r'^\s*[(\[{<（【].*[)\]}>）】]\s*$');

  /// Edge characters ignored when a span is compared with [_spanNotes]
  /// (a trailing run is only tried from its start: linear time).
  static final _noteEdges = RegExp(
    r'''^[\s"'“”‘’«»*_.…:-]+|(?<![\s"'“”‘’«»*_.…:-])[\s"'“”‘’«»*_.…:-]+$''',
  );

  /// What models write instead of a span (lower case).
  static const _spanNotes = {
    'none',
    'null',
    'n/a',
    'na',
    'nothing',
    'empty',
    'missing',
    'omitted',
    'not present',
    'not translated',
    'untranslated',
    'no translation',
    'not applicable',
    '—',
    '–',
  };

  /// Whether [raw] (a span not found in its text) is a note standing for
  /// no span: bracketed, only punctuation, or one of [_spanNotes].
  static bool _isSpanNote(String raw) {
    if (_bracketed.hasMatch(raw)) return true;
    final key = raw.replaceAll(_noteEdges, '').toLowerCase();
    return key.isEmpty || _spanNotes.contains(key);
  }

  /// [value], or empty when it says there is none (`none`, `null`, `n/a`,
  /// `-`).
  static String _noValue(String value) =>
      const {'none', 'null', 'n/a', '-', '—'}.contains(value.toLowerCase())
      ? ''
      : value;

  /// A verdict or issue type as a lower-case key: spaces and hyphens become
  /// `_`, other characters at the ends are dropped.
  static String _meaningKey(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .replaceAll(_meaningKeyEdges, '');

  /// What [_meaningKey] drops at the ends (a trailing run is only tried
  /// from its start: linear time).
  static final _meaningKeyEdges = RegExp(r'^[^a-z]+|(?<![^a-z])[^a-z]+$');

  /// A [MeaningVerdict] from a model's verdict (see [parseMeaningCheck]),
  /// or null.
  static MeaningVerdict? _meaningVerdict(Object? raw) {
    if (raw is! String) return null;
    final key = _meaningKey(raw);
    return MeaningVerdict.byName(key) ?? _verdictSynonyms[key];
  }

  static const _verdictSynonyms = <String, MeaningVerdict>{
    'identical': MeaningVerdict.same,
    'equivalent': MeaningVerdict.same,
    'equal': MeaningVerdict.same,
    'ok': MeaningVerdict.same,
    'okay': MeaningVerdict.same,
    'match': MeaningVerdict.same,
    'matches': MeaningVerdict.same,
    'faithful': MeaningVerdict.same,
    'accurate': MeaningVerdict.same,
    'correct': MeaningVerdict.same,
    'preserved': MeaningVerdict.same,
    'same_meaning': MeaningVerdict.same,
    'no_issues': MeaningVerdict.same,
    'no_difference': MeaningVerdict.same,
    'no_differences': MeaningVerdict.same,
    'pass': MeaningVerdict.same,
    'small': MeaningVerdict.minor,
    'slight': MeaningVerdict.minor,
    'partial': MeaningVerdict.minor,
    'nuance': MeaningVerdict.minor,
    'mostly_same': MeaningVerdict.minor,
    'mostly_preserved': MeaningVerdict.minor,
    'minor_difference': MeaningVerdict.minor,
    'minor_differences': MeaningVerdict.minor,
    'minor_issues': MeaningVerdict.minor,
    'slightly_different': MeaningVerdict.minor,
    'mostly_equivalent': MeaningVerdict.minor,
    'significant': MeaningVerdict.major,
    'substantial': MeaningVerdict.major,
    'changed': MeaningVerdict.major,
    'meaning_changed': MeaningVerdict.major,
    'different': MeaningVerdict.major,
    'wrong': MeaningVerdict.major,
    'incorrect': MeaningVerdict.major,
    'serious': MeaningVerdict.major,
    'severe': MeaningVerdict.major,
    'critical': MeaningVerdict.major,
    'fail': MeaningVerdict.major,
    'mistranslation': MeaningVerdict.major,
    'major_difference': MeaningVerdict.major,
    'major_differences': MeaningVerdict.major,
    'major_issues': MeaningVerdict.major,
  };

  /// A [MeaningIssueType] from a model's type (see [parseMeaningCheck]).
  static MeaningIssueType _meaningIssueType(
    String raw, {
    required bool inSource,
    required bool inTranslation,
  }) {
    final key = _meaningKey(raw);
    final type = MeaningIssueType.byName(key) ?? _issueTypeSynonyms[key];
    if (type != null) return type;
    if (inSource && !inTranslation) return MeaningIssueType.omission;
    if (inTranslation && !inSource) return MeaningIssueType.addition;
    return MeaningIssueType.other;
  }

  static const _issueTypeSynonyms = <String, MeaningIssueType>{
    'omitted': MeaningIssueType.omission,
    'omissions': MeaningIssueType.omission,
    'missing': MeaningIssueType.omission,
    'missing_information': MeaningIssueType.omission,
    'dropped': MeaningIssueType.omission,
    'untranslated': MeaningIssueType.omission,
    'not_translated': MeaningIssueType.omission,
    'deletion': MeaningIssueType.omission,
    'added': MeaningIssueType.addition,
    'additions': MeaningIssueType.addition,
    'extra': MeaningIssueType.addition,
    'insertion': MeaningIssueType.addition,
    'inserted': MeaningIssueType.addition,
    'added_information': MeaningIssueType.addition,
    'negative': MeaningIssueType.negation,
    'negations': MeaningIssueType.negation,
    'negated': MeaningIssueType.negation,
    'polarity': MeaningIssueType.negation,
    'wrong_negation': MeaningIssueType.negation,
    'missing_negation': MeaningIssueType.negation,
    'numbers': MeaningIssueType.number,
    'numeral': MeaningIssueType.number,
    'numeric': MeaningIssueType.number,
    'quantity': MeaningIssueType.number,
    'amount': MeaningIssueType.number,
    'date': MeaningIssueType.number,
    'time': MeaningIssueType.number,
    'unit': MeaningIssueType.number,
    'units': MeaningIssueType.number,
    'plural': MeaningIssueType.number,
    'singular': MeaningIssueType.number,
    'grammatical_number': MeaningIssueType.number,
    'wrong_number': MeaningIssueType.number,
    'tenses': MeaningIssueType.tense,
    'aspect': MeaningIssueType.tense,
    'mood': MeaningIssueType.tense,
    'person': MeaningIssueType.tense,
    'verb_tense': MeaningIssueType.tense,
    'wrong_tense': MeaningIssueType.tense,
    'mistranslated': MeaningIssueType.mistranslation,
    'wrong_meaning': MeaningIssueType.mistranslation,
    'meaning': MeaningIssueType.mistranslation,
    'terminology': MeaningIssueType.mistranslation,
    'term': MeaningIssueType.mistranslation,
    'wrong_term': MeaningIssueType.mistranslation,
    'wrong_word': MeaningIssueType.mistranslation,
    'false_friend': MeaningIssueType.mistranslation,
    'sense': MeaningIssueType.mistranslation,
  };

  /// The distance of an occurrence from the cursor [from] of a text of
  /// [length] characters, for [_find] with `forwardFirst`: the next
  /// occurrence at or after the cursor is nearest, then the nearest one
  /// before it.
  static int Function(_Range range) _forwardDistance(int from, int length) =>
      (r) => r.start >= from ? r.start - from : length + from - r.start;

  /// The distance of an occurrence from [near] (the previous phrase's
  /// range; none: from the start), for [_find]: the occurrence nearest to
  /// it, after it on a tie.
  static int Function(_Range range) _nearDistance(_Range? near) =>
      (r) => near == null
      ? r.start
      : r.start >= near.end
      ? 2 * (r.start - near.end)
      : r.end <= near.start
      ? 2 * (near.start - r.end) + 1
      : 0;

  static final _romanizationLabel = RegExp(
    r'^\s*(?:(?:sure|okay|ok|certainly|of course)[!,.]?\s*)?'
    r'(?:\*\*|__)?'
    "(?:here(?:'s| is) (?:the |your )?)?"
    '(?:romani[sz]ation|romani[sz]ed(?: text| version)?|transliteration'
    '|transliterated text|r[oō]maji|pinyin|jyutping)'
    r'(?: \([^\n)]{1,40}\))?'
    r'\s*(?:(?:\*\*|__)\s*)?[:：]\s*(?:\*\*|__)?[ \t]*(?:\r?\n)?',
    caseSensitive: false,
  );

  /// A source that itself starts with a romanization label word, in the
  /// Latin script or natively (ローマ字, 拼音, 粵拼, ...).
  static final _sourceRomanizationLabel = RegExp(
    r'^\s*(?:\*\*|__)?(?:romani[sz]|transliterat|r[oō]maji|pinyin|jyutping'
    '|ローマ字|ろーまじ|ローマじ|拼音|粵拼|粤拼|羅馬字|罗马字|로마자)',
    caseSensitive: false,
  );

  /// [cleanTranslation] for a romanization of [source], which also drops a
  /// leading "Romanization:" / "Romaji:" / "Pinyin:" (...) label, unless
  /// [source] starts with such a word itself (`ローマ字：…` romanizes to
  /// `Rōmaji: …`, and a learner's note may start with `Pinyin:`).
  static String cleanRomanization(String output, {required String source}) {
    final text = cleanTranslation(output, source: source);
    if (_sourceRomanizationLabel.hasMatch(source)) return text;
    final match = _romanizationLabel.firstMatch(text);
    if (match == null) return text;
    final rest = text.substring(match.end).trim();
    return rest.isEmpty ? text : cleanTranslation(rest, source: source);
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
      summary: _proofreadSummary(root),
    );
  }

  /// The summary. Some models split it into a list, of sentences or of
  /// bullet fragments: an item that ends a sentence is followed by a space
  /// (nothing after a full-width `。`, `！` or `？`), a fragment by `; `,
  /// so fragments do not run together.
  static String _proofreadSummary(Map<dynamic, dynamic> root) {
    const keys = ['summary', 'analysis', 'feedback'];
    if (_get(root, keys) case final List<dynamic> list) {
      final items = _strings(list);
      final summary = StringBuffer();
      for (final (index, item) in items.indexed) {
        if (index > 0) summary.write(_separatorAfter(items[index - 1]));
        summary.write(item);
      }
      return summary.toString();
    }
    return _string(root, keys);
  }

  /// What separates a summary [item] from the next one.
  static String _separatorAfter(String item) {
    if (_fullWidthSentenceEnd.hasMatch(item)) return '';
    return _sentenceEnd.hasMatch(item) ? ' ' : '; ';
  }

  /// Sentence-final punctuation, then any closing quotes or brackets.
  static final _sentenceEnd = RegExp(r'''[.!?…‽。！？؟।॥۔։။។።]["'”’»)\]」』）]*$''');
  static final _fullWidthSentenceEnd = RegExp(r'[。！？][」』”’）]*$');

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
    // Tried from the start of a run of spaces only (linear time).
    '(?<!\\s)\\s*\\[\\[\\s*$_keyword$_codePattern\\s*\\]\\]\\s*\$',
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
    // Only the end of the text matters (and the marker must follow text).
    final window = s.substring(
      s.length > _maxMarkerLength ? s.length - _maxMarkerLength : 1,
    );
    for (
      var i = window.lastIndexOf('[');
      i >= 0;
      i = i == 0 ? -1 : window.lastIndexOf('[', i - 1)
    ) {
      final tail = window.substring(i);
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
      final inner = _translationContent(t);
      if (inner != null && inner.trim().isNotEmpty) {
        t = inner.trim();
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
            // Spaces before the closing tag are only tried from their start
            // (linear time).
            RegExp(
              '\\r?\\n?(?<![ \\t])[ \\t]*</$tag>\\s*\$',
              caseSensitive: false,
            ),
            '',
          );
    }
    return t.trim().isEmpty ? text : t;
  }

  /// The start of an opening `<translation>` tag (with or without
  /// attributes).
  static final _translationOpening = RegExp(
    r'<translation(?=[\s>])',
    caseSensitive: false,
  );

  static final _translationClosing = RegExp(
    '</translation>',
    caseSensitive: false,
  );

  /// What the first match of the case-insensitive
  /// `<translation(?:\s[^>]*)?>([\s\S]*?)</translation>` in [text]
  /// captures, or null when there is none, in linear time (that expression
  /// scans the rest of the text again from each opening tag that no
  /// closing tag follows): the text between the end of the first opening
  /// tag and the first closing tag after it. When the first opening tag is
  /// not followed by a closing tag, no later one is.
  static String? _translationContent(String text) {
    final opening = _translationOpening.firstMatch(text);
    if (opening == null) return null;
    final close = text.indexOf('>', opening.end);
    if (close < 0) return null;
    final closing = _translationClosing.allMatches(text, close + 1).firstOrNull;
    return closing == null ? null : text.substring(close + 1, closing.start);
  }

  static final _labelPattern = RegExp(
    r'^\s*(?:(?:sure|okay|ok|certainly|of course)[!,.]?\s*)?'
    r'(?:\*\*|__)?'
    "(?:here(?:'s| is) (?:the |your |my )?(?:translation|translated text|"
    r'rewritten text|improved text)[^\n:：]{0,60}'
    r'|(?:the )?translation(?: in(?:to)? [^\n:：]{1,40}| \([^\n)]{1,40}\))?'
    '|translated text)'
    r'\s*(?:(?:\*\*|__)\s*)?[:：]\s*(?:\*\*|__)?[ \t]*(?:\r?\n)?',
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
    r"^\s*(?:[(\[]\s*)?(?:\*\*|__|\*|_)?(?:note|translator'?s? note|n\.b\.)"
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

  /// [text] without reasoning blocks (`<think>…</think>`; also
  /// `thinking`, `reasoning` and `thought`), without what comes before the
  /// last closing tag (its opening tag was swallowed by the server) and
  /// without an unterminated block (cut off by a token limit).
  static String _stripThink(String text) {
    var s = _withoutThinkBlocks(text);
    // A closing tag whose opening tag was swallowed by the server.
    final closing = _thinkClosing.allMatches(s).lastOrNull;
    if (closing != null) s = s.substring(closing.end);
    // An unterminated block (e.g. cut off by a token limit): an opening tag
    // ends at the first `>` after its name.
    final opening = _thinkOpening.firstMatch(s);
    if (opening != null && s.contains('>', opening.end)) {
      s = s.substring(0, opening.start);
    }
    return s;
  }

  static const _thinkTags = 'think|thinking|reasoning|thought';

  /// The start of an opening reasoning tag, with its name.
  static final _thinkOpening = RegExp(
    '<($_thinkTags)\\b',
    caseSensitive: false,
  );

  /// A closing reasoning tag, with its name.
  static final _thinkClosing = RegExp(
    '</($_thinkTags)\\s*>',
    caseSensitive: false,
  );

  /// [text] with every reasoning block removed, as `text.replaceAll(
  /// RegExp('<($_thinkTags)\\b[^>]*>[\\s\\S]*?</\\1\\s*>', caseSensitive:
  /// false), '')` would, in linear time (that expression scans the rest of
  /// the text again from each opening tag that no closing tag follows): an
  /// opening tag ends at the first `>` after its name, and its block at the
  /// first closing tag with the same name after that.
  static String _withoutThinkBlocks(String text) {
    final closings = <String, List<Match>>{};
    for (final closing in _thinkClosing.allMatches(text)) {
      (closings[closing.group(1)!.toLowerCase()] ??= []).add(closing);
    }
    if (closings.isEmpty) return text;
    // The next closing tag of each name that may end a block (blocks start
    // further and further into the text).
    final next = <String, int>{};
    final buffer = StringBuffer();
    var kept = 0;
    var close = -1;
    for (final opening in _thinkOpening.allMatches(text)) {
      if (opening.start < kept) continue;
      final name = opening.group(1)!.toLowerCase();
      final ends = closings[name];
      if (ends == null) continue;
      if (close < opening.end) close = text.indexOf('>', opening.end);
      if (close < 0) break;
      var i = next[name] ?? 0;
      while (i < ends.length && ends[i].start <= close) {
        i++;
      }
      next[name] = i;
      if (i == ends.length) continue;
      buffer.write(text.substring(kept, opening.start));
      kept = ends[i].end;
    }
    if (kept == 0) return text;
    return (buffer..write(text.substring(kept))).toString();
  }

  /// A fenced code block. The info string is matched whole, so that an
  /// unclosed fence is not scanned to the end again from each shorter one
  /// (linear time).
  static final _jsonFence = RegExp(
    r'```[\w-]*(?![\w-])[ \t]*(?![ \t])\r?\n?([\s\S]*?)```',
  );

  static Object? _findJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (_acceptable(_decode(trimmed)) case final value?) return value;

    for (final fence in _jsonFence.allMatches(trimmed)) {
      final inner = fence.group(1)!.trim();
      if (_acceptable(_decode(inner)) case final value?) return value;
    }

    // The first object or array that decodes, found with one pass over
    // the brackets ([_scanBrackets]); with a second one that ignores
    // quotes when quotes in prose may have hidden it.
    return _searchBrackets(trimmed, strings: true) ??
        (trimmed.contains('"')
            ? _searchBrackets(trimmed, strings: false)
            : null);
  }

  /// The first acceptable value ([_acceptable]) among the bracket spans of
  /// [s], in the order they start: a balanced span is decoded (and
  /// repaired); one that decodes is searched for its first acceptable
  /// value ([_firstAcceptable]), one that does not is looked into
  /// ([_firstInSpan]). An opening bracket that is never closed may be
  /// output truncated by a token limit: what is open is closed and an
  /// incomplete tail dropped ([_decodeTruncated]), for the first
  /// [_truncatedCandidates] of them (with [strings] only).
  ///
  /// Linear time also for hostile replies (mostly brackets, nested ones
  /// that never decode): the scan is one pass, the outermost balanced
  /// spans are disjoint (each character is decoded once), a decoded value
  /// is searched instead of the spans inside it, and looking into spans
  /// that do not decode is bounded by [_searchWork]: only valid JSON
  /// nested in dozens of brackets that do not decode is missed.
  static Object? _searchBrackets(String s, {required bool strings}) {
    final work = _Work(_searchWork * s.length + _searchWorkBase);
    var truncated = 0;
    for (final (span, :closed) in _scanBrackets(s, strings: strings)) {
      if (closed) {
        if (_firstInSpan(s, span, work) case final value?) return value;
        continue;
      }
      if (!strings ||
          !_isCandidate(s, span.start) ||
          truncated++ >= _truncatedCandidates) {
        continue;
      }
      final (:value, cost: _) = _decodeTruncated(s.substring(span.start));
      if (_firstAcceptable(value) case final found?) return found;
    }
    return null;
  }

  /// The bracket spans of [s], in one pass with a stack, in the order they
  /// start: the outermost balanced spans (`closed`, with the balanced
  /// spans inside them as [_Span.children]) and the brackets still open at
  /// the end (not `closed`), each followed by the balanced spans directly
  /// inside it.
  ///
  /// With [strings], quotes inside brackets start and end strings (with
  /// `\` escapes), whose brackets do not count; quotes outside brackets
  /// are prose. A closing bracket that does not match the innermost open
  /// one ends every open bracket (no candidate: neither balanced nor
  /// truncated); the balanced spans inside them stay.
  static List<(_Span, {bool closed})> _scanBrackets(
    String s, {
    required bool strings,
  }) {
    final spans = <(_Span, {bool closed})>[];
    final open = <_Span>[];
    void abandon() {
      for (final span in open) {
        for (final child in span.children) {
          spans.add((child, closed: true));
        }
      }
      open.clear();
    }

    var inString = false;
    for (var i = 0; i < s.length; i++) {
      final unit = s.codeUnitAt(i);
      if (inString) {
        if (unit == _backslash) {
          i++;
        } else if (unit == _quote) {
          inString = false;
        }
        continue;
      }
      switch (unit) {
        case _quote when strings && open.isNotEmpty:
          inString = true;
        case _openBrace || _openBracket:
          open.add(_Span(i));
        case _closeBrace || _closeBracket when open.isNotEmpty:
          final span = open.last;
          final opener = s.codeUnitAt(span.start);
          if ((opener == _openBrace) != (unit == _closeBrace)) {
            abandon();
            continue;
          }
          open.removeLast();
          span.end = i;
          if (open.isEmpty) {
            spans.add((span, closed: true));
          } else {
            open.last.children.add(span);
          }
      }
    }
    for (final span in open) {
      spans
        ..add((span, closed: false))
        ..addAll([for (final child in span.children) (child, closed: true)]);
    }
    return spans;
  }

  static const _quote = 0x22;
  static const _backslash = 0x5C;
  static const _openBrace = 0x7B;
  static const _closeBrace = 0x7D;
  static const _openBracket = 0x5B;
  static const _closeBracket = 0x5D;

  /// The first acceptable value of the balanced [root] span of [s] or the
  /// spans inside it, in the order they start: a span that decodes gives
  /// its first acceptable value ([_firstAcceptable]) or nothing (the spans
  /// inside it are parts of that value); the spans inside one that cannot
  /// start JSON or does not decode are tried next, while [work] lasts.
  static Object? _firstInSpan(String s, _Span root, _Work work) {
    final pending = [root];
    while (pending.isNotEmpty) {
      final span = pending.removeLast();
      if (_isCandidate(s, span.start)) {
        final length = span.end + 1 - span.start;
        // The outermost spans do not overlap: each is decoded once.
        if (!identical(span, root)) {
          // A decode, its repair and a second decode.
          if ((work.left -= 3 * length) < 0) return null;
        }
        final value = _decode(s.substring(span.start, span.end + 1));
        if (value != null) {
          if (_firstAcceptable(value) case final found?) return found;
          continue;
        }
      }
      if ((work.left -= span.children.length) < 0) return null;
      pending.addAll(span.children.reversed);
    }
    return null;
  }

  /// The first acceptable value ([_acceptable]) of [value] and the values
  /// inside it, in the order they appear in its JSON (an outer value
  /// first). Without recursion: deeply nested values are fine.
  static Object? _firstAcceptable(Object? value) {
    final pending = [value];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (_acceptable(next) case final found?) return found;
      switch (next) {
        case final Map<dynamic, dynamic> map:
          pending.addAll(map.values.toList().reversed);
        case final List<dynamic> list:
          pending.addAll(list.reversed);
      }
    }
    return null;
  }

  /// Whether the bracket at [index] of [s] may start JSON: a `[`, or a `{`
  /// that [_mayStartObject].
  static bool _isCandidate(String s, int index) =>
      s.codeUnitAt(index) == _openBracket || _mayStartObject(s, index);

  /// Characters of work [_firstInSpan] may spend, per character of the
  /// reply (plus [_searchWorkBase]), looking into spans that do not decode.
  static const int _searchWork = 48;
  static const int _searchWorkBase = 1 << 16;

  /// How many brackets left open [_searchBrackets] tries as truncated
  /// output (each costs a few decodes of the rest of the reply).
  static const _truncatedCandidates = 3;

  /// Whether the `{` at [start] may begin an object that decodes (also
  /// after [_repair]): a key in quotes (straight or smart) or `}` follows
  /// it, after spaces. A `{` followed by anything else (another `{`, a
  /// word, the end) is no candidate, so a reply full of them costs
  /// nothing.
  static bool _mayStartObject(String s, int start) {
    var i = start + 1;
    while (i < s.length && _isJsonSpace(s.codeUnitAt(i))) {
      i++;
    }
    if (i >= s.length) return false;
    final next = s[i];
    return next == '"' || next == '}' || _smartOpen.contains(next);
  }

  static bool _isJsonSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

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
      i == 0 || !_wordCharacter.hasMatch(s[i - 1]);

  static final _wordCharacter = RegExp(r'\w');

  static (String, String)? _pythonLiteral(String s, int i) {
    for (final (python, json) in const [
      ('True', 'true'),
      ('False', 'false'),
      ('None', 'null'),
    ]) {
      if (s.startsWith(python, i)) {
        final after = i + python.length;
        if (after >= s.length || !_wordCharacter.hasMatch(s[after])) {
          return (python, json);
        }
      }
    }
    return null;
  }

  /// Closes an unterminated JSON prefix, retrying at the last
  /// [_truncatedCuts] commas and closed brackets so a half-written
  /// trailing element is dropped: the value (null when no attempt
  /// decodes) and the characters of work it took. The open brackets are
  /// a linked stack, so a cut keeps the brackets open there without
  /// copying them (linear time also for deeply nested prefixes).
  static ({Object? value, int cost}) _decodeTruncated(String s) {
    final cuts = ListQueue<(int, _OpenBracket)>();
    _OpenBracket? open;
    void cut(int index, _OpenBracket brackets) {
      cuts.addLast((index, brackets));
      if (cuts.length > _truncatedCuts) cuts.removeFirst();
    }

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
          open = _OpenBracket('}', open);
        case '[':
          open = _OpenBracket(']', open);
        case '}' || ']':
          final below = open?.below;
          // Unbalanced, or balanced (not truncated).
          if (below == null) return (value: null, cost: i + 1);
          open = below;
          cut(i + 1, below);
        case ',':
          if (open case final brackets?) cut(i, brackets);
      }
    }
    if (open == null) return (value: null, cost: s.length);
    var cost = s.length;
    final attempts = [
      (inString ? '$s"' : s, open),
      for (final (index, below) in cuts.toList().reversed)
        (s.substring(0, index), below),
    ];
    for (final (prefix, brackets) in attempts) {
      final attempt = brackets.close(prefix);
      // A decode, its repair and a second decode.
      cost += 3 * attempt.length;
      final value = _decode(attempt);
      if (value is Map && value.isNotEmpty) return (value: value, cost: cost);
      if (value is List && value.isNotEmpty) return (value: value, cost: cost);
    }
    return (value: null, cost: cost);
  }

  /// How many earlier cut points [_decodeTruncated] tries.
  static const _truncatedCuts = 12;

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
      for (final part in s.split(_listSeparator))
        if (part.trim().isNotEmpty) part.trim(),
    ],
    _ => const [],
  };

  /// What separates the items of a list written as one string (the items
  /// are trimmed).
  static final _listSeparator = RegExp('[,;、，]');

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

  /// Quotes and emphasis at the ends of a span (a trailing run is only
  /// tried from its start: linear time).
  static final _edgePunctuation = RegExp(
    '^["\'“”„«»‘’「」『』*]+|(?<!["\'“”„«»‘’「」『』*])["\'“”„«»‘’「」『』*]+\$',
  );

  /// The best occurrence of [needle] in [haystack] (see [parseAlignment]):
  /// [needle] trimmed, else without edge quotes/punctuation, else ignoring
  /// case. Occurrences at word boundaries rank first, then those that
  /// overlap no range an earlier pair took; ties go to the smallest
  /// [distance].
  ///
  /// [distance] must grow with the start of occurrences that start at or
  /// after [increasingFrom], so the search stops at the first of them that
  /// cannot beat the best one so far. With [forwardFirst], occurrences
  /// that start at or after [increasingFrom] must also be nearer than any
  /// before it: the first top-ranked one there is then the best, and
  /// earlier text is only searched when there is none.
  static _Range? _find(
    String needle,
    _AlignmentText haystack, {
    required int Function(_Range range) distance,
    required int increasingFrom,
    bool forwardFirst = false,
  }) {
    final text = haystack.text;
    final trimmed = needle.trim();
    if (trimmed.isEmpty) return null;
    final bare = trimmed.replaceAll(_edgePunctuation, '').trim();
    final patterns = <(String, bool)>[
      (trimmed, false),
      if (bare.isNotEmpty && bare != trimmed) (bare, false),
      // Matches in [haystack] itself, so offsets stay valid even where
      // lower-casing would change the length (e.g. 'İ').
      if (bare.isNotEmpty) (bare, true),
    ];
    for (final (pattern, ignoreCase) in patterns) {
      if (forwardFirst) {
        _Range? first;
        _forEachOccurrence(
          text,
          pattern,
          ignoreCase: ignoreCase,
          start: increasingFrom,
          (range) {
            if (!haystack.atWordBoundaries(range) || haystack.isUsed(range)) {
              return true;
            }
            first = range;
            return false;
          },
        );
        if (first != null) return first;
      }
      _Range? best;
      var bestRank = 0;
      var bestDistance = 0;
      _forEachOccurrence(text, pattern, ignoreCase: ignoreCase, (range) {
        final d = distance(range);
        // Later occurrences are only farther away.
        if (best != null &&
            bestRank == 0 &&
            range.start >= increasingFrom &&
            d >= bestDistance) {
          return false;
        }
        final rank =
            (haystack.atWordBoundaries(range) ? 0 : 2) +
            (haystack.isUsed(range) ? 1 : 0);
        if (best == null ||
            rank < bestRank ||
            (rank == bestRank && d < bestDistance)) {
          best = range;
          bestRank = rank;
          bestDistance = d;
        }
        return true;
      });
      if (best != null) return best;
    }
    return null;
  }

  /// Calls [visit] with each non-overlapping occurrence of [needle] in
  /// [text] that starts at or after [start], in order, until it returns
  /// false. Exact occurrences are found with [String.indexOf]; with
  /// [ignoreCase] a case-insensitive [RegExp] (simple case mappings) is
  /// used.
  static void _forEachOccurrence(
    String text,
    String needle,
    bool Function(_Range range) visit, {
    required bool ignoreCase,
    int start = 0,
  }) {
    if (ignoreCase) {
      final pattern = RegExp(RegExp.escape(needle), caseSensitive: false);
      for (final match in pattern.allMatches(text, start)) {
        if (!visit((start: match.start, end: match.end))) return;
      }
      return;
    }
    for (
      var i = text.indexOf(needle, start);
      i >= 0;
      i = text.indexOf(needle, i + needle.length)
    ) {
      if (!visit((start: i, end: i + needle.length))) return;
    }
  }

  /// Letters, marks, digits and `_`.
  static final _wordChar = RegExp(r'[\p{L}\p{M}\p{N}_]', unicode: true);

  /// Scripts written without spaces between words.
  static final _unspacedScript = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
    r'\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}'
    r'\p{Script=Tibetan}]',
    unicode: true,
  );

  /// Whether a word continues across [index] of [text]: a word character
  /// of a script with spaces on both sides. In scripts written without
  /// spaces no position joins a word.
  static bool _joinsWord(String text, int index) {
    final before = _charBefore(text, index);
    final after = _charAt(text, index);
    return before != null &&
        after != null &&
        _isSpacedWordChar(before) &&
        _isSpacedWordChar(after);
  }

  static bool _isSpacedWordChar(String char) =>
      _wordChar.hasMatch(char) && !_unspacedScript.hasMatch(char);

  /// The character (code point) that ends at [index] of [s], or null.
  static String? _charBefore(String s, int index) {
    if (index <= 0) return null;
    if (index >= 2 &&
        _isLowSurrogate(s.codeUnitAt(index - 1)) &&
        _isHighSurrogate(s.codeUnitAt(index - 2))) {
      return s.substring(index - 2, index);
    }
    return s.substring(index - 1, index);
  }

  /// The character (code point) that starts at [index] of [s], or null.
  static String? _charAt(String s, int index) {
    if (index >= s.length) return null;
    if (index + 1 < s.length &&
        _isHighSurrogate(s.codeUnitAt(index)) &&
        _isLowSurrogate(s.codeUnitAt(index + 1))) {
      return s.substring(index, index + 2);
    }
    return s.substring(index, index + 1);
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  static List<String> _distinct(List<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (seen.add(value.toLowerCase())) value,
    ];
  }

  static String? _didYouMean(Object? value, {required String query}) {
    final raw = switch (value) {
      final String s => s,
      final List<dynamic> l => _strings(l).firstOrNull ?? '',
      _ => '',
    };
    final text = PromptSanitizer.singleLine(
      raw,
      maxLength: maxDidYouMeanLength,
      stripQuotes: true,
      stripAngleBrackets: true,
    );
    final key = text.toLowerCase();
    if (key.isEmpty ||
        const {'null', 'none', 'n/a', '-', 'false'}.contains(key) ||
        key == query.trim().toLowerCase()) {
      return null;
    }
    return text;
  }

  static final _groupChars = RegExp('[^a-z0-9_-]');

  /// A sanitised [RefinementSuggestion.exclusiveGroup], or null.
  static String? _group(String raw) {
    final key = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    final group = key.replaceAll(_groupChars, '');
    if (group.isEmpty || const {'null', 'none', 'false'}.contains(group)) {
      return null;
    }
    return group.length > 30 ? group.substring(0, 30) : group;
  }

  static String? _groupOfIcon(String icon) => switch (icon) {
    'formal' || 'casual' => RefinementSuggestion.formalityGroup,
    'shorter' || 'longer' => RefinementSuggestion.lengthGroup,
    _ => null,
  };

  /// A sanitised [RefinementSuggestion.instruction] (see [parseSuggestions]).
  static String _instruction(String raw) => PromptSanitizer.singleLine(
    raw,
    maxLength: maxSuggestionInstructionLength,
    stripAngleBrackets: true,
    atWordBoundary: true,
  );

  /// Quotes and emphasis before a language code, and those or a full stop
  /// after it. What follows leading quotes is dropped with them when it is
  /// all trailing characters; any other trailing run is only tried from
  /// its start (linear time).
  static final _codeEdges = RegExp(
    '^["\'`*]+(?:["\'`*.]*\$)?|(?<!["\'`*.])["\'`*.]+\$',
  );

  /// A catalogue code for a code or English language name; empty for
  /// placeholders (see [isPlaceholderLanguageCode]).
  static String _languageCode(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    final marker = splitLanguageMarker(s).language;
    if (marker != null) return marker;
    s = s.replaceAll(_codeEdges, '').trim();
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

/// A range of character offsets, end exclusive.
typedef _Range = ({int start, int end});

/// One side of an alignment for [ResponseParsers.parseAlignment]: the
/// searched [text], the characters earlier pairs took and memoised word
/// boundaries, so locating a phrase costs time linear in [text] however
/// many pairs came before.
final class _AlignmentText {
  new(this.text)
    : _used = Uint8List(text.length),
      _joins = Int8List(text.length + 1)..fillRange(0, text.length + 1, -1),
      _restore = !text.contains(_defused);

  static const _defused = '<${PromptSanitizer.zeroWidthSpace}';

  /// The searched text.
  final String text;

  /// 1 for every character an earlier pair took.
  final Uint8List _used;

  /// Per position: -1 unknown, 0 no word continues across it, 1 one does.
  final Int8List _joins;

  /// Whether tags defused in the prompt are restored in phrases (see
  /// [PromptSanitizer.restoreTags]).
  final bool _restore;

  /// [phrase] with tags defused in the prompt restored.
  String restoreTags(String phrase) =>
      _restore ? phrase.replaceAll(_defused, '<') : phrase;

  /// Whether no word continues across either end of [range]. In scripts
  /// written without spaces every position counts as a boundary.
  bool atWordBoundaries(_Range range) =>
      !_joinsAt(range.start) && !_joinsAt(range.end);

  bool _joinsAt(int index) {
    var joins = _joins[index];
    if (joins < 0) {
      joins = ResponseParsers._joinsWord(text, index) ? 1 : 0;
      _joins[index] = joins;
    }
    return joins == 1;
  }

  /// Whether [range] overlaps a range an earlier pair took.
  bool isUsed(_Range range) {
    for (var i = range.start; i < range.end; i++) {
      if (_used[i] != 0) return true;
    }
    return false;
  }

  /// Records that a pair took [range].
  void markUsed(_Range range) => _used.fillRange(range.start, range.end, 1);
}

/// A bracket still open in a JSON prefix (see
/// `ResponseParsers._decodeTruncated`): its closing character and the
/// brackets open below it. Immutable, so a cut point keeps the brackets
/// open there.
/// A bracket span of a reply (see `ResponseParsers._scanBrackets`): from
/// the bracket at [start] to the one at [end] that closes it (-1 while
/// it is open), with the balanced spans directly inside it.
final class _Span {
  new(this.start);

  final int start;
  int end = -1;
  final List<_Span> children = [];
}

/// Work left to a search (see `ResponseParsers._firstInSpan`).
final class _Work {
  new(this.left);

  int left;
}

final class _OpenBracket {
  const new(this.closer, this.below);

  final String closer;
  final _OpenBracket? below;

  /// [prefix] with this bracket and the ones below it closed.
  String close(String prefix) {
    final buffer = StringBuffer(prefix);
    for (_OpenBracket? open = this; open != null; open = open.below) {
      buffer.write(open.closer);
    }
    return buffer.toString();
  }
}
