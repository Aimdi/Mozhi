import 'package:llm_api/llm_api.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';

/// Sampling recommended by a model card.
typedef MtSampling = ({double? temperature, double? topP, int? topK});

/// Prompt templates for translation-specialised models.
///
/// Contract: [translate] returns exactly one user message (no system prompt)
/// in the model's documented template, and expects an explicit source
/// language (callers detect it first when the source is auto). For
/// [PromptProfile.general]/[PromptProfile.auto] it delegates to
/// [TranslationPrompts.translate].
///
/// The templates carry the text verbatim and nothing else: translation
/// options, glossaries, custom styles and the `[[lang:xx]]` marker are not
/// supported by these models (see [PromptProfile.isTranslationOnly]).
/// Language names come from the [LanguageCatalog] (English names; Chinese
/// names in the Hy-MT Chinese template where known).
abstract final class MtPrompts {
  /// The messages for translating [request] with a model of [profile].
  ///
  /// * [PromptProfile.translateGemma]: Google's TranslateGemma prompt,
  ///   `You are a professional {Source} ({src}) to {Target} ({tgt})
  ///   translator. …` followed by two blank lines and the text. When the
  ///   source is still auto the source slots are left out.
  /// * [PromptProfile.hunyuanMt]: Tencent Hy-MT. A Chinese instruction when
  ///   either side is Chinese (`将以下文本翻译为{target}，注意只需要输出翻译后的
  ///   结果，不要额外解释：`), otherwise `Translate the following segment into
  ///   {target}, without additional explanation.`, then a blank line and
  ///   the text. With an auto source, text that is mostly Han characters
  ///   (and has no kana or Hangul) counts as Chinese.
  static List<LlmMessage> translate(
    PromptProfile profile,
    TranslationRequest request,
  ) => switch (profile) {
    PromptProfile.translateGemma => [LlmMessage.user(_translateGemma(request))],
    PromptProfile.hunyuanMt => [LlmMessage.user(_hunyuanMt(request))],
    PromptProfile.general ||
    PromptProfile.auto => TranslationPrompts.translate(request),
  };

  /// Recommended sampling for [profile]; all-null means provider defaults.
  ///
  /// * Hy-MT: temperature 0.7, top-p 0.6, top-k 20 (model card; it also
  ///   recommends a repetition penalty of 1.05, which is not part of
  ///   [MtSampling]).
  /// * TranslateGemma, general and auto: provider defaults (the
  ///   TranslateGemma card does not override sampling).
  static MtSampling sampling(PromptProfile profile) => switch (profile) {
    PromptProfile.hunyuanMt => (temperature: 0.7, topP: 0.6, topK: 20),
    PromptProfile.translateGemma ||
    PromptProfile.general ||
    PromptProfile.auto => (temperature: null, topP: null, topK: null),
  };

  // ---------------------------------------------------------------------
  // TranslateGemma.
  // ---------------------------------------------------------------------

  static String _translateGemma(TranslationRequest request) {
    final tgt = _englishName(request.target);
    final tgtLabel = _gemmaLabel(request.target);
    if (request.source.isAuto) {
      return 'You are a professional translator into $tgtLabel. Your goal is '
          'to accurately convey the meaning and nuances of the original text '
          'while adhering to $tgt grammar, vocabulary, and cultural '
          'sensitivities.\n'
          'Produce only the $tgt translation, without any additional '
          'explanations or commentary. Please translate the following text '
          'into $tgt:\n\n\n'
          '${request.text}';
    }
    final src = _englishName(request.source);
    final srcLabel = _gemmaLabel(request.source);
    return 'You are a professional $srcLabel to $tgtLabel translator. Your '
        'goal is to accurately convey the meaning and nuances of the original '
        '$src text while adhering to $tgt grammar, vocabulary, and cultural '
        'sensitivities.\n'
        'Produce only the $tgt translation, without any additional '
        'explanations or commentary. Please translate the following $src '
        'text into $tgt:\n\n\n'
        '${request.text}';
  }

  /// `English (en)`; custom names have no code.
  static String _gemmaLabel(Language language) {
    final name = _englishName(language);
    if (language.isCustom) return name;
    final code = TranslationPrompts.sanitizeCustomLanguage(
      LanguageMatcher.normalize(language.code),
    );
    return code.isEmpty || code == name ? name : '$name ($code)';
  }

