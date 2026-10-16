import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

void main() {
  const blue = Color(0xFF1D9BF0);
  const white = Color(0xFFFFFFFF);

  ColorScheme scheme(
    Brightness brightness, {
    Color seed = blue,
    bool pureBlack = false,
    ColorScheme? dynamicScheme,
  }) => appColorScheme(
    brightness: brightness,
    seedColor: seed,
    pureBlack: pureBlack,
    dynamicScheme: dynamicScheme,
  );

  double hue(Color color) => HSLColor.fromColor(color).hue;

  group('AppTones', () {
    test('picks light, Dim or Lights out', () {
      expect(AppTones.of(Brightness.light), AppTones.light);
      expect(AppTones.of(Brightness.light, lightsOut: true), AppTones.light);
      expect(AppTones.of(Brightness.dark), AppTones.dim);
      expect(AppTones.of(Brightness.dark, lightsOut: true), AppTones.lightsOut);
    });

    test('builds the palette with the X hairline and secondary tones', () {
      final palette = AppTones.dim.palette;
      expect(palette.hairline, const Color(0xFF38444D));
      expect(palette.secondaryText, const Color(0xFF8B98A5));
      expect(palette.like, const Color(0xFFF91880));
      expect(palette.success, const Color(0xFF00BA7C));
      expect(palette.barBackground.a, closeTo(0.85, 0.01));
      expect(
        palette.barBackground.withValues(alpha: 1),
        const Color(0xFF15202B),
      );
    });
  });

  group('accentWithContrast', () {
    test('keeps a colour that already contrasts enough', () {
      expect(
        accentWithContrast(
          const Color(0xFF000000),
          white,
          minContrast: 4.5,
          darken: true,
        ),
        const Color(0xFF000000),
      );
    });

    test('darkens towards the target contrast, keeping the hue', () {
      final darker = accentWithContrast(
        blue,
        white,
        minContrast: 4.5,
        darken: true,
      );
      expect(contrastRatio(darker, white), greaterThanOrEqualTo(4.5));
      expect(hue(darker), closeTo(hue(blue), 1));
      expect(
        HSLColor.fromColor(darker).lightness,
        lessThan(HSLColor.fromColor(blue).lightness),
      );
    });

    test('lightens when asked', () {
      const purple = Color(0xFF7856FF);
      final lighter = accentWithContrast(
        purple,
        AppTones.dim.surface,
        minContrast: 4.6,
        darken: false,
      );
      expect(
        contrastRatio(lighter, AppTones.dim.surface),
        greaterThanOrEqualTo(4.6),
      );
      expect(
        HSLColor.fromColor(lighter).lightness,
        greaterThan(HSLColor.fromColor(purple).lightness),
      );
    });

    test('ends at black or white when the target is unreachable', () {
      expect(
        accentWithContrast(blue, white, minContrast: 30, darken: true),
        Colors.black,
      );
      expect(
        accentWithContrast(
          blue,
          const Color(0xFF000000),
          minContrast: 30,
          darken: false,
        ),
        Colors.white,
      );
    });
  });

  group('appColorScheme', () {
    test('light: white neutral surfaces and X text tones', () {
      final light = scheme(Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.surface, white);
      expect(light.onSurface, const Color(0xFF0F1419));
      expect(light.onSurfaceVariant, const Color(0xFF536471));
      expect(light.outline, const Color(0xFFCFD9DE));
      expect(light.outlineVariant, const Color(0xFFEFF3F4));
      expect(light.surfaceContainerLowest, white);
      expect(light.surfaceTint, Colors.transparent);
    });

    test('dark: Dim by default', () {
      final dim = scheme(Brightness.dark);
      expect(dim.surface, const Color(0xFF15202B));
      expect(dim.surfaceContainer, const Color(0xFF1E2732));
      expect(dim.onSurface, const Color(0xFFF7F9F9));
      expect(dim.onSurfaceVariant, const Color(0xFF8B98A5));
      expect(dim.outlineVariant, const Color(0xFF38444D));
    });

    test('dark: Lights out with pure black', () {
      final black = scheme(Brightness.dark, pureBlack: true);
      expect(black.surface, const Color(0xFF000000));
      expect(black.surfaceContainerLowest, const Color(0xFF000000));
      expect(black.surfaceDim, const Color(0xFF000000));
      expect(black.surfaceContainer, const Color(0xFF16181C));
      expect(black.onSurface, const Color(0xFFE7E9EA));
      expect(black.onSurfaceVariant, const Color(0xFF71767B));
      expect(black.outlineVariant, const Color(0xFF2F3336));
    });

    test('pure black does not affect light schemes', () {
      expect(scheme(Brightness.light, pureBlack: true).surface, white);
    });

    test('dark primary is the accent itself', () {
      expect(scheme(Brightness.dark).primary, blue);
      expect(scheme(Brightness.dark, pureBlack: true).primary, blue);
    });

    test('light primary is darkened to read as text on white', () {
      final light = scheme(Brightness.light);
      expect(light.primary, isNot(blue));
      expect(contrastRatio(light.primary, white), greaterThanOrEqualTo(4.5));
      expect(hue(light.primary), closeTo(hue(blue), 1));
      expect(light.onPrimary, white);
    });

    test('a dark accent keeps dark text off it in dark mode', () {
      // Raw blue is too light for white text: onPrimary turns dark.
      final dim = scheme(Brightness.dark);
      expect(dim.onPrimary, const Color(0xFF0F1419));
      expect(contrastRatio(dim.onPrimary, dim.primary), greaterThan(4.5));
    });

    test('primaryContainer is a darker accent carrying white text', () {
      for (final brightness in Brightness.values) {
        final s = scheme(brightness);
        expect(s.onPrimaryContainer, white);
        expect(
          contrastRatio(s.onPrimaryContainer, s.primaryContainer),
          greaterThanOrEqualTo(4.5),
        );
        expect(hue(s.primaryContainer), closeTo(hue(blue), 1));
      }
    });

    test('secondary roles are neutral', () {
      final light = scheme(Brightness.light);
      expect(light.secondaryContainer, AppTones.light.raisedHigh);
      expect(light.onSecondaryContainer, AppTones.light.text);
    });

    test('snack bar colours: inverse surface and readable action', () {
      for (final brightness in Brightness.values) {
        final s = scheme(brightness);
        expect(s.inverseSurface, s.onSurface);
        expect(s.onInverseSurface, s.surface);
        expect(
          contrastRatio(s.inversePrimary, s.inverseSurface),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('every offered accent reaches 4.5:1 as text', () {
      for (final option in AccentColorOption.options) {
        final seed = Color(option.argb);
        final light = scheme(Brightness.light, seed: seed);
        expect(
          contrastRatio(light.primary, light.surface),
          greaterThanOrEqualTo(4.5),
          reason: option.argb.toRadixString(16),
        );
        for (final black in [false, true]) {
          final dark = scheme(Brightness.dark, seed: seed, pureBlack: black);
          expect(
            contrastRatio(dark.primary, dark.surface),
            greaterThanOrEqualTo(4.5),
            reason: option.argb.toRadixString(16),
          );
          expect(
            contrastRatio(dark.onPrimary, dark.primary),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          contrastRatio(light.onPrimaryContainer, light.primaryContainer),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('takes only the accent from a dynamic scheme', () {
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: Brightness.dark,
      );
      final s = scheme(Brightness.dark, dynamicScheme: dynamicScheme);
      expect(s.primary, dynamicScheme.primary);
      expect(s.surface, AppTones.dim.surface);
      expect(s.surface, isNot(dynamicScheme.surface));
    });

    test('ignores a dynamic scheme of the other brightness', () {
      final dynamicScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final s = scheme(Brightness.dark, dynamicScheme: dynamicScheme);
      expect(s.brightness, Brightness.dark);
      expect(s.primary, blue);
    });
  });

  group('appPalette', () {
    test('matches the look of the scheme', () {
      expect(
        appPalette(scheme(Brightness.light)).hairline,
        const Color(0xFFEFF3F4),
      );
      expect(
        appPalette(scheme(Brightness.light)).secondaryText,
        const Color(0xFF536471),
      );
      expect(
        appPalette(scheme(Brightness.dark)).hairline,
        const Color(0xFF38444D),
      );
      expect(
        appPalette(scheme(Brightness.dark, pureBlack: true)).hairline,
        const Color(0xFF2F3336),
      );
      expect(
        appPalette(scheme(Brightness.dark, pureBlack: true)).secondaryText,
        const Color(0xFF71767B),
      );
    });
  });

  group('buildAppTheme', () {
    final light = buildAppTheme(scheme(Brightness.light));
    final dim = buildAppTheme(scheme(Brightness.dark));
    final black = buildAppTheme(scheme(Brightness.dark, pureBlack: true));
    final colors = light.colorScheme;

    T resolve<T>(WidgetStateProperty<T>? property, [Set<WidgetState>? s]) =>
        property!.resolve(s ?? {});

    test('is Material 3 with the scheme on neutral backgrounds', () {
      expect(light.useMaterial3, isTrue);
      expect(light.scaffoldBackgroundColor, white);
      expect(dim.scaffoldBackgroundColor, const Color(0xFF15202B));
      expect(black.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(light.canvasColor, white);
    });

    test('registers the palette of each look', () {
      expect(light.extension<AppPalette>()?.hairline, const Color(0xFFEFF3F4));
      expect(dim.extension<AppPalette>()?.hairline, const Color(0xFF38444D));
      expect(
        dim.extension<AppPalette>()?.secondaryText,
        const Color(0xFF8B98A5),
      );
      expect(black.extension<AppPalette>()?.hairline, const Color(0xFF2F3336));
      expect(
        black.extension<AppPalette>()?.barBackground,
        const Color(0xFF000000).withValues(alpha: 0.85),
      );
      expect(light.dividerTheme.color, const Color(0xFFEFF3F4));
    });

    test('takes an explicit palette', () {
      final palette = AppTones.lightsOut.palette;
      final theme = buildAppTheme(scheme(Brightness.light), palette: palette);
      expect(theme.extension<AppPalette>(), palette);
    });

    test('bold typography', () {
      final text = light.textTheme;
      expect(text.titleLarge?.fontSize, 20);
      expect(text.titleLarge?.fontWeight, FontWeight.w800);
      expect(text.titleLarge?.letterSpacing, lessThan(0));
      expect(text.titleMedium?.fontWeight, FontWeight.w700);
      for (final style in [
        text.displayLarge,
        text.displayMedium,
        text.displaySmall,
        text.headlineLarge,
        text.headlineMedium,
        text.headlineSmall,
      ]) {
        expect(style?.fontWeight, FontWeight.w800);
        expect(style?.letterSpacing, lessThan(0));
      }
      expect(text.bodyLarge?.fontSize, 16);
      expect(text.bodyMedium?.fontSize, 15);
      expect(text.labelLarge?.fontWeight, FontWeight.w700);
    });

    test('filled buttons are inverse pills', () {
      final style = light.filledButtonTheme.style!;
      expect(resolve(style.shape), const StadiumBorder());
      expect(resolve(style.backgroundColor), colors.onSurface);
      expect(resolve(style.foregroundColor), colors.surface);
      expect(resolve(style.iconColor), colors.surface);
      expect(resolve(style.minimumSize)!.height, greaterThanOrEqualTo(44));
      expect(resolve(style.textStyle)?.fontWeight, FontWeight.w700);
      const disabled = {WidgetState.disabled};
      expect(resolve(style.backgroundColor, disabled)?.a, closeTo(0.12, 0.01));
      expect(resolve(style.foregroundColor, disabled)?.a, closeTo(0.38, 0.01));
      expect(resolve(style.iconColor, disabled)?.a, closeTo(0.38, 0.01));
      expect(resolve(style.overlayColor), isNull);
      expect(resolve(style.overlayColor, {WidgetState.pressed}), isNotNull);
      // White on dark: the dark theme's pill is light.
      expect(
        resolve(dim.filledButtonTheme.style!.backgroundColor),
        dim.colorScheme.onSurface,
      );
    });

    test('other buttons are pills too', () {
      expect(
        resolve(light.outlinedButtonTheme.style!.shape),
        const StadiumBorder(),
      );
      expect(
        resolve(light.outlinedButtonTheme.style!.side),
        BorderSide(color: colors.outline),
      );
      expect(
        resolve(light.textButtonTheme.style!.shape),
        const StadiumBorder(),
      );
      final elevated = light.elevatedButtonTheme.style!;
      expect(resolve(elevated.shape), const StadiumBorder());
      expect(resolve(elevated.backgroundColor), colors.primaryContainer);
      expect(resolve(elevated.foregroundColor), colors.onPrimaryContainer);
      expect(
        resolve(light.segmentedButtonTheme.style!.shape),
        const StadiumBorder(),
      );
    });

    test('chips are outlined hairline pills with a check mark', () {
      final chips = light.chipTheme;
      expect(chips.shape, const StadiumBorder());
      expect(chips.showCheckmark, isTrue);
      expect(chips.backgroundColor, Colors.transparent);
      final side = chips.side! as WidgetStateBorderSide;
      expect(side.resolve({})?.color, colors.outline);
      expect(side.resolve({WidgetState.selected})?.color, colors.primary);
    });

    test('cards are flat hairline boxes', () {
      expect(light.cardTheme.elevation, 0);
      expect(light.cardTheme.color, white);
      expect(
        light.cardTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
          side: BorderSide(color: Color(0xFFEFF3F4)),
        ),
      );
    });

    test('inputs are outlined with a 2 px accent focus', () {
      final inputs = light.inputDecorationTheme;
      expect(inputs.filled, isFalse);
      final enabled = inputs.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderRadius, BorderRadius.circular(8));
      expect(enabled.borderSide.color, const Color(0xFFCFD9DE));
      final focused = inputs.focusedBorder! as OutlineInputBorder;
      expect(focused.borderSide.width, 2);
      expect(focused.borderSide.color, colors.primary);
      expect(
        (black.inputDecorationTheme.enabledBorder! as OutlineInputBorder)
            .borderSide
            .color,
        const Color(0xFF333639),
      );
    });

    test('the FAB is an accent circle with a white icon', () {
      for (final theme in [light, dim, black]) {
        final fab = theme.floatingActionButtonTheme;
        expect(fab.shape, const StadiumBorder());
        expect(fab.foregroundColor, white);
        expect(fab.elevation, greaterThan(0));
        expect(
          contrastRatio(white, fab.backgroundColor!),
          greaterThanOrEqualTo(3),
        );
      }
    });

    test('tabs: bold label and a short rounded accent underline', () {
      final tabs = light.tabBarTheme;
      expect(tabs.labelStyle?.fontWeight, FontWeight.w700);
      expect(tabs.indicatorSize, TabBarIndicatorSize.label);
      final indicator = tabs.indicator! as UnderlineTabIndicator;
      expect(indicator.borderSide.color, colors.primary);
      expect(indicator.borderSide.width, inInclusiveRange(3, 4));
      expect(indicator.borderRadius, isNotNull);
      expect(tabs.dividerColor, const Color(0xFFEFF3F4));
    });

    test('app bars: surface, bold title, hairline, no tint', () {
      final bar = light.appBarTheme;
      expect(bar.backgroundColor, white);
      expect(bar.surfaceTintColor, Colors.transparent);
      expect(bar.titleTextStyle?.fontWeight, FontWeight.w800);
      expect(
        bar.shape,
        const Border(bottom: BorderSide(color: Color(0xFFEFF3F4))),
      );
    });

    test('navigation bar: icon only, no indicator', () {
      final nav = light.navigationBarTheme;
      expect(nav.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      expect(nav.indicatorColor, Colors.transparent);
      expect(nav.height, inInclusiveRange(56, 60));
      expect(
        nav.iconTheme!.resolve({WidgetState.selected})?.color,
        colors.onSurface,
      );
      expect(nav.iconTheme!.resolve({})?.color, const Color(0xFF536471));
      expect(
        nav.labelTextStyle!.resolve({WidgetState.selected})?.fontWeight,
        FontWeight.w800,
      );
      expect(nav.labelTextStyle!.resolve({})?.fontWeight, FontWeight.w500);
    });

    test('navigation rail: untinted with bold labels', () {
      final rail = light.navigationRailTheme;
      expect(rail.backgroundColor, white);
      expect(rail.indicatorColor, Colors.transparent);
      expect(rail.selectedLabelTextStyle?.fontWeight, FontWeight.w800);
      expect(rail.unselectedLabelTextStyle?.fontWeight, FontWeight.w400);
    });

    test('switches: accent track, white thumb, no icon', () {
      final switches = light.switchTheme;
      const selected = {WidgetState.selected};
      const disabled = {WidgetState.disabled};
      expect(resolve(switches.thumbColor), white);
      expect(resolve(switches.thumbColor, disabled), colors.surface);
      final on = resolve(switches.trackColor, selected)!;
      expect(contrastRatio(white, on), greaterThanOrEqualTo(3));
      expect(hue(on), closeTo(hue(colors.primary), 1));
      expect(resolve(switches.trackColor), const Color(0xFF536471));
      expect(resolve(switches.trackColor, disabled)?.a, closeTo(0.12, 0.01));
      expect(resolve(switches.thumbIcon), isNull);
      expect(resolve(switches.trackOutlineColor), Colors.transparent);
    });

    test('lists, sheets, dialogs, snack bars and progress', () {
      expect(light.listTileTheme.shape, const RoundedRectangleBorder());
      expect(light.listTileTheme.iconColor, const Color(0xFF536471));
      expect(
        light.bottomSheetTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      );
      expect(light.bottomSheetTheme.backgroundColor, white);
      expect(light.dialogTheme.backgroundColor, white);
      expect(light.dialogTheme.titleTextStyle?.fontWeight, FontWeight.w800);
      expect(
        light.dialogTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      );
      final snack = light.snackBarTheme;
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.backgroundColor, colors.inverseSurface);
      expect(light.progressIndicatorTheme.color, colors.primary);
      expect(resolve(light.searchBarTheme.shape), const StadiumBorder());
      expect(light.popupMenuTheme.color, white);
      expect(
        resolve(light.menuTheme.style!.side),
        const BorderSide(color: Color(0xFFEFF3F4)),
      );
    });
  });

  group('AppThemes.fromSettings', () {
    final lightDynamic = ColorScheme.fromSeed(seedColor: Colors.green);
    final darkDynamic = ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.dark,
    );

    test('defaults to the X blue accent', () {
      expect(const AppSettings().seedColor, 0xFF1D9BF0);
      final themes = AppThemes.fromSettings(
        const AppSettings(dynamicColor: false),
      );
      expect(themes.light.brightness, Brightness.light);
      expect(themes.dark.brightness, Brightness.dark);
      expect(themes.dark.colorScheme.primary, blue);
      expect(themes.dark.colorScheme.surface, const Color(0xFF15202B));
      expect(themes.light.colorScheme.surface, white);
    });

    test('uses the dynamic accent when enabled and available', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(
        themes.light.colorScheme.primary,
        accentWithContrast(
          lightDynamic.primary,
          white,
          minContrast: kTextContrast,
          darken: true,
        ),
      );
      expect(themes.dark.colorScheme.primary, darkDynamic.primary);
      expect(themes.light.colorScheme.surface, white);
    });

    test('ignores dynamic colors when disabled', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(dynamicColor: false, seedColor: 0xFF00BA7C),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.primary, const Color(0xFF00BA7C));
    });

    test('Lights out applies to the dark theme only', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(pureBlack: true),
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.surface, const Color(0xFF000000));
      expect(themes.dark.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(
        themes.dark.extension<AppPalette>()?.hairline,
        const Color(0xFF2F3336),
      );
      expect(themes.light.colorScheme.surface, white);
    });
  });
}
