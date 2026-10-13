import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// A request to translate something, coming from outside the translate
/// screen: a Kagi-style URL (`/translate?text=…&from=…&to=…`), a share
/// intent or text selected in another app.
class TranslateLink extends Equatable {
  const new({this.text, this.from, this.to});

  /// Parses Kagi/Google style query parameters from [uri].
  ///
  /// Accepted names: `text` (or `q`), `from` (or `sl`, `source`) and `to`
  /// (or `tl`, `target`). Returns null when none of them is present.
  static TranslateLink? fromUri(Uri uri) {
    final params = uri.queryParameters;
    String? pick(List<String> names) {
      for (final name in names) {
        final value = params[name]?.trim();
        if (value != null && value.isNotEmpty) return params[name];
      }
      return null;
    }

    final text = pick(const ['text', 'q']);
    final from = pick(const ['from', 'sl', 'source'])?.trim();
    final to = pick(const ['to', 'tl', 'target'])?.trim();
    if (text == null && from == null && to == null) return null;
    return TranslateLink(text: text, from: from, to: to);
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
  /// to finish loading, selects the matching languages, then replaces the
  /// input and translates.
  Future<void> applyTo(
    TranslateCubit cubit, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final state = await waitForEngines(cubit, timeout: timeout);
    if (state == null) return;

    final from = this.from;
    if (from != null) {
      final language = matchLanguage(from, state.sourceLanguages);
      if (language != null && language != state.source) {
        cubit.setSource(language);
      }
    }
    final to = this.to;
    if (to != null) {
      final language =
          matchLanguage(to, state.targetLanguages) ??
          ((state.engine?.supportsCustomLanguages ?? false)
              ? Language.custom(to)
              : null);
      if (language != null && language != state.target) {
        cubit.setTarget(language);
      }
    }
    if (hasText) cubit.setInputAndTranslate(text!);
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
