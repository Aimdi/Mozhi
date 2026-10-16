import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Corner radius used by flat cards (a hairline box, no fill).
const double kCardRadius = 16;

/// Corner radius of small badges, menus and text fields.
const double kChipRadius = 8;

/// Corner radius of the top of bottom sheets.
const double kSheetRadius = 20;

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
    required this.border,
    required this.inputBorder,
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
    border: Color(0xFFCFD9DE),
    inputBorder: Color(0xFFCFD9DE),
  );

  /// Dark blue-grey ("Dim").
  static const dim = AppTones(
    surface: Color(0xFF15202B),
    subtle: Color(0xFF192734),
    raised: Color(0xFF1E2732),
    raisedHigh: Color(0xFF273340),
    raisedHighest: Color(0xFF2F3B47),
    text: Color(0xFFF7F9F9),
    secondaryText: Color(0xFF8B98A5),
    hairline: Color(0xFF38444D),
    border: Color(0xFF536471),
    inputBorder: Color(0xFF38444D),
  );

  /// True black ("Lights out").
  static const lightsOut = AppTones(
    surface: Color(0xFF000000),
    subtle: Color(0xFF0A0A0B),
    raised: Color(0xFF16181C),
    raisedHigh: Color(0xFF1D1F23),
    raisedHighest: Color(0xFF202327),
    text: Color(0xFFE7E9EA),
    secondaryText: Color(0xFF71767B),
    hairline: Color(0xFF2F3336),
    border: Color(0xFF536471),
    inputBorder: Color(0xFF333639),
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

  /// Metadata and subtitles.
  final Color secondaryText;

  /// 1 px separators.
  final Color hairline;

  /// Stronger borders (outlined buttons, chips).
  final Color border;

  /// Borders of text fields.
  final Color inputBorder;

  /// The tones for [brightness]; [lightsOut] picks black over Dim.
  static AppTones of(Brightness brightness, {bool lightsOut = false}) {
    if (brightness == Brightness.light) return light;
    return lightsOut ? AppTones.lightsOut : dim;
  }

  /// The [AppPalette] registered on themes with these tones.
  AppPalette get palette => AppPalette(
    hairline: hairline,
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
  /// theme is "Dim", or "Lights out" (black) with [AppSettings.pureBlack].
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
    outline: tones.border,
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
ThemeData buildAppTheme(ColorScheme scheme, {AppPalette? palette}) {
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
    borderRadius: BorderRadius.circular(kChipRadius),
    borderSide: BorderSide(color: _tonesOf(scheme).inputBorder),
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
    borderRadius: const BorderRadius.all(Radius.circular(12)),
    side: hairline,
  );

  return base.copyWith(
    extensions: [pal],
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
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(kCardRadius)),
        side: hairline,
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      trackOutlineWidth: const WidgetStatePropertyAll(0),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // Icon-only on a blurred bar: no fill, no indicator pill.
      backgroundColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      height: 56,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 26,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : pal.secondaryText,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium?.copyWith(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w500,
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
      selectedLabelTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kSheetRadius)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
      ),
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

TextTheme _textTheme(TextTheme base) {
  TextStyle? heading(TextStyle? style, double spacing) =>
      style?.copyWith(fontWeight: FontWeight.w800, letterSpacing: spacing);
  return base.copyWith(
    displayLarge: heading(base.displayLarge, -1),
    displayMedium: heading(base.displayMedium, -0.8),
    displaySmall: heading(base.displaySmall, -0.6),
    headlineLarge: heading(base.headlineLarge, -0.6),
    headlineMedium: heading(base.headlineMedium, -0.5),
    headlineSmall: heading(base.headlineSmall, -0.4),
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
    ),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.4),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 15, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(height: 1.4),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700),
  );
}
