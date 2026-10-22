import 'package:translation_repository/src/models/translation_options.dart';

/// The terms of the user's saved glossaries for a language pair (source
/// term -> rendering) and the source terms among them that are
/// case-sensitive.
typedef SavedGlossary = ({
  Map<String, String> terms,
  Set<String> caseSensitive,
});

/// The [SavedGlossary] for [sourceCode] -> [targetCode] (`auto` when the
/// source is detected); see `TranslationRepository.savedGlossaries`.
typedef SavedGlossaryLookup = SavedGlossary Function(
  String sourceCode,
  String targetCode,
);

/// [options] with the [saved] glossary added to its own
/// `TranslationOptions.glossary`: a request's term wins over a saved one
/// for the same source term (compared trimmed, and without case unless
/// either is case-sensitive). The saved case-sensitive terms that are
/// taken join `TranslationOptions.caseSensitiveGlossaryTerms`. [options]
/// itself when nothing is added.
TranslationOptions mergeSavedGlossary(
  TranslationOptions options,
  SavedGlossary saved,
) {
  if (saved.terms.isEmpty) return options;
  final own = options.glossary;
  final ownExact = {for (final key in own.keys) key.trim()};
  final ownFolded = {
    for (final key in own.keys)
      if (!options.caseSensitiveGlossaryTerms.contains(key))
        key.trim().toLowerCase(),
  };
  final added = <String, String>{};
  final caseSensitive = <String>{};
  for (final MapEntry(:key, :value) in saved.terms.entries) {
    final term = key.trim();
    if (term.isEmpty || value.trim().isEmpty) continue;
    final exact = saved.caseSensitive.contains(key);
    final taken = exact
        ? ownExact.contains(term) || ownFolded.contains(term.toLowerCase())
        : ownExact.any((own) => own.toLowerCase() == term.toLowerCase());
    if (taken) continue;
    added[term] = value.trim();
    if (exact) caseSensitive.add(term);
  }
  if (added.isEmpty) return options;
  return options.copyWith(
    glossary: {...added, ...own},
    caseSensitiveGlossaryTerms: {
      ...options.caseSensitiveGlossaryTerms,
      ...caseSensitive,
    },
  );
}
