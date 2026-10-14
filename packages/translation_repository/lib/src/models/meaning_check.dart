import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const _issueList = ListEquality<MeaningIssue>();

/// How far the meaning of a translation departs from its original
/// ([MeaningCheck.verdict]).
enum MeaningVerdict {
  /// The meaning is fully preserved.
  same,

  /// Small differences that barely change the message (a nuance, a
  /// detail).
  minor,

  /// The translation says something different, leaves out or adds
  /// important information, or could mislead the reader.
  major;

  /// The verdict whose [name] is [name] (ignoring case and surrounding
  /// space), or null.
  static MeaningVerdict? byName(String? name) {
    final key = name?.trim().toLowerCase() ?? '';
    return values.firstWhereOrNull((verdict) => verdict.name == key);
  }

  /// The verdict to assume when none (or an unknown one) was given: [same]
  /// without issues; with issues, [major] when one of [issueTypes] (the
  /// types of those issues) changes the facts (a lost or added negation, a
  /// wrong number, something left out), else [minor].
  static MeaningVerdict fallback({
    required bool hasIssues,
    Iterable<MeaningIssueType> issueTypes = const [],
  }) => !hasIssues
      ? same
      : issueTypes.any(_factualTypes.contains)
      ? major
      : minor;

  /// Issue types that change what a text states.
  static const Set<MeaningIssueType> _factualTypes = {
    MeaningIssueType.negation,
    MeaningIssueType.number,
    MeaningIssueType.omission,
  };
}

/// What kind of meaning difference a [MeaningIssue] is.
enum MeaningIssueType {
  /// Something in the original that the translation leaves out.
  omission,

  /// Something in the translation that is not in the original.
  addition,

  /// A negation that is lost, added or misplaced.
  negation,

  /// A wrong number, quantity, amount, date, time or unit, or grammatical
  /// number (singular instead of plural or the reverse).
  number,

  /// A wrong tense, aspect, mood or person (who does what to whom).
  tense,

  /// A word or term translated with the wrong meaning (a false friend, the
  /// wrong sense of an ambiguous word).
  mistranslation,

  /// Any other difference in meaning.
  other;

  /// The type whose [name] is [name] (ignoring case and surrounding space),
  /// or null.
  static MeaningIssueType? byName(String? name) {
    final key = name?.trim().toLowerCase() ?? '';
    return values.firstWhereOrNull((type) => type.name == key);
  }
}

/// One difference in meaning between an original text and its translation,
/// found by `TranslationRepository.checkMeaning`.
///
/// [sourceSpan] and [translationSpan] are exact substrings of the checked
/// texts, at the character ranges (UTF-16 code unit offsets, like
/// [String.substring]; starts inclusive, ends exclusive) [sourceStart] ..
/// [sourceEnd] and [translationStart] .. [translationEnd]. An issue may be
/// located in one text only: an omission usually has no [translationSpan]
/// and an addition no [sourceSpan]; the offsets of a missing side are null
/// (both or neither are set).
@immutable
class MeaningIssue {
  const new({
    required this.problem,
    this.type = MeaningIssueType.other,
    this.sourceSpan = '',
    this.translationSpan = '',
    this.suggestion = '',
    this.sourceStart,
    this.sourceEnd,
    this.translationStart,
    this.translationEnd,
  }) : assert(
         (sourceStart == null) == (sourceEnd == null),
         'sourceStart and sourceEnd are set together',
       ),
       assert(
         (translationStart == null) == (translationEnd == null),
         'translationStart and translationEnd are set together',
       );

