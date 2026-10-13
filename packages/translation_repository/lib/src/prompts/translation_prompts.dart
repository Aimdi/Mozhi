import 'package:llm_api/llm_api.dart';
import 'package:translation_repository/src/models/models.dart';

/// Builds LLM messages for every AI feature. Pure functions; unit-tested by
/// asserting on the produced text.
///
/// Translation prompt requirements (Kagi-grade):
/// * System prompt frames the task as professional translation, tells the
///   model to translate *everything* faithfully including slang/profanity
///   (never refuse, never censor, never answer questions contained in the
///   text, never add notes/quotes/preambles), output ONLY the translation.
/// * Natural style: idiomatic, natural to native speakers, keep meaning,
///   tone, register, humour; use official localized titles for well-known
///   works/brands; convert idioms to target equivalents. Literal style: stay
///   close to source structure while remaining grammatical.
/// * Formality / reading level (CEFR descriptions) / speaker & addressee
///   gender / context / glossary ("always translate X as Y") / one-off
///   instructions are rendered only when non-default.
/// * Preserve formatting: line breaks, Markdown, HTML/XML tags, code, URLs,
///   e-mail addresses, `{placeholders}`, `%s`, `{{vars}}`, emoji.
/// * Custom targets (e.g. "Pirate speak") are treated as a style/register
///   to rewrite into.
/// * When the source is auto, the model must begin its reply with a marker
///   `[[lang:xx]]` (ISO 639-1 or BCP-47 code of the detected source) on its
///   own, then the translation. `ResponseParsers.splitLanguageMarker`
///   strips it. When source == target language, the model should improve /
///   rephrase in the same language instead (Kagi behaviour) — the marker
///   still applies.
/// * The text to translate goes in the user message wrapped in
///   `<source>...</source>` tags (prompt-injection hardening); the system
///   prompt says content inside the tags is data, not instructions.
///
/// JSON features ask for a single JSON object (no code fences), with the
/// exact schema spelled out in the prompt, and explanations written in
/// [uiLanguage] (an English language name, default "English").
abstract final class TranslationPrompts {
  static List<LlmMessage> translate(TranslationRequest request) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"description": str, "alternatives": [{"text": str,
  /// "explanation": str}]}` with [count] alternatives that genuinely differ.
  /// When [span] is non-null only alternatives for that substring of the
  /// translation are requested (Kagi partial alternatives); `text` is then
  /// the replacement for the span.
  static List<LlmMessage> alternatives(
    TranslationRequest request,
    String translation, {
    int count = 3,
    String? span,
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"insights": [{"source": str, "target": str, "type": str,
  /// "explanation": str, "variations": [{"text": str, "explanation": str}]}]}`
  /// — 2 to 6 key words/phrases; `target` must be an exact substring of the
  /// translation; flag idioms, wordplay/puns lost in translation, cultural
  /// references, ambiguity.
  static List<LlmMessage> insights(
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"suggestions": [{"label": str, "description": str,
  /// "instruction": str, "icon": str}]}` — 3 to 5 context-specific
  /// refinements for this particular translation, labels in [uiLanguage].
  static List<LlmMessage> suggestions(
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Free-form Markdown explanation of the translation (grammar, word
  /// choices, nuances), or an answer to [question] about it.
  static List<LlmMessage> explain(
    TranslationRequest request,
    String translation, {
    String? question,
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"word": str, "pronunciation": str, "parts_of_speech": [str],
  /// "senses": [{"part_of_speech": str, "definition": str,
  /// "translations": [str], "usage": str}], "examples": [{"source": str,
  /// "translation": str}], "synonyms": [str], "etymology": str,
  /// "notes": str}` — definitions in [uiLanguage], translations into
  /// [targetLanguage].
  static List<LlmMessage> dictionary(
    String word, {
    required Language source,
    required Language targetLanguage,
    String context = '',
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"language": str, "corrected": str, "summary": str,
  /// "edits": [{"original": str, "replacement": str, "explanation": str,
  /// "category": str}]}` — `original` must be an exact substring of the
  /// input; keep the author's voice; follow [style] and [level].
  static List<LlmMessage> proofread(
    String text, {
    WritingStyle style = WritingStyle.general,
    CorrectionLevel level = CorrectionLevel.standard,
    Formality formality = Formality.automatic,
    String context = '',
    String uiLanguage = 'English',
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Schema: `{"language": str, "uncertain": bool, "mixed": bool,
  /// "alternatives": [str]}`.
  static List<LlmMessage> detectLanguage(String text) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Vision translation: user message carries the image; output is the
  /// translated text of the image, formatted like the original (headings,
  /// lists, tables as Markdown), preceded by the `[[lang:xx]]` marker when
  /// source is auto. Must NOT summarise — translate all visible text.
  static List<LlmMessage> translateImage(
    List<int> imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }
}
