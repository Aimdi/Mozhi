import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

/// How on-device text recognition with downloaded language data reads an
/// image, see [planTextRecognition].
@immutable
sealed class TextRecognitionPlan {
  const new();
}

/// Recognise with [codes] (installed, main language first).
final class TextRecognitionReady extends TextRecognitionPlan {
  const new(this.codes);

  final List<String> codes;

  @override
  bool operator ==(Object other) =>
      other is TextRecognitionReady && listEquals(other.codes, codes);

  @override
  int get hashCode => Object.hashAll(codes);

  @override
  String toString() => 'TextRecognitionReady(${codes.join('+')})';
}

/// The data for the source is missing: offer [missing] (never downloaded
/// without the user's tap).
final class TextRecognitionNeedsData extends TextRecognitionPlan {
  const new(this.missing);

  final OcrDataMissingException missing;

  @override
  bool operator ==(Object other) =>
      other is TextRecognitionNeedsData && other.missing == missing;

  @override
  int get hashCode => missing.hashCode;

  @override
  String toString() => 'TextRecognitionNeedsData($missing)';
}

/// No data reads the source language.
final class TextRecognitionUnsupported extends TextRecognitionPlan {
  const new();

  @override
  bool operator ==(Object other) => other is TextRecognitionUnsupported;

  @override
  int get hashCode => 0;
}

/// Most languages recognised at once for "Detect language" (each one
/// makes recognition slower and its mistakes more likely).
const maxAutoOcrLanguages = 3;

/// Which languages [data] reads an image in [source] with:
///
/// * A specific source: its data when installed; else
///   [TextRecognitionNeedsData] with it, or [TextRecognitionUnsupported]
///   when no data reads it.
/// * "Detect language": the installed languages, at most [maxLanguages]
///   ([maxAutoOcrLanguages]), those of [preferred] first (app codes, best
///   first: the recent source languages and the app's language), then
///   English, then the others by code. With nothing installed: offer the
///   data of the first of [preferred] (then English) that has data, marked
///   as a guess.
Future<TextRecognitionPlan> planTextRecognition(
  TextRecognitionLanguageData data, {
  required Language source,
  List<String> preferred = const [],
  int maxLanguages = maxAutoOcrLanguages,
}) async {
  final installed = (await data.installedOcrLanguages()).keys.toSet();
  if (source.isCustom) return const TextRecognitionUnsupported();
  if (!source.isAuto) {
    final language = await data.ocrLanguageFor(source.code);
    if (language == null) return const TextRecognitionUnsupported();
    if (installed.contains(language.code)) {
      return TextRecognitionReady([language.code]);
    }
    return TextRecognitionNeedsData(OcrDataMissingException(language));
  }
  final candidates = <OcrLanguage>[];
  for (final code in [...preferred, 'en']) {
    final language = await data.ocrLanguageFor(code);
    if (language != null && !candidates.contains(language)) {
      candidates.add(language);
    }
  }
  final codes = <String>[
    for (final language in candidates)
      if (installed.contains(language.code)) language.code,
  ];
  for (final code in installed.toList()..sort()) {
    if (!codes.contains(code)) codes.add(code);
  }
  if (codes.isNotEmpty) {
    return TextRecognitionReady(List.unmodifiable(codes.take(maxLanguages)));
  }
  if (candidates.isEmpty) return const TextRecognitionUnsupported();
  return TextRecognitionNeedsData(
    OcrDataMissingException(candidates.first, guessed: true),
  );
}
