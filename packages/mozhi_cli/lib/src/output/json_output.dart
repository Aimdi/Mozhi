import 'dart:convert';

import 'package:mozhi_cli/src/errors.dart';
import 'package:translation_repository/translation_repository.dart';

/// Pretty JSON with two-space indentation.
String encodeJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

Map<String, dynamic> languageJson(Language language) => {
  'code': language.code,
  'name': language.name,
  if (language.nativeName != null) 'nativeName': language.nativeName,
  if (language.isCustom) 'custom': true,
};

Map<String, dynamic> engineJson(TranslationEngine engine) => {
  'id': engine.id,
  'kind': engine.kind.name,
  'name': engine.name,
  'subtitle': ?engine.subtitle,
  if (engine.isAi || engine.isMt) 'local': engine.isLocal,
  if (engine.mtService case final service?) 'mtService': service.name,
};

Map<String, dynamic> translationJson(
  TranslationResult result, {
  required Language source,
  required Language target,
  String? instance,
  AlternativeTranslations? alternatives,
  List<WordInsight>? insights,
  String? explanation,
  String? romanization,
  MeaningCheck? meaningCheck,
}) => {
  'engine': result.engineId,
  'engineName': result.engineName,
  'instance': ?instance,
  'source': source.code,
  'detectedSource': ?result.detectedSource,
  'target': target.code,
  'text': result.text,
  if (result.sourceTransliteration.isNotEmpty)
    'sourceTransliteration': result.sourceTransliteration,
  if (result.targetTransliteration.isNotEmpty)
    'targetTransliteration': result.targetTransliteration,
  if (result.wordChoices.isNotEmpty)
    'wordChoices': [
      for (final choice in result.wordChoices)
        {
          'word': choice.word,
          if (choice.definition.isNotEmpty) 'definition': choice.definition,
          if (choice.examplesSource.isNotEmpty)
            'examplesSource': choice.examplesSource,
          if (choice.examplesTarget.isNotEmpty)
            'examplesTarget': choice.examplesTarget,
        },
    ],
  if (result.sourceSynonyms.isNotEmpty) 'sourceSynonyms': result.sourceSynonyms,
  if (result.targetSynonyms.isNotEmpty) 'targetSynonyms': result.targetSynonyms,
  if (alternatives != null) 'alternatives': alternativesJson(alternatives),
  if (insights != null)
    'insights': [for (final insight in insights) insightJson(insight)],
  'explanation': ?explanation,
  'romanization': ?romanization,
  if (meaningCheck != null) 'meaningCheck': meaningCheckJson(meaningCheck),
  'elapsedMs': ?result.elapsed?.inMilliseconds,
};

Map<String, dynamic> meaningCheckJson(MeaningCheck check) => {
  'verdict': check.verdict.name,
  if (check.backTranslation.isNotEmpty)
    'backTranslation': check.backTranslation,
  'issues': [
    for (final issue in check.issues)
      {
        'type': issue.type.name,
        'problem': issue.problem,
        if (issue.sourceSpan.isNotEmpty) 'sourceSpan': issue.sourceSpan,
        if (issue.translationSpan.isNotEmpty)
          'translationSpan': issue.translationSpan,
        if (issue.suggestion.isNotEmpty) 'suggestion': issue.suggestion,
      },
  ],
};

Map<String, dynamic> alternativesJson(AlternativeTranslations alternatives) => {
  if (alternatives.description.isNotEmpty)
    'description': alternatives.description,
  'items': [
    for (final alt in alternatives.alternatives)
      {
        'text': alt.text,
        if (alt.explanation.isNotEmpty) 'explanation': alt.explanation,
      },
  ],
};

Map<String, dynamic> insightJson(WordInsight insight) => {
  if (insight.sourceText.isNotEmpty) 'source': insight.sourceText,
  'target': insight.targetText,
  'type': insight.type,
  if (insight.explanation.isNotEmpty) 'explanation': insight.explanation,
  if (insight.variations.isNotEmpty)
    'variations': [
      for (final v in insight.variations)
        {
          'text': v.text,
          if (v.explanation.isNotEmpty) 'explanation': v.explanation,
        },
    ],
};

Map<String, dynamic> dictionaryJson(DictionaryEntry entry) => {
  'word': entry.word,
  if (entry.pronunciation.isNotEmpty) 'pronunciation': entry.pronunciation,
  if (entry.partsOfSpeech.isNotEmpty) 'partsOfSpeech': entry.partsOfSpeech,
  'didYouMean': ?entry.didYouMean,
  'senses': [
    for (final sense in entry.senses)
      {
        'definition': sense.definition,
        if (sense.partOfSpeech.isNotEmpty) 'partOfSpeech': sense.partOfSpeech,
        if (sense.translations.isNotEmpty) 'translations': sense.translations,
        if (sense.usage.isNotEmpty) 'usage': sense.usage,
      },
  ],
  if (entry.examples.isNotEmpty)
    'examples': [
      for (final ex in entry.examples)
        {
          'source': ex.source,
          if (ex.translation.isNotEmpty) 'translation': ex.translation,
        },
    ],
  if (entry.synonyms.isNotEmpty) 'synonyms': entry.synonyms,
  if (entry.relatedWords.isNotEmpty) 'relatedWords': entry.relatedWords,
  if (entry.etymology.isNotEmpty) 'etymology': entry.etymology,
  if (entry.notes.isNotEmpty) 'notes': entry.notes,
};

Map<String, dynamic> compareJson(CompareEntry entry) => entry.isSuccess
    ? {
        'engine': entry.id,
        'engineName': entry.name,
        'ok': true,
        'text': entry.result!.text,
        'detectedSource': ?entry.result!.detectedSource,
        'elapsedMs': ?entry.result!.elapsed?.inMilliseconds,
      }
    : {
        'engine': entry.id,
        'engineName': entry.name,
        'ok': false,
        'error': describeError(entry.error!).message,
      };

Map<String, dynamic> proofreadJson(ProofreadResult result) => {
  'correctedText': result.correctedText,
  'detectedLanguage': ?result.detectedLanguage,
  if (result.summary.isNotEmpty) 'summary': result.summary,
  'edits': [
    for (final edit in result.edits)
      {
        'original': edit.original,
        'replacement': edit.replacement,
        'category': edit.category,
        if (edit.explanation.isNotEmpty) 'explanation': edit.explanation,
      },
  ],
};
