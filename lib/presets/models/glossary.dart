import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// Language scopes of glossaries: a language code or [any].
abstract final class LanguageScope {
  /// Matches every language.
  static const any = 'any';

  /// Whether [scope] means "any language" (`any`, `*` or empty).
  static bool isAny(String scope) {
    final key = _key(scope);
    return key.isEmpty || key == any || key == '*';
  }

  /// Canonical stored form of [scope]: [any] or the trimmed code.
  static String normalize(String scope) => isAny(scope) ? any : scope.trim();

  /// Whether a glossary scoped to [scope] applies to the language [code].
  ///
  /// Codes compare case-insensitively with `_` == `-` and after
  /// [LanguageMatcher.normalize] (`iw` == `he`, `fr-FR` == `fr`). A bare
  /// language scope matches its regional variants (`pt` matches `pt-BR`) but
  /// not the other way round. An unknown [code] (empty, `auto` or `any`)
  /// matches every scope, so source-scoped glossaries still apply while the
  /// source language is being detected.
  static bool matches(String scope, String code) {
    if (isAny(scope)) return true;
    final query = _key(code);
    if (query.isEmpty || query == 'auto' || query == any) return true;
    final scoped = _key(scope);
    if (scoped == query) return true;
    final normalizedScope = LanguageMatcher.normalize(scope).toLowerCase();
    if (normalizedScope.isNotEmpty &&
        normalizedScope == LanguageMatcher.normalize(code).toLowerCase()) {
      return true;
    }
    return !scoped.contains('-') && query.split('-').first == scoped;
  }

  static String _key(String code) =>
      code.trim().replaceAll('_', '-').toLowerCase();
}

/// One glossary entry: [source] must be translated as [target].
class GlossaryTerm extends Equatable {
  const new({
    required this.source,
    required this.target,
    this.note = '',
    this.caseSensitive = false,
  });

  /// Throws [FormatException] when [source] or [target] is missing.
  factory fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    final target = json['target'];
    if (source is! String || target is! String) {
      throw const FormatException('Glossary term needs a source and target');
    }
    final note = json['note'];
    final caseSensitive = json['caseSensitive'];
    return GlossaryTerm(
      source: source,
      target: target,
      note: note is String ? note : '',
      caseSensitive: caseSensitive == true || caseSensitive == 'true',
    );
  }

  final String source;
  final String target;

  /// Free-text note for the user (not sent to the translator).
  final String note;

  /// Whether [source] only matches with the exact capitalisation.
  final bool caseSensitive;

  /// Both [source] and [target] contain text.
  bool get isValid => source.trim().isNotEmpty && target.trim().isNotEmpty;

  /// Copy with trimmed fields.
  GlossaryTerm trimmed() => GlossaryTerm(
    source: source.trim(),
    target: target.trim(),
    note: note.trim(),
    caseSensitive: caseSensitive,
  );

  /// Whether this and [other] define the same source term: equal after
  /// trimming, ignoring case unless both are case-sensitive.
  bool sameSourceAs(GlossaryTerm other) {
    final a = source.trim();
    final b = other.source.trim();
    if (caseSensitive && other.caseSensitive) return a == b;
    return a.toLowerCase() == b.toLowerCase();
  }

  GlossaryTerm copyWith({
    String? source,
    String? target,
    String? note,
    bool? caseSensitive,
  }) => GlossaryTerm(
    source: source ?? this.source,
    target: target ?? this.target,
    note: note ?? this.note,
    caseSensitive: caseSensitive ?? this.caseSensitive,
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'target': target,
    if (note.isNotEmpty) 'note': note,
    if (caseSensitive) 'caseSensitive': true,
  };

  @override
  List<Object?> get props => [source, target, note, caseSensitive];
}

/// Result of [mergeTerms].
typedef TermMerge = ({List<GlossaryTerm> terms, int added, int updated});

/// Adds [incoming] terms to [existing]: a term with the same source
/// ([GlossaryTerm.sameSourceAs]) replaces the existing one in place, others
/// are appended. Invalid terms are skipped and all terms are trimmed.
TermMerge mergeTerms(
  List<GlossaryTerm> existing,
  Iterable<GlossaryTerm> incoming,
) {
  final terms = [...existing];
  var added = 0;
  var updated = 0;
  for (final raw in incoming) {
    if (!raw.isValid) continue;
    final term = raw.trimmed();
    final index = terms.indexWhere(term.sameSourceAs);
    if (index < 0) {
      terms.add(term);
      added++;
    } else if (terms[index] != term) {
      terms[index] = term;
      updated++;
    }
  }
  return (terms: List.unmodifiable(terms), added: added, updated: updated);
}

