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
  if (engine.isAi) 'local': engine.isLocal,
};

Map<String, dynamic> translationJson(
  TranslationResult result, {
  required Language source,
  required Language target,
  String? instance,
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
  'elapsedMs': ?result.elapsed?.inMilliseconds,
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
