import 'dart:convert';
import 'dart:typed_data';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';

/// The Mozhi engine id of [engine] (`google` for `mozhi:google`).
String mozhiEngineId(TranslationEngine engine) =>
    engine.mozhiEngine ??
    (engine.id.startsWith('mozhi:')
        ? engine.id.substring('mozhi:'.length)
        : engine.id);

/// Normalises a detected language code to a catalogue code; empty, `auto`,
/// unknown (`und`) and placeholder codes (a literally echoed `xx`, see
/// `ResponseParsers.isPlaceholderLanguageCode`) become null.
String? normalizeDetected(String? code) {
  final trimmed = code?.trim() ?? '';
  if (ResponseParsers.isPlaceholderLanguageCode(trimmed)) return null;
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

/// DeepL target ids that Mozhi lists but rejects (`libmozhi` validates `to`
/// against DeepL's *source* list, mozhi-contract G3), mapped to the base
/// code it accepts.
const _deeplTargetAliases = {
  'en-us': 'en',
  'en-gb': 'en',
  'pt-br': 'pt',
  'pt-pt': 'pt',
  'zh-hans': 'zh',
};

/// DeepL target ids that would silently become a different language (base
/// `zh` is Simplified Chinese), so they are dropped instead.
const _deeplDroppedTargets = {'zh-hant'};

/// Fixes a Mozhi DeepL target list: `en-us`/`en-gb` -> `en`,
/// `pt-br`/`pt-pt` -> `pt`, `zh-hans` -> `zh` (named after the base
/// language), and drops `zh-hant`. Duplicates are removed later by
/// [mapMozhiLanguages].
List<MozhiLanguage> fixMozhiDeeplTargets(List<MozhiLanguage> languages) => [
  for (final language in languages)
    if (!_deeplDroppedTargets.contains(language.id.trim().toLowerCase()))
      switch (_deeplTargetAliases[language.id.trim().toLowerCase()]) {
        final base? => MozhiLanguage(
          id: base,
          name: LanguageCatalog.byCode(base)?.name ?? base,
        ),
        null => language,
      },
];

/// The `to` code to send to Mozhi [engine] for [code]: DeepL regional
/// targets are sent as the base code DeepL accepts (see
/// [fixMozhiDeeplTargets]); everything else is unchanged.
String mozhiTargetCode(String engine, String code) =>
    engine.toLowerCase() == 'deepl'
    ? _deeplTargetAliases[code.trim().toLowerCase()] ?? code
    : code;
