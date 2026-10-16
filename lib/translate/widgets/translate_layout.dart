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

  /// Space between two groups of the output column (output card, "Refine
  /// & learn", more languages).
  static const double sectionGap = 20;
  static const double paneGap = 48;
  static const double cardRadius = 24;

  /// Inner padding of the input and output cards (start edge).
  static const double cardPadding = 20;

  /// Texts longer than this use the smaller text style.
  static const int longTextLength = 160;

  static const BorderRadius cardBorderRadius = BorderRadius.all(
    Radius.circular(cardRadius),
  );

  /// Large, calm text for short inputs; smaller for long texts.
  static TextStyle? textStyle(BuildContext context, int length) {
    final textTheme = Theme.of(context).textTheme;
    final base = length > longTextLength
        ? textTheme.titleMedium
        : textTheme.titleLarge;
    return base?.copyWith(fontWeight: FontWeight.w400, height: 1.4);
  }

  /// The translation: a step larger than [textStyle], with a comfortable
  /// line height.
  static TextStyle? outputTextStyle(BuildContext context, int length) {
    final textTheme = Theme.of(context).textTheme;
    final base = length > longTextLength
        ? textTheme.titleLarge
        : textTheme.headlineSmall;
    return base?.copyWith(
      fontWeight: FontWeight.w400,
      height: 1.4,
      letterSpacing: 0,
    );
  }

  /// Surface of the input card.
  static Color inputSurface(ColorScheme scheme) => scheme.surfaceContainerLow;

  /// Surface of the output card: a subtle tint of the primary colour over
  /// the input's surface, so the translation stands apart without
  /// competing with it (text keeps `onSurface` contrast in every theme).
  static Color outputSurface(ColorScheme scheme) => Color.alphaBlend(
    scheme.primary.withValues(
      alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.07,
    ),
    scheme.surfaceContainerLow,
  );

  /// Surface of the target language button: a stronger tint of the output
  /// card's colour, so the button reads as the output's header.
  static Color targetButtonSurface(ColorScheme scheme) => Color.alphaBlend(
    scheme.primary.withValues(
      alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.12,
    ),
    scheme.surfaceContainerHigh,
  );
}

/// A small heading that names a group of the translate screen ("Refine &
/// learn"), a header for screen readers.
class TranslateSectionHeader extends StatelessWidget {
  const new(this.title, {this.icon, super.key});

  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
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