  // ---------------------------------------------------------------------
  // Tencent Hy-MT / Hunyuan-MT.
  // ---------------------------------------------------------------------

  static String _hunyuanMt(TranslationRequest request) {
    final chinese =
        _isChinese(request.target) ||
        (request.source.isAuto
            ? _looksChinese(request.text)
            : _isChinese(request.source));
    if (chinese) {
      final target =
          _chineseNames[_code(request.target)] ?? _englishName(request.target);
      return '将以下文本翻译为$target，注意只需要输出翻译后的结果，不要额外解释：\n\n'
          '${request.text}';
    }
    return 'Translate the following segment into '
        '${_englishName(request.target)}, without additional explanation.'
        '\n\n${request.text}';
  }

  /// Chinese (any script or region), after normalisation (`zh`, `cmn`,
  /// `zh-Hant`, `zh-HK`, ...).
  static bool _isChinese(Language language) {
    if (language.isCustom || language.isAuto) return false;
    return _code(language).split('-').first.toLowerCase() == 'zh';
  }

  static final _han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
  static final _kanaOrHangul = RegExp(
    r'[\u3040-\u30FF\u31F0-\u31FF\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]',
  );
  static final _letters = RegExp(r'\p{L}+', unicode: true);

  /// Whether [text] (its first 1000 characters) is mostly Chinese: no
  /// Japanese kana or Korean Hangul, and at least 1.5 Han characters per
  /// word of other letters (a Chinese word averages about 1.5 characters),
  /// so `我爱 Flutter` is Chinese but `I like 饺子 a lot` is not.
  static bool _looksChinese(String text) {
    final sample = text.length > 1000 ? text.substring(0, 1000) : text;
    if (_kanaOrHangul.hasMatch(sample)) return false;
    final han = _han.allMatches(sample).length;
    if (han == 0) return false;
    final otherWords = _letters.allMatches(sample.replaceAll(_han, ' ')).length;
    return han * 2 >= otherWords * 3;
  }

  /// Chinese names of the Hy-MT languages (model card table), plus common
  /// regional variants, keyed by catalogue code.
  static const _chineseNames = <String, String>{
    'zh-CN': '中文',
    'zh-TW': '繁体中文',
    'yue': '粤语',
    'en': '英语',
    'en-GB': '英式英语',
    'en-US': '美式英语',
    'fr': '法语',
    'fr-CA': '加拿大法语',
    'pt': '葡萄牙语',
    'pt-BR': '巴西葡萄牙语',
    'pt-PT': '欧洲葡萄牙语',
    'es': '西班牙语',
    'ja': '日语',
    'tr': '土耳其语',
    'ru': '俄语',
    'ar': '阿拉伯语',
    'ko': '韩语',
    'th': '泰语',
    'it': '意大利语',
    'de': '德语',
    'vi': '越南语',
    'ms': '马来语',
    'id': '印尼语',
    'tl': '菲律宾语',
    'hi': '印地语',
    'pl': '波兰语',
    'cs': '捷克语',
    'nl': '荷兰语',
    'km': '高棉语',
    'my': '缅甸语',
    'fa': '波斯语',
    'gu': '古吉拉特语',
    'ur': '乌尔都语',
    'te': '泰卢固语',
    'mr': '马拉地语',
    'he': '希伯来语',
    'bn': '孟加拉语',
    'ta': '泰米尔语',
    'uk': '乌克兰语',
    'bo': '藏语',
    'kk': '哈萨克语',
    'mn': '蒙古语',
    'ug': '维吾尔语',
  };

  // ---------------------------------------------------------------------
  // Shared helpers.
  // ---------------------------------------------------------------------

  /// The catalogue code of [language] (`iw` -> `he`, `zh` -> `zh-CN`).
  static String _code(Language language) =>
      LanguageMatcher.normalize(language.code);

  /// The English catalogue name of [language], its own name when the
  /// catalogue does not know it, or the sanitised text of a custom target.
  static String _englishName(Language language) {
    if (language.isCustom) {
      final name = TranslationPrompts.sanitizeCustomLanguage(language.name);
      return name.isEmpty ? 'English' : name;
    }
    final name = TranslationPrompts.sanitizeCustomLanguage(
      LanguageCatalog.byCode(language.code)?.name ?? language.name,
    );
    return name.isNotEmpty
        ? name
        : TranslationPrompts.sanitizeCustomLanguage(language.code);
  }
}
