import 'package:llm_api/llm_api.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';

/// Sampling recommended by a model card.
typedef MtSampling = ({double? temperature, double? topP, int? topK});

/// Prompt templates for translation-specialised models.
///
/// Contract (implemented by the prompts agent): [translate] returns exactly
/// one user message (no system prompt) in the model's documented template,
/// and requires an explicit source language (callers detect it first when
/// the source is auto). For [PromptProfile.general]/[PromptProfile.auto] it
/// delegates to [TranslationPrompts.translate].
abstract final class MtPrompts {
  static List<LlmMessage> translate(
    PromptProfile profile,
    TranslationRequest request,
  ) {
    // TODO(prompts): real TranslateGemma / Hy-MT templates.
    return TranslationPrompts.translate(request);
  }

  /// Recommended sampling for [profile]; all-null means provider defaults.
  static MtSampling sampling(PromptProfile profile) =>
      (temperature: null, topP: null, topK: null);
}