/// A named list of terms for a language pair (either side may be
/// [LanguageScope.any]). Disabled glossaries are kept but not applied.
class Glossary extends Equatable {
  const new({
    required this.id,
    this.name = '',
    this.sourceCode = LanguageScope.any,
    this.targetCode = LanguageScope.any,
    this.enabled = true,
    this.terms = const [],
  });

  /// Tolerant parser: invalid terms are skipped, a missing scope means
  /// [LanguageScope.any]. Throws [FormatException] without an id.
  factory fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Glossary without an id');
    }
    final name = json['name'];
    final source = json['source'] ?? json['sourceCode'];
    final target = json['target'] ?? json['targetCode'];
    final enabled = json['enabled'];
    final terms = json['terms'];
    return Glossary(
      id: id,
      name: name is String ? name : '',
      sourceCode: LanguageScope.normalize(source is String ? source : ''),
      targetCode: LanguageScope.normalize(target is String ? target : ''),
      enabled: enabled is! bool || enabled,
      terms: List.unmodifiable([
        if (terms is List)
          for (final term in terms)
            if (term is Map) ?_tryParseTerm(term),
      ]),
    );
  }

  final String id;
  final String name;

  /// Source language code or [LanguageScope.any].
  final String sourceCode;

  /// Target language code or [LanguageScope.any].
  final String targetCode;

  final bool enabled;
  final List<GlossaryTerm> terms;

  /// Whether this glossary applies to translations from [sourceCode] into
  /// [targetCode] (see [LanguageScope.matches]); ignores [enabled].
  bool matches({required String sourceCode, required String targetCode}) =>
      LanguageScope.matches(this.sourceCode, sourceCode) &&
      LanguageScope.matches(this.targetCode, targetCode);

  /// Number of scoped sides: 2 for a language pair, 0 for any -> any.
  int get specificity =>
      (LanguageScope.isAny(sourceCode) ? 0 : 1) +
      (LanguageScope.isAny(targetCode) ? 0 : 1);

  Glossary copyWith({
    String? id,
    String? name,
    String? sourceCode,
    String? targetCode,
    bool? enabled,
    List<GlossaryTerm>? terms,
  }) => Glossary(
    id: id ?? this.id,
    name: name ?? this.name,
    sourceCode: sourceCode == null
        ? this.sourceCode
        : LanguageScope.normalize(sourceCode),
    targetCode: targetCode == null
        ? this.targetCode
        : LanguageScope.normalize(targetCode),
    enabled: enabled ?? this.enabled,
    terms: terms == null ? this.terms : List.unmodifiable(terms),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': sourceCode,
    'target': targetCode,
    'enabled': enabled,
    'terms': [for (final term in terms) term.toJson()],
  };

  static GlossaryTerm? _tryParseTerm(Map<dynamic, dynamic> json) {
    try {
      final term = GlossaryTerm.fromJson(Map<String, dynamic>.from(json));
      return term.isValid ? term : null;
    } on FormatException {
      return null;
    }
  }

  @override
  List<Object?> get props => [id, name, sourceCode, targetCode, enabled, terms];
}

/// Merges the terms of all enabled [glossaries] that match the language pair
/// into the `source -> target` map used by `TranslationOptions.glossary`.
///
/// Precedence on conflicting source terms ([GlossaryTerm.sameSourceAs]):
/// language-pair glossaries beat one-sided ones, which beat any -> any
/// glossaries; among equally specific glossaries the earlier one in the list
/// wins, and within a glossary the first term wins. Keys and values are
/// trimmed; notes and case flags are not part of the result.
Map<String, String> mergeActiveGlossaries(
  Iterable<Glossary> glossaries, {
  required String sourceCode,
  required String targetCode,
}) {
  final matching = [
    for (final glossary in glossaries)
      if (glossary.enabled &&
          glossary.matches(sourceCode: sourceCode, targetCode: targetCode))
        glossary,
  ];
  // List.sort is not guaranteed to be stable; sort by (specificity, index).
  final order = List.generate(matching.length, (i) => i)
    ..sort((a, b) {
      final bySpecificity = matching[b].specificity.compareTo(
        matching[a].specificity,
      );
      return bySpecificity != 0 ? bySpecificity : a.compareTo(b);
    });
  final accepted = <GlossaryTerm>[];
  final exact = <String>{};
  final foldedAll = <String>{};
  final foldedInsensitive = <String>{};
  for (final index in order) {
    for (final raw in matching[index].terms) {
      if (!raw.isValid) continue;
      final term = raw.trimmed();
      final folded = term.source.toLowerCase();
      final conflict = term.caseSensitive
          ? exact.contains(term.source) || foldedInsensitive.contains(folded)
          : foldedAll.contains(folded);
      if (conflict) continue;
      accepted.add(term);
      exact.add(term.source);
      foldedAll.add(folded);
      if (!term.caseSensitive) foldedInsensitive.add(folded);
    }
  }
  return {for (final term in accepted) term.source: term.target};
}
