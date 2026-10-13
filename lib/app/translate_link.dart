import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// A request to translate something, coming from outside the translate
/// screen: a Kagi-style URL (`/translate?text=…&from=…&to=…`), a share
/// intent or text selected in another app.
class TranslateLink extends Equatable {
  const new({this.text, this.from, this.to});

  /// Longest text a link may carry; longer text is cut (links come from
  /// outside the app and are not trusted).
  static const maxTextLength = 5000;

  /// Longest language code or name a link may carry; longer values are
  /// ignored.
  static const maxLanguageLength = 64;

  /// Parses Kagi/Google style query parameters from [uri].
  ///
  /// Accepted names: `text` (or `q`), `from` (or `sl`, `source`) and `to`
  /// (or `tl`, `target`). The text is cut to [maxTextLength]; languages
  /// longer than [maxLanguageLength] are dropped. Returns null when none of
  /// them is present.
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
    if (text == null && from == null && to == null) return null;
    return TranslateLink(text: capText(text), from: from, to: to);
  }

  /// [text] cut to [maxTextLength] UTF-16 units without splitting a
  /// surrogate pair.
  static String? capText(String? text) {
    if (text == null || text.length <= maxTextLength) return text;
    var end = maxTextLength;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  /// Text to translate (may be null to only change languages).
  final String? text;

  /// Source language code (or name); `auto` for detection.
  final String? from;

  /// Target language code (or name). AI engines also accept free-form
  /// targets such as `Pirate speak`.
  final String? to;

  bool get hasText => text != null && text!.trim().isNotEmpty;

  /// Applies this link to [cubit]: waits (up to [timeout]) for the engines
  /// to finish loading, then hands the text and the matching languages to
  /// [TranslateCubit.setExternalInput], which only translates right away
  /// when that costs nothing (never a paid AI request on its own).
  ///
  /// Languages are only taken from the engine's lists ([matchLanguage]);
  /// unknown values (including free-form AI targets such as
  /// `Pirate speak`) are ignored, so a link cannot smuggle instructions
  /// into a prompt. The text is cut to [maxTextLength].
  Future<void> applyTo(
    TranslateCubit cubit, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final state = await waitForEngines(cubit, timeout: timeout);
    if (state == null) return;

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
      cubit.setExternalInput(
        capText(text)!,
        source: usableSource == state.source ? null : usableSource,
        target: usableTarget == state.target ? null : usableTarget,
      );
      return;
    }
    // Languages only: select them without translating the current input.
    if ((usableSource != null && usableSource != state.source) ||
        (usableTarget != null && usableTarget != state.target)) {
      cubit.setExternalInput(
        state.input,
        source: usableSource == state.source ? null : usableSource,
        target: usableTarget == state.target ? null : usableTarget,
      );
    }
  }

  @override
  List<Object?> get props => [text, from, to];
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
