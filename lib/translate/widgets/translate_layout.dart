import 'package:material_ui/material_ui.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shared spacing, breakpoints and text styles of the translate screen.
abstract final class TranslateLayout {
  /// At and above this width the input and output panes sit side by side.
  static const double wideBreakpoint = 840;

  /// Below this width the app bar shows only the engine selector.
  static const double compactBreakpoint = 600;

  /// Max width of the single column layout.
  static const double maxColumnWidth = 760;

  /// Max width of the two pane layout.
  static const double maxWideWidth = 1440;

  static const double gutter = 16;
  static const double gap = 12;
  static const double paneGap = 48;
  static const double cardRadius = 24;

  static const BorderRadius cardBorderRadius = BorderRadius.all(
    Radius.circular(cardRadius),
  );

  /// Large, calm text for short inputs/outputs; smaller for long texts.
  static TextStyle? textStyle(BuildContext context, int length) {
    final textTheme = Theme.of(context).textTheme;
    final base = length > 160 ? textTheme.titleMedium : textTheme.titleLarge;
    return base?.copyWith(fontWeight: FontWeight.w400, height: 1.4);
  }
}

/// English (or engine supplied) display name for [code], preferring names
/// from [known] (the engine's language list) over the catalogue.
String languageNameFor(String code, Iterable<Language> known) {
  final wanted = code.toLowerCase().replaceAll('_', '-');
  for (final language in known) {
    if (!language.isCustom && language.code.toLowerCase() == wanted) {
      return language.name;
    }
  }
  return LanguageCatalog.byCode(code)?.name ?? code;
}

/// Whether [options] differ from the defaults in a way the user chose
/// (one-off refinement instructions are ignored).
bool optionsAreDefault(TranslationOptions options) =>
    options.style == TranslationStyle.natural &&
    options.formality == Formality.automatic &&
    options.readingLevel == ReadingLevel.standard &&
    options.speakerGender == Gender.unknown &&
    options.addresseeGender == Gender.unknown &&
    options.context.trim().isEmpty &&
    options.preserveFormatting &&
    options.glossary.isEmpty;

/// Formats a latency as seconds with one decimal ("0.8").
String formatSeconds(Duration duration) =>
    (duration.inMilliseconds / 1000).toStringAsFixed(1);

/// Whether [engineId] is an on-device engine (ids `offline:<backend>`).
bool isOfflineEngineId(String? engineId) =>
    engineId?.startsWith('offline:') ?? false;
