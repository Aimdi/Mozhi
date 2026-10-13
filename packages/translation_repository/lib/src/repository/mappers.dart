import 'dart:convert';
import 'dart:typed_data';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';

/// The Mozhi engine id of [engine] (`google` for `mozhi:google`).
String mozhiEngineId(TranslationEngine engine) =>
    engine.mozhiEngine ??
    (engine.id.startsWith('mozhi:')
        ? engine.id.substring('mozhi:'.length)
        : engine.id);

/// Normalises a detected language code to a catalogue code; empty, `auto`
/// and unknown (`und`) codes become null.
String? normalizeDetected(String? code) {
  final trimmed = code?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower == 'auto' || lower == 'und') return null;
  return LanguageMatcher.normalize(trimmed);
}

/// Maps a Mozhi language list: `auto` becomes [Language.auto] (first), the
/// other entries keep the engine's id and name and get a native name from
/// the [LanguageCatalog] when known.
List<Language> mapMozhiLanguages(List<MozhiLanguage> languages) {
  var hasAuto = false;
  final mapped = <Language>[];
  final seen = <String>{};
  for (final language in languages) {
    final id = language.id.trim();
    if (id.isEmpty) continue;
    if (id.toLowerCase() == 'auto') {
      hasAuto = true;
      continue;
    }
    if (!seen.add(id)) continue;
    mapped.add(
      Language(
        code: id,
        name: language.name.trim().isEmpty ? id : language.name.trim(),
        nativeName: LanguageCatalog.byCode(LanguageMatcher.normalize(id))
            ?.nativeName,
      ),
    );
  }
  return [if (hasAuto) Language.auto, ...mapped];
}

/// Maps a Mozhi translation of [request] by [engine].
TranslationResult mapMozhiTranslation(
  TranslationEngine engine,
  TranslationRequest request,
  MozhiTranslation translation, {
  Duration? elapsed,
}) => TranslationResult(
  engineId: engine.id,
  engineName: engine.name,
  text: translation.translatedText,
  detectedSource: request.source.isAuto
      ? normalizeDetected(translation.detectedLanguage)
      : null,
  sourceTransliteration: translation.sourceTransliteration,
  targetTransliteration: translation.targetTransliteration,
  wordChoices: [
    for (final choice in translation.wordChoices)
      if (choice.word.trim().isNotEmpty)
        WordChoice(
          word: choice.word,
          definition: choice.definition,
          examplesSource: choice.examplesSource.isEmpty && choice.example != ''
              ? [choice.example]
              : choice.examplesSource,
          examplesTarget: choice.examplesTarget,
        ),
  ],
  sourceSynonyms: translation.sourceSynonyms,
  targetSynonyms: translation.targetSynonyms,
  elapsed: elapsed,
);

/// Decodes a base64 image (optionally a `data:` URI); null when empty or
/// invalid.
Uint8List? decodeBase64Image(String data) {
  var payload = data.trim();
  if (payload.startsWith('data:')) {
    final comma = payload.indexOf(',');
    payload = comma == -1 ? '' : payload.substring(comma + 1);
  }
  payload = payload.replaceAll(RegExp(r'\s'), '');
  if (payload.isEmpty) return null;
  try {
    return base64.decode(base64.normalize(payload));
  } on FormatException {
    return null;
  }
}
