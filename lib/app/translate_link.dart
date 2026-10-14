import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Speed/quality preference a link asks for (Kagi's `quality` parameter).
///
/// [TranslateLink.applyTo] selects the matching quality mode of the
/// translate screen.
enum TranslateLinkQuality {
  fast,
  standard,
  best;

  /// The quality named [value] (case-insensitive), or null when unknown.
  static TranslateLinkQuality? tryParse(String? value) {
    final key = value?.trim().toLowerCase();
    for (final quality in values) {
      if (quality.name == key) return quality;
    }
    return null;
  }
}

/// A request to translate something, coming from outside the translate
/// screen: a Kagi-style URL (`/translate?text=…&from=…&to=…`), a share
/// intent or text selected in another app.
class TranslateLink extends Equatable {
  const new({this.text, this.from, this.to, this.options, this.quality});

  /// Longest text a link may carry; longer text is cut (links come from
  /// outside the app and are not trusted).
  static const maxTextLength = 5000;

  /// Longest language code or name a link may carry; longer values are
  /// ignored.
  static const maxLanguageLength = 64;

  /// Longest `context` / `formality_context` a link may carry; longer text
  /// is cut.
  static const maxContextLength = 2000;

  /// Parses Kagi/Google style query parameters from [uri].
  ///
  /// Accepted names: `text` (or `q`), `from` (or `sl`, `source`) and `to`
  /// (or `tl`, `target`). The text is cut to [maxTextLength]; languages
  /// longer than [maxLanguageLength] are dropped.
  ///
  /// Translation options are read with [TranslationOptions.fromJson], which
  /// accepts Kagi's names and values (`translation_style`, `formality`,
  /// `language_complexity`, `speaker_gender=male`, `context`,
  /// `formality_context`, `preserveFormatting`, ...); see [sanitizeOptions]
  /// for what a link may not set. `quality` is `fast`, `standard` or
  /// `best`. Unknown values are ignored.
  ///
  /// Returns null when none of them is present.
  static TranslateLink? fromUri(Uri uri) {
    final params = uri.queryParameters;
    String? pick(List<String> names) {
      for (final name in names) {
        final value = params[name]?.trim();
        if (value != null && value.isNotEmpty) return params[name];
      }
      return null;
    }

    String? language(List<String> names) {
      final value = pick(names)?.trim();
      return value == null || value.length > maxLanguageLength ? null : value;
    }

    final text = pick(const ['text', 'q']);
    final from = language(const ['from', 'sl', 'source']);
    final to = language(const ['to', 'tl', 'target']);
    final options = sanitizeOptions(TranslationOptions.fromJson(params));
    final quality = TranslateLinkQuality.tryParse(params['quality']);
    if (text == null &&
        from == null &&
        to == null &&
        options == null &&
        quality == null) {
      return null;
    }
    return TranslateLink(
      text: capText(text),
      from: from,
      to: to,
      options: options,
      quality: quality,
    );
  }

  /// What a link may set of [options]: no glossary and no refinement
  /// instructions (a link must not smuggle instructions into a prompt),
  /// `context` and `formality_context` trimmed and cut to
  /// [maxContextLength]. Null when nothing differs from the defaults.
  static TranslationOptions? sanitizeOptions(TranslationOptions options) {
    final safe = TranslationOptions(
      style: options.style,
      formality: options.formality,
      readingLevel: options.readingLevel,
      speakerGender: options.speakerGender,
      addresseeGender: options.addresseeGender,
      context: _cut(options.context.trim(), maxContextLength),
      preserveFormatting: options.preserveFormatting,
      formalityContext: _cut(options.formalityContext.trim(), maxContextLength),
    );
    return safe.isDefault ? null : safe;
  }

  /// [text] cut to [maxTextLength] UTF-16 units without splitting a
  /// surrogate pair.
  static String? capText(String? text) =>
      text == null ? null : _cut(text, maxTextLength);

  static String _cut(String text, int length) {
    if (text.length <= length) return text;
    var end = length;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  /// Text to translate (may be null to only change languages).
  final String? text;

  /// Source language code (or name); `auto` for detection.
  final String? from;

  /// Target language code (or name). Only languages of the engine's list
  /// are applied: free-form AI targets such as `Pirate speak` are ignored.
  final String? to;

  /// Translation options the link asks for (already sanitized, see
  /// [sanitizeOptions]); only the values that differ from the defaults are
  /// applied ([mergeOptions]). Null when the link sets none.
  final TranslationOptions? options;

  /// Speed/quality preference (`quality=fast|standard|best`), kept for the
  /// translate screen to honour; null when absent or unknown.
  final TranslateLinkQuality? quality;

  bool get hasText => text != null && text!.trim().isNotEmpty;

  /// [current] with every option this link sets to a non-default value
  /// replaced by the link's value. The user's glossary and anything the
  /// link leaves at its default are kept; refinement instructions are
  /// dropped. Returns [current] (without instructions) when the link has no
  /// [options].
  TranslationOptions mergeOptions(TranslationOptions current) {
    final linked = options;
    final base = current.copyWith(instructions: '');
    if (linked == null) return base;
    const defaults = TranslationOptions();
    T? changed<T>(T value, T fallback) => value == fallback ? null : value;
    return base.copyWith(
      style: changed(linked.style, defaults.style),
      formality: changed(linked.formality, defaults.formality),
      readingLevel: changed(linked.readingLevel, defaults.readingLevel),
      speakerGender: changed(linked.speakerGender, defaults.speakerGender),
      addresseeGender: changed(
        linked.addresseeGender,
        defaults.addresseeGender,
      ),
      context: changed(linked.context, defaults.context),
      preserveFormatting: changed(
        linked.preserveFormatting,
        defaults.preserveFormatting,
      ),
      formalityContext: changed(
        linked.formalityContext,
        defaults.formalityContext,
      ),
    );
  }

  /// Applies this link to [cubit]: waits (up to [timeout]) for the engines
  /// to finish loading, then hands the text and the matching languages to
  /// [TranslateCubit.setExternalInput], which only translates right away
  /// when that costs nothing (never a paid AI request on its own).
  ///
  /// Languages are only taken from the engine's lists ([matchLanguage]);
  /// unknown values (including free-form AI targets such as
  /// `Pirate speak`) are ignored, so a link cannot smuggle instructions
  /// into a prompt. The text is cut to [maxTextLength].
  ///
  /// [quality] is applied first with [TranslateCubit.setQualityMode]
  /// (`fast` -> [QualityMode.fast], `best` -> [QualityMode.best],
  /// `standard` -> [QualityMode.off]; a mode whose engine is not configured
  /// or not available changes nothing), so the languages are matched
  /// against the lists of the engine that will translate.
  ///
  /// [options] that change the current ones are applied next with
  /// [TranslateCubit.setOptions].
  ///
  /// Switching engines and changing options re-translate the input right
  /// away (possibly a paid AI request), so the input is taken out meanwhile
  /// (and put back afterwards when the link has no text of its own and the
  /// user has not typed something else meanwhile): a link never starts a
  /// paid request on its own. A quality mode whose engine is already the
  /// selected one changes no engine, so the input and its translation stay.
  Future<void> applyTo(
    TranslateCubit cubit, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final loaded = await waitForEngines(cubit, timeout: timeout);
    if (loaded == null || cubit.isClosed) return;

    final qualityCleared = await _applyQuality(cubit);
    if (cubit.isClosed) return;
    final cleared = _applyOptions(cubit) || qualityCleared;
    final state = cubit.state;
    final from = this.from;
    final source = from == null
        ? null
        : matchLanguage(from, state.sourceLanguages);
    final to = this.to;
    final target = to == null ? null : matchLanguage(to, state.targetLanguages);
    final usableTarget = target == null || target.isAuto || target.isCustom
        ? null
        : target;
    final usableSource = source == null || source.isCustom ? null : source;

    if (hasText) {
      final text = capText(this.text)!;
      cubit.setExternalInput(
        text,
        source: usableSource == state.source ? null : usableSource,
        target: usableTarget == state.target ? null : usableTarget,
      );
      // The same text arrived from outside moments ago and was ignored as
      // a repeat: put it back instead of leaving the input empty.
      if (cleared && cubit.state.input.isEmpty) cubit.setInput(text);
      return;
    }
    // Languages only: select them. Like any external input, the current
    // text is only translated again when that costs nothing.
    if ((usableSource != null && usableSource != state.source) ||
        (usableTarget != null && usableTarget != state.target)) {
      cubit.setExternalInput(
        state.input,
        source: usableSource == state.source ? null : usableSource,
        target: usableTarget == state.target ? null : usableTarget,
      );
    }
  }

  /// Applies [quality] (see [applyTo]); returns whether the input was
  /// cleared and still is (a link with text puts its own text in).
  Future<bool> _applyQuality(TranslateCubit cubit) async {
    final mode = switch (quality) {
      null => null,
      TranslateLinkQuality.fast => QualityMode.fast,
      TranslateLinkQuality.standard => QualityMode.off,
      TranslateLinkQuality.best => QualityMode.best,
    };
    final state = cubit.state;
    if (mode == null || mode == state.qualityMode) return false;
    // Nothing would change: do not touch the input.
    if (mode != QualityMode.off && state.qualityEngine(mode) == null) {
      return false;
    }
    final input = state.input;
    // Only an engine switch translates again: a mode whose engine is the
    // selected one only changes the mode, and the output is kept. (Turning
    // a mode off goes back to the normal engine, which is another one.)
    final switches =
        mode == QualityMode.off ||
        state.qualityEngine(mode)?.id != state.engine?.id;
    if (input.trim().isEmpty || !switches) {
      await cubit.setQualityMode(mode);
      return false;
    }
    cubit.setInput('');
    await cubit.setQualityMode(mode);
    if (cubit.isClosed) return true;
    // The user may have typed while the engine's languages loaded: keep
    // that.
    if (cubit.state.input.isNotEmpty) return false;
    if (hasText) return true;
    cubit.setInput(input);
    return false;
  }

  /// Applies [options] (see [applyTo]); returns whether the input was
  /// cleared and still is (a link with text puts its own text in).
  bool _applyOptions(TranslateCubit cubit) {
    if (options == null) return false;
    final state = cubit.state;
    final merged = mergeOptions(state.options);
    if (merged == state.options) return false;
    final input = state.input;
    if (!state.isAiEngine || input.trim().isEmpty) {
      cubit.setOptions(merged);
      return false;
    }
    cubit
      ..setInput('')
      ..setOptions(merged);
    if (hasText) return true;
    cubit.setInput(input);
    return false;
  }

  @override
  List<Object?> get props => [text, from, to, options, quality];
}

/// Completes with the first state of [cubit] whose engines finished loading
/// (successfully or not). Completes with the current state after [timeout]
/// and with null when the cubit closes first.
Future<TranslateState?> waitForEngines(
  TranslateCubit cubit, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  bool settled(TranslateState s) =>
      s.enginesStatus == EnginesStatus.ready ||
      s.enginesStatus == EnginesStatus.failure;

  if (settled(cubit.state)) return cubit.state;
  if (cubit.isClosed) return null;
  try {
    return await cubit.stream
        .cast<TranslateState?>()
        .firstWhere((s) => s != null && settled(s), orElse: () => null)
        .timeout(timeout);
  } on TimeoutException {
    return cubit.isClosed ? null : cubit.state;
  }
}

/// Finds [query] (a code such as `pt-BR`/`auto`, or an English/native
/// name) in [available].
Language? matchLanguage(String query, List<Language> available) {
  final wanted = query.trim().toLowerCase().replaceAll('_', '-');
  if (wanted.isEmpty) return null;
  for (final language in available) {
    if (!language.isCustom && language.code.toLowerCase() == wanted) {
      return language;
    }
  }
  for (final language in available) {
    if (language.name.toLowerCase() == wanted ||
        language.nativeName?.toLowerCase() == wanted) {
      return language;
    }
  }
  return LanguageMatcher.match(
    Language(code: query.trim(), name: query.trim()),
    available,
  );
}
