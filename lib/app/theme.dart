import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Corner radii (logical pixels) shared by the screens, in the soft,
/// rounded style of Kagi Translate: chips, buttons and other controls are
/// pills ([StadiumBorder]); boxes use these. Use them instead of ad-hoc
/// radii so shapes stay consistent.
abstract final class AppRadius {
  /// Small badges and tags inside a row (not controls: those are pills).
  static const double badge = 8;

  /// Menus, pop-ups, snack bars and small boxes nested in a row or card.
  static const double menu = 16;

  /// Text and search fields.
  static const double field = 20;

  /// Cards and outlined boxes (a hairline box, no fill).
  static const double card = 24;

  /// The large surfaces: bottom sheets (their top corners), dialogs and
  /// the translate composer.
  static const double sheet = 28;

  /// [card] as a [BorderRadius].
  static const BorderRadius cardBorderRadius = BorderRadius.all(
    Radius.circular(card),
  );

  /// [field] as a [BorderRadius].
  static const BorderRadius fieldBorderRadius = BorderRadius.all(
    Radius.circular(field),
  );
}

/// The font family of the terminal look (JetBrains Mono, bundled under
/// `assets/fonts/jetbrains_mono`, SIL Open Font License 1.1). Scripts it
/// lacks (Arabic, Devanagari, CJK, Tamil …) fall back to the system fonts.
const String kTerminalFontFamily = 'JetBrainsMono';

/// The look of the current theme ([AppSettings.style]), registered on
/// every theme by [buildAppTheme]: the corner radii, the shape of
/// controls and whether the screens use the terminal layout. Read it with
/// [AppLook.of] instead of [AppRadius] where a shape is drawn, so the
/// terminal look stays square.
@immutable
class AppLook extends ThemeExtension<AppLook> {
  const new({
    required this.style,
    required this.badge,
    required this.menu,
    required this.field,
    required this.card,
    required this.sheet,
  });

  /// The rounded look ([AppRadius]).
  static const classic = AppLook(
    style: AppStyle.classic,
    badge: AppRadius.badge,
    menu: AppRadius.menu,
    field: AppRadius.field,
    card: AppRadius.card,
    sheet: AppRadius.sheet,
  );

  /// The terminal look: square corners everywhere.
  static const terminal = AppLook(
    style: AppStyle.terminal,
    badge: 0,
    menu: 0,
    field: 0,
    card: 0,
    sheet: 0,
  );

  /// The look of [style].
  static AppLook forStyle(AppStyle style) => switch (style) {
    AppStyle.terminal => terminal,
    AppStyle.classic => classic,
  };

  /// The look of [context]'s theme ([classic] when none is registered).
  static AppLook of(BuildContext context) =>
      Theme.of(context).extension<AppLook>() ?? classic;

  final AppStyle style;

  /// Corner radii, as [AppRadius] (all 0 in the terminal look).
  final double badge;
  final double menu;
  final double field;
  final double card;
  final double sheet;

  /// Whether the screens use the terminal layout and decorations.
  bool get isTerminal => style == AppStyle.terminal;

  /// The shape of buttons, chips and other controls: a pill
  /// ([StadiumBorder]), or a square box in the terminal look.
  OutlinedBorder get control => isTerminal
      ? const RoundedRectangleBorder()
      : const StadiumBorder();

  /// [badge] as a [BorderRadius].
  BorderRadius get badgeRadius => BorderRadius.circular(badge);

  /// [menu] as a [BorderRadius].
  BorderRadius get menuRadius => BorderRadius.circular(menu);

  /// [field] as a [BorderRadius].
  BorderRadius get fieldRadius => BorderRadius.circular(field);

  /// [card] as a [BorderRadius].
  BorderRadius get cardRadius => BorderRadius.circular(card);

  /// [sheet] as a [BorderRadius].
  BorderRadius get sheetRadius => BorderRadius.circular(sheet);

  /// A radius for a control drawn by hand: [pill] (a pill's half
  /// height) in the classic look, 0 in the terminal look.
  double controlRadius(double pill) => isTerminal ? 0 : pill;

  @override
  AppLook copyWith({
    AppStyle? style,
    double? badge,
    double? menu,
    double? field,
    double? card,
    double? sheet,
  }) => AppLook(
    style: style ?? this.style,
    badge: badge ?? this.badge,
    menu: menu ?? this.menu,
    field: field ?? this.field,
    card: card ?? this.card,
    sheet: sheet ?? this.sheet,
  );

  @override
  AppLook lerp(AppLook? other, double t) => t < 0.5 || other == null
      ? this
      : other;
}

