import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
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

  /// Radius of the few outlined boxes (a quoted earlier translation, the
  /// compare entries): X's quoted-post card.
  static const double cardRadius = 16;

  /// Inner padding of the input and output (start edge).
  static const double cardPadding = 4;

  /// Diameter of the language avatars of the thread layout.
  static const double avatarSize = 40;

  /// Space between an avatar and its text.
  static const double avatarGap = 12;

  /// Width of the thread connector between the source and target avatars.
  static const double connectorWidth = 2;

  /// Duration of the subtle motion (sections appearing); zero with reduced
  /// motion.
  static Duration motion(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? Duration.zero
      : const Duration(milliseconds: 200);

  /// Texts longer than this use the smaller text style.
  static const int longTextLength = 160;

  static const BorderRadius cardBorderRadius = BorderRadius.all(
    Radius.circular(cardRadius),
  );

  /// Compose-like text for short inputs (20 px); smaller for long texts.
  static TextStyle? textStyle(BuildContext context, int length) {
    final textTheme = Theme.of(context).textTheme;
    return textTheme.bodyLarge?.copyWith(
      fontSize: length > longTextLength ? 17 : 20,
      fontWeight: FontWeight.w400,
      height: 1.35,
      letterSpacing: 0,
    );
  }

  /// The translation: the same size as the input (a post and its reply),
  /// in the body colour.
  static TextStyle? outputTextStyle(BuildContext context, int length) =>
      textStyle(context, length);

  /// Surface of the input: the page itself (flat, no box).
  static Color inputSurface(ColorScheme scheme) => scheme.surface;

  /// Surface of the output: the page itself, like the input.
  static Color outputSurface(ColorScheme scheme) => scheme.surface;

  /// Bold heading style of the flat sections ("Refine & learn").
  static TextStyle? headingStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.2);
}

/// How a [TranslateFlatCard] is drawn.
enum TranslateCardLook {
  /// No box: content on the page, a hairline above it (X rows).
  section,

  /// No box and no line (input and output).
  plain,

  /// A 16 px hairline-outlined box without fill (X's quoted post).
  quote,
}

/// The translate screen's replacement for filled cards: a flat, unfilled
/// [Card] (keeps its `semanticContainer` and clipping) separated by a
/// hairline ([TranslateCardLook.section]), outlined like a quoted post
/// ([TranslateCardLook.quote]) or plain.
class TranslateFlatCard extends StatelessWidget {
  const new({
    required this.child,
    this.look = TranslateCardLook.section,
    this.semanticContainer = true,
    this.clipBehavior = Clip.none,
    super.key,
  });

  final Widget child;
  final TranslateCardLook look;
  final bool semanticContainer;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: AppPalette.of(context).hairline);
    final shape = switch (look) {
      TranslateCardLook.section => Border(top: side),
      TranslateCardLook.plain => const Border(),
      TranslateCardLook.quote => RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
        side: side,
      ),
    };
    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: semanticContainer,
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: look == TranslateCardLook.quote
          ? Clip.antiAlias
          : clipBehavior,
      shape: shape,
      child: child,
    );
  }
}

/// A row of the X-thread layout: a [LanguageAvatar] for [code] at the
/// start, [child] beside it, and (with [connector]) a thin vertical line
/// from below the avatar down to the next row's avatar.
class TranslateThreadRow extends StatelessWidget {
  const new({
    required this.code,
    required this.child,
    this.connector = false,
    this.avatarTop = 8,
    super.key,
  });

  /// Language code of the avatar.
  final String code;
  final Widget child;
  final bool connector;

  /// Offset of the avatar from the top (to line it up with the first line
  /// of text).
  final double avatarTop;

  @override
  Widget build(BuildContext context) {
    const size = TranslateLayout.avatarSize;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: size + TranslateLayout.avatarGap,
          ),
          child: child,
        ),
        PositionedDirectional(
          start: 0,
          top: avatarTop,
          child: LanguageAvatar(code: code),
        ),
        if (connector)
          PositionedDirectional(
            key: const Key('translate_thread_connector'),
            start: (size - TranslateLayout.connectorWidth) / 2,
            top: avatarTop + size + 4,
            bottom: 0,
            width: TranslateLayout.connectorWidth,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppPalette.of(context).hairline,
                  borderRadius: const BorderRadius.all(Radius.circular(1)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A bold heading that names a group of the translate screen ("Refine &
/// learn"), a header for screen readers.
class TranslateSectionHeader extends StatelessWidget {
  const new(this.title, {this.icon, super.key});

  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, top: 12, bottom: 8),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                style: TranslateLayout.headingStyle(context)
                    ?.copyWith(color: theme.colorScheme.onSurface),
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

/// Styles the chips below it as X topic pills: hairline-outlined
/// stadiums without fill, bold labels and accent icons; selected pills
/// take an accent outline and a faint accent tint (plus their check mark,
/// so selection is not shown by colour alone).
class TranslatePills extends StatelessWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final accent = scheme.primary;
    return Theme(
      data: theme.copyWith(
        // Flat chips paint the canvas colour: let the page show through.
        canvasColor: Colors.transparent,
        chipTheme: theme.chipTheme.copyWith(
          shape: const StadiumBorder(),
          side: WidgetStateBorderSide.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : palette.hairline,
            ),
          ),
          color: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          labelStyle: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
          iconTheme: IconThemeData(color: accent, size: 18),
          checkmarkColor: accent,
          showCheckmark: true,
        ),
      ),
      child: child,
    );
  }
}
