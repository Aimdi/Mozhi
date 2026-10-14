import 'package:mocktail/mocktail.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// Stubs the round-3 output extras of [harness]'s cubit (romanization,
/// alignment, dictionary words and verbosity).
void stubOutputExtras(TranslateHarness harness) {
  final translate = harness.translate;
  when(translate.loadRomanization).thenAnswer((_) async {});
  when(translate.loadAlignment).thenAnswer((_) async {});
  when(() => translate.lookUpWord(any())).thenAnswer((_) async {});
  when(() => translate.setDictionaryVerbosity(any())).thenAnswer((_) async {});
}

/// Registers the fallback values [stubOutputExtras] needs.
void registerOutputFallbacks() {
  registerTranslateFallbacks();
  registerFallbackValue(DictionaryVerbosity.standard);
}

/// An AI engine with a translation-only model (no extras, no refinement).
const translateGemma = TranslationEngine(
  id: 'ai:gemma',
  kind: EngineKind.ai,
  name: 'TranslateGemma',
  subtitle: 'translategemma:4b',
  providerId: 'gemma',
  promptProfile: PromptProfile.translateGemma,
);