  /// Reads the [toJson] keys; also accepts snake_case keys
  /// (`source_span`, `translation_start`, ...). Missing texts are empty and
  /// an unknown [type] is [MeaningIssueType.other].
  ///
  /// Throws a [FormatException] when a text is not a string, or the
  /// offsets of a side are not both absent (or null) or both present,
  /// non-negative integers whose range has the length of that side's span.
  factory fromJson(Map<String, dynamic> json) {
    Object? read(String key, String snake) => json[key] ?? json[snake];

    String text(String key, String snake) => switch (read(key, snake)) {
      null => '',
      final String value => value,
      final value => throw FormatException('Invalid MeaningIssue.$key', value),
    };

    int? offset(String key, String snake) => switch (read(key, snake)) {
      null => null,
      final int value when value >= 0 => value,
      final num value when value >= 0 && value == value.truncate() =>
        value.toInt(),
      final value => throw FormatException('Invalid MeaningIssue.$key', value),
    };

    (int?, int?) range(String side, String span) {
      final start = offset('${side}Start', '${side}_start');
      final end = offset('${side}End', '${side}_end');
      if (start == null && end == null) return (null, null);
      if (start == null || end == null || end - start != span.length) {
        throw FormatException('Invalid MeaningIssue $side range', json);
      }
      return (start, end);
    }

    final sourceSpan = text('sourceSpan', 'source_span');
    final translationSpan = text('translationSpan', 'translation_span');
    final (sourceStart, sourceEnd) = range('source', sourceSpan);
    final (translationStart, translationEnd) = range(
      'translation',
      translationSpan,
    );
    final type = read('type', 'type');
    return MeaningIssue(
      problem: text('problem', 'problem'),
      type:
          MeaningIssueType.byName(type is String ? type : null) ??
          MeaningIssueType.other,
      sourceSpan: sourceSpan,
      translationSpan: translationSpan,
      suggestion: text('suggestion', 'suggestion'),
      sourceStart: sourceStart,
      sourceEnd: sourceEnd,
      translationStart: translationStart,
      translationEnd: translationEnd,
    );
  }

  /// What differs, in the UI language of the check (one line).
  final String problem;

  final MeaningIssueType type;

  /// The affected words of the original text; empty when the issue is not
  /// located there (e.g. an addition).
  final String sourceSpan;

  /// The affected words of the translation; empty when the issue is not
  /// located there (e.g. an omission).
  final String translationSpan;

  /// A corrected wording, in the target language, to replace
  /// [translationSpan] with (for an omission: the words to add); empty when
  /// the model gave none. Model output: show it, never apply it without a
  /// user action.
  final String suggestion;

  /// Start of [sourceSpan] in the original text (inclusive), or null.
  final int? sourceStart;

  /// End of [sourceSpan] in the original text (exclusive), or null.
  final int? sourceEnd;

  /// Start of [translationSpan] in the translation (inclusive), or null.
  final int? translationStart;

  /// End of [translationSpan] in the translation (exclusive), or null.
  final int? translationEnd;

  /// Whether the issue is located in the original text.
  bool get hasSourceRange => sourceStart != null;

  /// Whether the issue is located in the translation.
  bool get hasTranslationRange => translationStart != null;

  /// Whether [sourceSpan] covers the character at [offset] of the original.
  bool coversSource(int offset) =>
      sourceStart != null && offset >= sourceStart! && offset < sourceEnd!;

  /// Whether [translationSpan] covers the character at [offset] of the
  /// translation.
  bool coversTranslation(int offset) =>
      translationStart != null &&
      offset >= translationStart! &&
      offset < translationEnd!;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'problem': problem,
    'sourceSpan': sourceSpan,
    'translationSpan': translationSpan,
    'suggestion': suggestion,
    if (sourceStart != null) 'sourceStart': sourceStart,
    if (sourceEnd != null) 'sourceEnd': sourceEnd,
    if (translationStart != null) 'translationStart': translationStart,
    if (translationEnd != null) 'translationEnd': translationEnd,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeaningIssue &&
          other.problem == problem &&
          other.type == type &&
          other.sourceSpan == sourceSpan &&
          other.translationSpan == translationSpan &&
          other.suggestion == suggestion &&
          other.sourceStart == sourceStart &&
          other.sourceEnd == sourceEnd &&
          other.translationStart == translationStart &&
          other.translationEnd == translationEnd;

  @override
  int get hashCode => Object.hash(
    problem,
    type,
    sourceSpan,
    translationSpan,
    suggestion,
    sourceStart,
    sourceEnd,
    translationStart,
    translationEnd,
  );