/// Corner radius used by flat cards (a hairline box, no fill).
const double kCardRadius = AppRadius.card;

/// Corner radius of small badges ([AppRadius.badge]).
const double kChipRadius = AppRadius.badge;

/// Corner radius of the top of bottom sheets.
const double kSheetRadius = AppRadius.sheet;

/// Spacing scale (logical pixels) shared by the screens: use these instead
/// of ad-hoc gaps so groups line up.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Width (logical pixels) from which the app switches to the expanded
/// layout (navigation rail, side-by-side panes).
const double kExpandedBreakpoint = 840;

/// Height (logical pixels) of the bottom navigation bar: an icon with its
/// label below it.
const double kNavigationBarHeight = 64;

/// The default accent (X blue).
const Color kDefaultAccent = Color(0xFF1D9BF0);

/// Minimum contrast of text against its background (WCAG 1.4.3 AA), with
/// a little headroom so 8-bit rounding never drops below 4.5:1.
const double kTextContrast = 4.6;

/// Minimum contrast of icons and control parts (WCAG 1.4.11).
const double kNonTextContrast = 3;

/// The neutral, untinted surface tones of the three looks.
@immutable
class AppTones {
  const new({
    required this.surface,
    required this.raised,
    required this.raisedHigh,
    required this.raisedHighest,
    required this.subtle,
    required this.text,
    required this.secondaryText,
    required this.hairline,
    required this.controlOutline,
  });

  /// White.
  static const light = AppTones(
    surface: Color(0xFFFFFFFF),
    subtle: Color(0xFFF7F9F9),
    raised: Color(0xFFF7F9F9),
    raisedHigh: Color(0xFFEFF3F4),
    raisedHighest: Color(0xFFE7ECEE),
    text: Color(0xFF0F1419),
    secondaryText: Color(0xFF536471),
    hairline: Color(0xFFEFF3F4),
    controlOutline: Color(0xFF7B8A97),
  );

  /// Dark blue-grey ("Dim").
  static const dim = AppTones(
    surface: Color(0xFF15202B),
    subtle: Color(0xFF192734),
    raised: Color(0xFF1E2732),
    raisedHigh: Color(0xFF273340),
    raisedHighest: Color(0xFF2F3B47),
    text: Color(0xFFF7F9F9),
    // Lighter than X's #8B98A5: 4.6:1 on the raised containers too.
    secondaryText: Color(0xFF919DA9),
    hairline: Color(0xFF38444D),
    controlOutline: Color(0xFF6E7E8C),
  );

  /// True black ("Lights out").
  static const lightsOut = AppTones(
    surface: Color(0xFF000000),
    subtle: Color(0xFF0A0A0B),
    raised: Color(0xFF16181C),
    raisedHigh: Color(0xFF1D1F23),
    raisedHighest: Color(0xFF202327),
    text: Color(0xFFE7E9EA),
    // Lighter than X's #71767B (4.6:1 on black only): 4.6:1 on the raised
    // containers too.
    secondaryText: Color(0xFF83888D),
    hairline: Color(0xFF2F3336),
    controlOutline: Color(0xFF616C77),
  );

  /// Page background.
  final Color surface;

  /// Barely raised (low containers).
  final Color subtle;

  /// Raised panels (menus, containers).
  final Color raised;
  final Color raisedHigh;
  final Color raisedHighest;

  /// Primary text.
  final Color text;

  /// Metadata and subtitles: at least 4.6:1 ([kTextContrast]) on [surface],
  /// [subtle], [raised] and [raisedHigh].
  final Color secondaryText;

  /// 1 px separators (decorative: no contrast needed).
  final Color hairline;

  /// The outlines of interactive controls: text fields and the composer,
  /// outlined buttons, chips and pills, segmented buttons (WCAG 1.4.11:
  /// at least 3:1 on [surface], [subtle], [raised] and [raisedHigh]). The
  /// scheme's `outline`.
  final Color controlOutline;

  /// The tones for [brightness]; [lightsOut] picks black over Dim.
  static AppTones of(Brightness brightness, {bool lightsOut = false}) {
    if (brightness == Brightness.light) return light;
    return lightsOut ? AppTones.lightsOut : dim;
  }

  /// The [AppPalette] registered on themes with these tones.
  AppPalette get palette => AppPalette(
    hairline: hairline,
    controlOutline: controlOutline,
    secondaryText: secondaryText,
    like: const Color(0xFFF91880),
    success: const Color(0xFF00BA7C),
    barBackground: surface.withValues(alpha: 0.85),
  );
}

