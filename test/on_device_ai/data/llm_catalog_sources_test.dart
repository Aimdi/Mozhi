import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:translation_repository/translation_repository.dart';

/// The catalogue sources (tool/llm_catalog.json) and the bundled catalogue
/// against what the app knows: its language codes and prompt profiles.
void main() {
  final sources =
      (jsonDecode(File('tool/llm_catalog.json').readAsStringSync())
              as Map<String, Object?>)['models']!
          as List<Object?>;
  final bundled = LlamaModelCatalog.parse(
    File('packages/llama_engine/assets/models.json').readAsStringSync(),
  );
  final codes = {for (final language in LanguageCatalog.all) language.code};

  test('lists the translation model and the two assistants', () {
    expect(
      [for (final source in sources) (source! as Map<String, Object?>)['id']],
      ['hy-mt2-1.8b-q4', 'gemma-4-e2b-q4', 'qwen3-1.7b-q4'],
    );
  });

  test('languages are app language codes', () {
    for (final source in sources.cast<Map<String, Object?>>()) {
      for (final code in (source['languages'] as List<Object?>?) ?? []) {
        expect(codes, contains(code), reason: '${source['id']}: $code');
      }
    }
    for (final model in bundled.models) {
      expect(codes, containsAll(model.languages), reason: model.id);
    }
  });

  test('Hy-MT2 translates the 33 languages and 5 variants of its README', () {
    final hy = sources.cast<Map<String, Object?>>().first;
    final languages = (hy['languages']! as List<Object?>).cast<String>();
    expect(languages, hasLength(38));
    expect(
      languages,
      containsAll(['zh-CN', 'zh-TW', 'yue', 'bo', 'ug', 'kk', 'mn', 'tl']),
    );
    expect(hy['promptProfile'], PromptProfile.hunyuanMt.name);
  });

  test('prompt profiles are PromptProfile names', () {
    expect(LlamaCatalogModel.promptProfiles, {
      for (final profile in PromptProfile.values) profile.name,
    });
    for (final source in sources.cast<Map<String, Object?>>()) {
      expect(
        PromptProfile.tryParse(source['promptProfile']),
        isNotNull,
        reason: '${source['id']}',
      );
    }
  });
}
