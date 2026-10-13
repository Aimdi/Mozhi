/// Unifies Mozhi engines and AI (LLM) providers behind one translation
/// interface, with Kagi-style extras: style/formality/reading-level/gender
/// controls, free-form context and target "languages", alternatives, word
/// insights, refinement suggestions, dictionary and proofreading.
library;

export 'package:llm_api/llm_api.dart'
    show LlmApiException, LlmModel, LlmProvider, LlmRefusalException;
export 'package:mozhi_api/mozhi_api.dart' show MozhiApiException;
export 'package:mt_api/mt_api.dart'
    show
        DeeplApiException,
        DeeplClient,
        LibreTranslateClient,
        LibreTranslateException,
        MtApiException,
        MtErrorKind;

export 'src/cache/translation_cache.dart';
export 'src/language_catalog.dart';
export 'src/language_matcher.dart';
export 'src/models/models.dart';
export 'src/offline/offline_translator.dart';
export 'src/prompts/mt_prompts.dart';
export 'src/prompts/response_parsers.dart';
export 'src/prompts/translation_prompts.dart';
export 'src/repository/repository_exceptions.dart';
export 'src/translation_repository.dart';