/// A matching pair of light and dark themes.
@immutable
class AppThemes {
  const new({required this.light, required this.dark});

  /// Builds the themes for [settings].
  ///
  /// The accent is [AppSettings.seedColor], or the platform's Material You
  /// primary ([lightDynamic] / [darkDynamic]) when [AppSettings.dynamicColor]
  /// is on and one was reported. Surfaces are always neutral; the dark
  /// theme is "Lights out" (black) with [AppSettings.pureBlack] (the
  /// default), else "Dim".
  factory fromSettings(
    AppSettings settings, {
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    final seed = Color(settings.seedColor);
    return AppThemes(
      light: buildAppTheme(
        appColorScheme(
          brightness: Brightness.light,
          seedColor: seed,
          dynamicScheme: settings.dynamicColor ? lightDynamic : null,
        ),
      ),
      dark: buildAppTheme(
        appColorScheme(
          brightness: Brightness.dark,
          seedColor: seed,
          dynamicScheme: settings.dynamicColor ? darkDynamic : null,
          pureBlack: settings.pureBlack,
        ),
      ),
    );
  }

  final ThemeData light;
  final ThemeData dark;
}

/// WCAG contrast ratio of two opaque colours (1 to 21).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// [color] with its HSL lightness moved (darker when [darken], else
/// lighter) in small steps until it has [minContrast] against [against].
/// Keeps the hue; returns [color] itself when it already passes.
Color accentWithContrast(
  Color color,
  Color against, {
  required double minContrast,
  required bool darken,
}) {
  final opaque = color.withValues(alpha: 1);
  if (_contrast(opaque, against) >= minContrast) return opaque;
  final hsl = HSLColor.fromColor(opaque);
  var lightness = hsl.lightness;
  var result = opaque;
  while (_contrast(result, against) < minContrast) {
    lightness = darken ? lightness - 0.01 : lightness + 0.01;
    if (lightness <= 0 || lightness >= 1) {
      return darken ? Colors.black : Colors.white;
    }
    result = hsl.withLightness(lightness).toColor();
  }
  return result;
}

/// The color scheme for [brightness].
///
/// Surfaces are neutral ([AppTones]): white, Dim, or – with [pureBlack] –
/// Lights out (ignored for light schemes). The accent is [seedColor], or
/// [dynamicScheme]'s primary (Material You) when given with the same
/// brightness; it is darkened (light) or lightened (dark) only as far as
/// needed to read as text on the surface (≥ 4.5:1). `primaryContainer` is
/// a darker accent carrying white text (≥ 4.5:1) for filled text surfaces.
ColorScheme appColorScheme({
  required Brightness brightness,
  required Color seedColor,
  ColorScheme? dynamicScheme,
  bool pureBlack = false,
}) {
  final dark = brightness == Brightness.dark;
  final tones = AppTones.of(brightness, lightsOut: pureBlack);
  final accent =
      (dynamicScheme != null && dynamicScheme.brightness == brightness)
      ? dynamicScheme.primary
      : seedColor;
  final base = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
  final primary = accentWithContrast(
    accent,
    tones.surface,
    minContrast: kTextContrast,
    darken: !dark,
  );
  // White text when it reads (≥ 4.5:1), else near-black, else black.
  final onPrimary = [Colors.white, const Color(0xFF0F1419)].firstWhere(
    (c) => _contrast(c, primary) >= kTextContrast,
    orElse: () => Colors.black,
  );
  final container = accentWithContrast(
    accent,
    Colors.white,
    minContrast: kTextContrast,
    darken: true,
  );
  return base.copyWith(
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: container,
    onPrimaryContainer: Colors.white,
    secondary: tones.secondaryText,
    onSecondary: tones.surface,
    secondaryContainer: tones.raisedHigh,
    onSecondaryContainer: tones.text,
    surface: tones.surface,
    onSurface: tones.text,
    onSurfaceVariant: tones.secondaryText,
    surfaceDim: dark ? tones.surface : tones.raisedHigh,
    surfaceBright: dark ? tones.raised : tones.surface,
    surfaceContainerLowest: tones.surface,
    surfaceContainerLow: tones.subtle,
    surfaceContainer: tones.raised,
    surfaceContainerHigh: tones.raisedHigh,
    surfaceContainerHighest: tones.raisedHighest,
    // Control outlines (3:1); decorative lines use outlineVariant.
    outline: tones.controlOutline,
    outlineVariant: tones.hairline,
    // Snack bars: dark on light, light on dark.
    inverseSurface: tones.text,
    onInverseSurface: tones.surface,
    inversePrimary: accentWithContrast(
      accent,
      tones.text,
      minContrast: kTextContrast,
      darken: dark,
    ),
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
    scrim: Colors.black,
  );
}

/// The [AppTones] of [scheme]'s look (light, Dim or Lights out).
AppTones _tonesOf(ColorScheme scheme) => AppTones.of(
  scheme.brightness,
  lightsOut: scheme.surface.toARGB32() == 0xFF000000,
);

/// The [AppPalette] matching [scheme]'s look (light, Dim or Lights out).
AppPalette appPalette(ColorScheme scheme) => _tonesOf(scheme).palette;

/// Material 3 theme with Mozhi's X-inspired component styling for
/// [scheme]: flat neutral surfaces, hairlines, pill buttons and bold type.
///
/// Registers [palette] (default: [appPalette] of [scheme]).
///
/// Registers [look] too (default: [AppLook.classic]); the terminal look's
/// component styling is built from it.
ThemeData buildAppTheme(
  ColorScheme scheme, {
  AppPalette? palette,
  AppLook look = AppLook.classic,
}) {
  final pal = palette ?? appPalette(scheme);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: scheme.brightness,
  );
  final textTheme = _textTheme(base.textTheme);
  final hairline = BorderSide(color: pal.hairline);
  const pill = StadiumBorder();
  final inputBorder = OutlineInputBorder(
    borderRadius: AppRadius.fieldBorderRadius,
    borderSide: BorderSide(color: scheme.outline),
  );
  final buttonText = textTheme.labelLarge?.copyWith(
    fontWeight: FontWeight.w700,
    fontSize: 15,
  );
  final selectedTint = Color.alphaBlend(
    scheme.primary.withValues(alpha: 0.12),
    scheme.surface,
  );
  // The FAB and the "on" switch track carry white: darken the accent just
  // enough for that (icons and controls need 3:1).
  final whiteOnAccent = accentWithContrast(
    scheme.primary,
    Colors.white,
    minContrast: kNonTextContrast + 0.05,
    darken: true,
  );
  final menuShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(AppRadius.menu)),
    side: hairline,
  );
  // Sheets and dialogs carry a hairline too: in Lights out they are as
  // black as the dimmed page behind them.
  final sheetShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(AppRadius.sheet),
    ),
    side: hairline,
  );
  final dialogShape = RoundedRectangleBorder(
    borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sheet)),
    side: hairline,
  );

  return base.copyWith(
    extensions: [pal, look],
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: pal.hairline,
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: hairline),
      // Page titles: big and bold, like Kagi's.
      titleTextStyle: textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.cardBorderRadius,
        side: hairline,
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      // A little more room at the sides for the rounder corners.
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: pal.hairline),
      ),
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      hintStyle: TextStyle(color: pal.secondaryText),
    ),
    chipTheme: ChipThemeData(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: textTheme.labelLarge?.copyWith(color: scheme.onSurface),
      backgroundColor: Colors.transparent,
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline,
        ),
      ),
      shape: pill,
      selectedColor: selectedTint,
      checkmarkColor: scheme.primary,
      iconTheme: IconThemeData(color: scheme.primary, size: 18),
      // Selected filter/choice chips show a check mark, so selection is
      // not conveyed by colour alone (WCAG 1.4.1).
      showCheckmark: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      // X's primary call to action: an inverse pill (black on light,
      // white on dark).
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(buttonText),
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        ),
        shape: const WidgetStatePropertyAll(pill),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.12)
              : scheme.onSurface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : scheme.surface,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : scheme.surface,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)
              ? scheme.surface.withValues(alpha: 0.12)
              : null,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      // The accent pill (white text on the darker accent, ≥ 4.5:1).
      style: ElevatedButton.styleFrom(
        textStyle: buttonText,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: pill,
        elevation: 0,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        iconColor: scheme.onPrimaryContainer,
        surfaceTintColor: Colors.transparent,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        textStyle: buttonText,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: pill,
        foregroundColor: scheme.onSurface,
        iconColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: buttonText,
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        shape: pill,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        textStyle: buttonText,
        selectedBackgroundColor: selectedTint,
        selectedForegroundColor: scheme.onSurface,
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline),
        shape: pill,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      // A circle (stadium when extended) on the accent with a white icon.
      shape: pill,
      backgroundColor: whiteOnAccent,
      foregroundColor: Colors.white,
      elevation: 3,
      focusElevation: 4,
      hoverElevation: 4,
      highlightElevation: 6,
      extendedTextStyle: buttonText,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: pal.secondaryText,
      labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 4),
        borderRadius: const BorderRadius.all(Radius.circular(2)),
      ),
      dividerColor: pal.hairline,
      dividerHeight: 1,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: RoundedRectangleBorder(),
      collapsedShape: RoundedRectangleBorder(),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(hairline),
        shape: WidgetStatePropertyAll(menuShape),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: menuShape,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: pal.secondaryText,
      // Flat rows: the highlight fills the row edge to edge.
      shape: const RoundedRectangleBorder(),
      titleTextStyle: textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(
        color: pal.secondaryText,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.surface
            : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: 0.12);
        }
        return states.contains(WidgetState.selected)
            ? whiteOnAccent
            : pal.secondaryText;
      }),
      // No outline, but for keyboard focus (the focused state is only set
      // while focus is shown): a 2 px accent ring around the track.
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? scheme.primary
            : Colors.transparent,
      ),
      trackOutlineWidth: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused) ? 2 : 0,
      ),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // Labelled icons on a blurred bar: no fill, no indicator pill (the
      // shell marks the selection with an accent bar and a bold label).
      backgroundColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      height: kNavigationBarHeight,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelPadding: const EdgeInsets.only(top: 2),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 26,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : pal.secondaryText,
        ),
      ),
      // One line: a label too long for its quarter of a narrow phone
      // (Tamil, Italian) ends in an ellipsis; its tooltip and its name for
      // screen readers stay whole.
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : pal.secondaryText,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w500,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      // X web's sidebar: no tint, no indicator pill (the shell adds a
      // marker when collapsed), bold labels.
      backgroundColor: scheme.surface,
      indicatorColor: Colors.transparent,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -1,
      selectedIconTheme: IconThemeData(color: scheme.onSurface, size: 26),
      unselectedIconTheme: IconThemeData(color: scheme.onSurface, size: 26),
      // Labels, not headings: they keep their size.
      selectedLabelTextStyle: textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.menu)),
      ),
      elevation: 2,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: scheme.surface,
      modalBackgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: scheme.outline,
      shape: sheetShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: dialogShape,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    dividerTheme: DividerThemeData(color: pal.hairline, space: 1, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: pal.hairline,
      circularTrackColor: Colors.transparent,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: const WidgetStatePropertyAll(pill),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

/// Sizes (logical pixels) of the bold headings of [buildAppTheme]'s text
/// theme: bigger than Material's, like Kagi Translate's page titles and
/// section headings. Body, label and `titleSmall` styles (the labels of
/// controls such as the language bar) keep Material's sizes.
abstract final class AppTypeScale {
  /// `headlineLarge`.
  static const double headlineLarge = 34;

  /// `headlineMedium`: the greetings of empty screens.
  static const double headlineMedium = 30;

  /// `headlineSmall`: page titles (app bars).
  static const double headlineSmall = 26;

  /// `titleLarge`: section headings (settings sections, sheet and dialog
  /// titles, "Refine & learn", history days).
  static const double titleLarge = 22;

  /// `titleMedium`: sub-headings ("Style" in the options sheet).
  static const double titleMedium = 17;
}

TextTheme _textTheme(TextTheme base) {
  TextStyle? heading(TextStyle? style, double spacing, [double? size]) =>
      style?.copyWith(
        fontSize: size,
        fontWeight: FontWeight.w800,
        letterSpacing: spacing,
      );
  return base.copyWith(
    displayLarge: heading(base.displayLarge, -1),
    displayMedium: heading(base.displayMedium, -0.8),
    displaySmall: heading(base.displaySmall, -0.6),
    headlineLarge: heading(
      base.headlineLarge,
      -0.7,
      AppTypeScale.headlineLarge,
    ),
    headlineMedium: heading(
      base.headlineMedium,
      -0.6,
      AppTypeScale.headlineMedium,
    ),
    headlineSmall: heading(
      base.headlineSmall,
      -0.5,
      AppTypeScale.headlineSmall,
    ),
    titleLarge: heading(base.titleLarge, -0.4, AppTypeScale.titleLarge),
    // Also emphasised values (a dropdown's value, a proofread change): a
    // bold 700; sub-headings ask for 800 (see `TranslateLayout`).
    titleMedium: base.titleMedium?.copyWith(
      fontSize: AppTypeScale.titleMedium,
      fontWeight: FontWeight.w700,
    ),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.4),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 15, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(height: 1.4),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700),
  );
}