  @override
  String toString() =>
      'MeaningIssue(${type.name}, '
      '${sourceStart ?? '-'}-${sourceEnd ?? '-'} -> '
      '${translationStart ?? '-'}-${translationEnd ?? '-'})';
}

/// The result of a meaning check (`TranslationRepository.checkMeaning`): the
/// model translated the translation back into the source language and
/// compared its meaning with the original text.
@immutable
class MeaningCheck {
  const new({
    required this.verdict,
    this.backTranslation = '',
    this.issues = const [],
    this.isPartial = false,
  });

  /// Reads the [toJson] keys; also accepts snake_case keys
  /// (`back_translation`, `is_partial`). An unknown or missing verdict is
  /// [MeaningVerdict.fallback] for the issues' types.
  ///
  /// Throws a [FormatException] when `backTranslation` is not a string,
  /// `issues` is not a list of objects (see [MeaningIssue.fromJson]) or
  /// `isPartial` is not a boolean.
  factory fromJson(Map<String, dynamic> json) {
    Object? read(String key, String snake) => json[key] ?? json[snake];

    final issues = switch (read('issues', 'issues')) {
      null => const <MeaningIssue>[],
      final List<dynamic> list => [
        for (final item in list)
          if (item is Map<String, dynamic>)
            MeaningIssue.fromJson(item)
          else
            throw FormatException('Invalid MeaningCheck.issues item', item),
      ],
      final value => throw FormatException(
        'Invalid MeaningCheck.issues',
        value,
      ),
    };
    final verdict = read('verdict', 'verdict');
    return MeaningCheck(
      verdict:
          MeaningVerdict.byName(verdict is String ? verdict : null) ??
          MeaningVerdict.fallback(
            hasIssues: issues.isNotEmpty,
            issueTypes: [for (final issue in issues) issue.type],
          ),
      backTranslation: switch (read('backTranslation', 'back_translation')) {
        null => '',
        final String text => text,
        final value => throw FormatException(
          'Invalid MeaningCheck.backTranslation',
          value,
        ),
      },
      issues: List.unmodifiable(issues),
      isPartial: switch (read('isPartial', 'is_partial')) {
        null => false,
        final bool partial => partial,
        final value => throw FormatException(
          'Invalid MeaningCheck.isPartial',
          value,
        ),
      },
    );
  }

  final MeaningVerdict verdict;

  /// The translation translated back into the source language (model
  /// output; may be empty).
  final String backTranslation;

  /// The differences in meaning, in the order the model listed them
  /// (empty when none were found or none could be located).
  final List<MeaningIssue> issues;

  /// Whether only the beginnings of long texts were compared (see
  /// `TranslationPrompts.maxMeaningCheckChars`).
  final bool isPartial;

  /// Whether the meaning is fully preserved.
  bool get isSame => verdict == MeaningVerdict.same;

  MeaningCheck copyWith({
    MeaningVerdict? verdict,
    String? backTranslation,
    List<MeaningIssue>? issues,
    bool? isPartial,
  }) => MeaningCheck(
    verdict: verdict ?? this.verdict,
    backTranslation: backTranslation ?? this.backTranslation,
    issues: issues ?? this.issues,
    isPartial: isPartial ?? this.isPartial,
  );

  Map<String, dynamic> toJson() => {
    'verdict': verdict.name,
    'backTranslation': backTranslation,
    'issues': [for (final issue in issues) issue.toJson()],
    'isPartial': isPartial,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeaningCheck &&
          other.verdict == verdict &&
          other.backTranslation == backTranslation &&
          _issueList.equals(other.issues, issues) &&
          other.isPartial == isPartial;

  @override
  int get hashCode =>
      Object.hash(verdict, backTranslation, _issueList.hash(issues), isPartial);

  @override
  String toString() =>
      'MeaningCheck(${verdict.name}, ${issues.length} issues'
      '${isPartial ? ', partial' : ''})';
}
