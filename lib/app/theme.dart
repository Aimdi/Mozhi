import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Corner radius used by cards, text fields and other large surfaces.
const double kCardRadius = 16;

/// Corner radius of chips, small badges and menus.
const double kChipRadius = 8;

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

/// A matching pair of light and dark themes.
@immutable
class AppThemes {
  const new({required this.light, required this.dark});

  /// Builds the themes for [settings].
  ///
  /// When [AppSettings.dynamicColor] is on and the platform reported a
  /// palette ([lightDynamic] / [darkDynamic]), it is used; otherwise the
  /// palette is generated from [AppSettings.seedColor].
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

/// The color scheme for [brightness].
///
/// Uses [dynamicScheme] (Material You) when given, else a tonal-spot scheme
/// generated from [seedColor]. [pureBlack] turns dark surfaces AMOLED black
/// (ignored for light schemes).
ColorScheme appColorScheme({
  required Brightness brightness,
  required Color seedColor,
  ColorScheme? dynamicScheme,
  bool pureBlack = false,
}) {
  final scheme =
      (dynamicScheme != null && dynamicScheme.brightness == brightness)
      ? dynamicScheme
      : ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  if (!pureBlack || brightness != Brightness.dark) return scheme;
  return scheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0B0B0D),
    surfaceContainer: const Color(0xFF121214),
  );
}

/// Material 3 theme with Mozhi's component styling for [scheme].
ThemeData buildAppTheme(ColorScheme scheme) {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: scheme.brightness,
  );
  final textTheme = _textTheme(base.textTheme);
  const cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(kCardRadius),
    borderSide: BorderSide.none,
  );

  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      // A flat tonal shift (no shadow) once content scrolls under.
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: cardShape,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    chipTheme: ChipThemeData(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: textTheme.labelLarge,
      side: BorderSide(color: scheme.outlineVariant),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(kChipRadius)),
      ),
      selectedColor: scheme.secondaryContainer,
      checkmarkColor: scheme.onSecondaryContainer,
      iconTheme: IconThemeData(color: scheme.primary, size: 18),
      // Selected filter/choice chips show a check mark, so selection is
      // not conveyed by colour alone (WCAG 1.4.1).
      showCheckmark: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        textStyle: textTheme.labelLarge,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        textStyle: textTheme.labelLarge,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: textTheme.labelLarge,
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        textStyle: textTheme.labelLarge,
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      // Tiles sit in cards: no lines of their own.
      shape: RoundedRectangleBorder(),
      collapsedShape: RoundedRectangleBorder(),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(kChipRadius * 1.5)),
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(kChipRadius * 1.5)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: scheme.onSurfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      surfaceTintColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium?.copyWith(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      // The rail is chrome: a quiet tonal panel beside the page.
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -1,
      selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

TextTheme _textTheme(TextTheme base) => base.copyWith(
  displaySmall: base.displaySmall?.copyWith(letterSpacing: -0.5),
  headlineLarge: base.headlineLarge?.copyWith(
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
  ),
  headlineMedium: base.headlineMedium?.copyWith(
    fontWeight: FontWeight.w600,
    letterSpacing: -0.25,
  ),
  headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
  titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
  titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
  bodySmall: base.bodySmall?.copyWith(height: 1.4),
  bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
  bodyMedium: base.bodyMedium?.copyWith(height: 1.4),
  labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
);
