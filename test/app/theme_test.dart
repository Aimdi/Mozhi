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
      expect(palette.secondaryText, const Color(0xFF919DA9));
      expect(palette.controlOutline, AppTones.dim.controlOutline);
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
      expect(light.outline, const Color(0xFF7B8A97));
      expect(light.outlineVariant, const Color(0xFFEFF3F4));
      expect(light.surfaceContainerLowest, white);
      expect(light.surfaceTint, Colors.transparent);
    });

    test('dark: Dim by default', () {
      final dim = scheme(Brightness.dark);
      expect(dim.surface, const Color(0xFF15202B));
      expect(dim.surfaceContainer, const Color(0xFF1E2732));
      expect(dim.onSurface, const Color(0xFFF7F9F9));
      expect(dim.onSurfaceVariant, const Color(0xFF919DA9));
      expect(dim.outline, const Color(0xFF6E7E8C));
      expect(dim.outlineVariant, const Color(0xFF38444D));
    });

    test('dark: Lights out with pure black', () {
      final black = scheme(Brightness.dark, pureBlack: true);
      expect(black.surface, const Color(0xFF000000));
      expect(black.surfaceContainerLowest, const Color(0xFF000000));
      expect(black.surfaceDim, const Color(0xFF000000));
      expect(black.surfaceContainer, const Color(0xFF16181C));
      expect(black.onSurface, const Color(0xFFE7E9EA));
      expect(black.onSurfaceVariant, const Color(0xFF83888D));
      expect(black.outline, const Color(0xFF616C77));
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

    test('Lavender: the pastel on dark, a darker violet on white', () {
      const lavender = Color(0xFFC4B5FD);
      expect(
        AccentColorOption.options.map((o) => o.argb),
        contains(lavender.toARGB32()),
      );
      for (final black in [false, true]) {
        final dark = scheme(Brightness.dark, seed: lavender, pureBlack: black);
        // Light enough to read as text on Dim and Lights out as it is.
        expect(dark.primary, lavender);
        expect(
          contrastRatio(dark.primary, dark.surface),
          greaterThanOrEqualTo(kTextContrast),
        );
        // Filled with the pastel, buttons carry near-black text.
        expect(dark.onPrimary, const Color(0xFF0F1419));
        expect(
          contrastRatio(dark.onPrimary, dark.primary),
          greaterThanOrEqualTo(kTextContrast),
        );
      }
      // Too light for white: a darker shade of the same hue.
      final light = scheme(Brightness.light, seed: lavender);
      expect(contrastRatio(lavender, white), lessThan(2));
      expect(
        contrastRatio(light.primary, white),
        greaterThanOrEqualTo(kTextContrast),
      );
      expect(hue(light.primary), closeTo(hue(lavender), 1));
      expect(
        HSLColor.fromColor(light.primary).lightness,
        lessThan(HSLColor.fromColor(lavender).lightness),
      );
      expect(light.onPrimary, white);
      // Icons on white (switch track, FAB) get 3:1 too.
      final theme = buildAppTheme(scheme(Brightness.dark, seed: lavender));
      expect(
        contrastRatio(white, theme.floatingActionButtonTheme.backgroundColor!),
        greaterThanOrEqualTo(kNonTextContrast),
      );
    });

    test('a too light seed is darkened the same way (Yellow)', () {
      const yellow = Color(0xFFFFD400);
      final light = scheme(Brightness.light, seed: yellow);
      expect(contrastRatio(light.primary, white), greaterThanOrEqualTo(4.5));
      expect(hue(light.primary), closeTo(hue(yellow), 1));
      expect(scheme(Brightness.dark, seed: yellow).primary, yellow);
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
        const Color(0xFF83888D),
      );
      for (final s in [
        scheme(Brightness.light),
        scheme(Brightness.dark),
        scheme(Brightness.dark, pureBlack: true),
      ]) {
        expect(appPalette(s).controlOutline, s.outline);
      }
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
        const Color(0xFF919DA9),
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

    test('bold, larger headings (Kagi-sized page titles and sections)', () {
      final text = light.textTheme;
      expect(text.headlineLarge?.fontSize, AppTypeScale.headlineLarge);
      expect(text.headlineMedium?.fontSize, AppTypeScale.headlineMedium);
      expect(text.headlineSmall?.fontSize, AppTypeScale.headlineSmall);
      expect(text.titleLarge?.fontSize, AppTypeScale.titleLarge);
      expect(text.titleMedium?.fontSize, AppTypeScale.titleMedium);
      expect(text.headlineMedium?.fontSize, 30);
      expect(text.headlineSmall?.fontSize, 26);
      expect(text.titleLarge?.fontSize, 22);
      expect(text.titleLarge?.fontWeight, FontWeight.w800);
      expect(text.titleLarge?.letterSpacing, lessThan(0));
      expect(text.titleMedium?.fontWeight, FontWeight.w700);
      // Control labels (titleSmall) keep Material's size: the theme sets
      // none, the platform's type geometry does (14).
      expect(text.titleSmall?.fontSize, isNull);
      expect(text.titleSmall?.fontWeight, FontWeight.w700);
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
      expect(resolve(light.searchBarTheme.shape), const StadiumBorder());
      expect(chips.backgroundColor, Colors.transparent);
      final side = chips.side! as WidgetStateBorderSide;
      expect(side.resolve({})?.color, colors.outline);
      expect(side.resolve({WidgetState.selected})?.color, colors.primary);
    });

    test('cards are flat, rounded hairline boxes', () {
      expect(light.cardTheme.elevation, 0);
      expect(light.cardTheme.color, white);
      expect(
        light.cardTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
          side: BorderSide(color: Color(0xFFEFF3F4)),
        ),
      );
    });

    test('the radius tokens grow from badges to sheets', () {
      expect(AppRadius.badge, lessThan(AppRadius.menu));
      expect(AppRadius.menu, lessThan(AppRadius.field));
      expect(AppRadius.field, lessThan(AppRadius.card));
      expect(AppRadius.card, lessThan(AppRadius.sheet));
      expect(AppRadius.field, inInclusiveRange(20, 28));
      expect(AppRadius.card, inInclusiveRange(20, 28));
      expect(AppRadius.sheet, inInclusiveRange(20, 28));
      expect(kCardRadius, AppRadius.card);
      expect(kSheetRadius, AppRadius.sheet);
      expect(kChipRadius, AppRadius.badge);
      expect(AppRadius.cardBorderRadius, BorderRadius.circular(AppRadius.card));
      expect(
        AppRadius.fieldBorderRadius,
        BorderRadius.circular(AppRadius.field),
      );
    });

    test('inputs are rounded outlines with a 2 px accent focus', () {
      final inputs = light.inputDecorationTheme;
      expect(inputs.filled, isFalse);
      final enabled = inputs.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderRadius, BorderRadius.circular(AppRadius.field));
      for (final border in [
        inputs.border,
        inputs.disabledBorder,
        inputs.focusedBorder,
        inputs.errorBorder,
        inputs.focusedErrorBorder,
      ]) {
        expect(
          (border! as OutlineInputBorder).borderRadius,
          AppRadius.fieldBorderRadius,
        );
      }
      expect(enabled.borderSide.color, const Color(0xFF7B8A97));
      expect(enabled.borderSide.color, colors.outline);
      final focused = inputs.focusedBorder! as OutlineInputBorder;
      expect(focused.borderSide.width, 2);
      expect(focused.borderSide.color, colors.primary);
      expect(
        (black.inputDecorationTheme.enabledBorder! as OutlineInputBorder)
            .borderSide
            .color,
        const Color(0xFF616C77),
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

    test('app bars: surface, big bold title, hairline, no tint', () {
      final bar = light.appBarTheme;
      expect(bar.backgroundColor, white);
      expect(bar.surfaceTintColor, Colors.transparent);
      expect(bar.titleTextStyle?.fontWeight, FontWeight.w800);
      expect(bar.titleTextStyle?.fontSize, AppTypeScale.headlineSmall);
      expect(bar.titleTextStyle?.color, colors.onSurface);
      expect(
        bar.shape,
        const Border(bottom: BorderSide(color: Color(0xFFEFF3F4))),
      );
    });

    test('navigation bar: labelled icons, no indicator', () {
      final nav = light.navigationBarTheme;
      expect(nav.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
      expect(nav.indicatorColor, Colors.transparent);
      expect(nav.height, kNavigationBarHeight);
      expect(kNavigationBarHeight, inInclusiveRange(64, 80));
      expect(
        nav.iconTheme!.resolve({WidgetState.selected})?.color,
        colors.onSurface,
      );
      expect(nav.iconTheme!.resolve({})?.color, const Color(0xFF536471));
      final selected = nav.labelTextStyle!.resolve({WidgetState.selected});
      final unselected = nav.labelTextStyle!.resolve({});
      expect(selected?.fontWeight, FontWeight.w800);
      expect(selected?.color, colors.onSurface);
      expect(unselected?.fontWeight, FontWeight.w500);
      expect(unselected?.color, const Color(0xFF536471));
      // One line: long labels end in an ellipsis.
      expect(selected?.overflow, TextOverflow.ellipsis);
      expect(unselected?.overflow, TextOverflow.ellipsis);
    });

    test('navigation rail: untinted with bold labels', () {
      final rail = light.navigationRailTheme;
      expect(rail.backgroundColor, white);
      expect(rail.indicatorColor, Colors.transparent);
      expect(rail.selectedLabelTextStyle?.fontWeight, FontWeight.w800);
      expect(rail.unselectedLabelTextStyle?.fontWeight, FontWeight.w400);
      // Labels, not headings: they keep Material's size.
      expect(rail.selectedLabelTextStyle?.fontSize, 16);
      expect(rail.unselectedLabelTextStyle?.fontSize, 16);
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
      expect(resolve(switches.trackOutlineWidth), 0);
      // Keyboard focus (the state is set only while focus is shown): a
      // 2 px accent ring around the track.
      const focused = {WidgetState.focused};
      expect(resolve(switches.trackOutlineColor, focused), colors.primary);
      expect(resolve(switches.trackOutlineWidth, focused), 2);
    });

    test('lists, sheets, dialogs, snack bars and progress', () {
      expect(light.listTileTheme.shape, const RoundedRectangleBorder());
      expect(light.listTileTheme.iconColor, const Color(0xFF536471));
      // Hairline edges: in Lights out a black sheet would otherwise melt
      // into the dimmed black page.
      expect(
        black.bottomSheetTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
          side: BorderSide(color: Color(0xFF2F3336)),
        ),
      );
      expect(light.bottomSheetTheme.backgroundColor, white);
      expect(light.dialogTheme.backgroundColor, white);
      expect(light.dialogTheme.titleTextStyle?.fontWeight, FontWeight.w800);
      expect(
        light.dialogTheme.titleTextStyle?.fontSize,
        AppTypeScale.titleLarge,
      );
      expect(
        light.dialogTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.sheet)),
          side: BorderSide(color: Color(0xFFEFF3F4)),
        ),
      );
      expect(
        light.popupMenuTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.menu)),
          side: BorderSide(color: Color(0xFFEFF3F4)),
        ),
      );
      final snack = light.snackBarTheme;
      expect(
        snack.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.menu)),
        ),
      );
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

    test('defaults to the X blue accent and Lights out', () {
      expect(const AppSettings().seedColor, 0xFF1D9BF0);
      final themes = AppThemes.fromSettings(
        const AppSettings(style: AppStyle.classic, dynamicColor: false),
      );
      expect(themes.light.brightness, Brightness.light);
      expect(themes.dark.brightness, Brightness.dark);
      expect(themes.dark.colorScheme.primary, blue);
      expect(themes.dark.colorScheme.surface, const Color(0xFF000000));
      expect(themes.light.colorScheme.surface, white);
    });

    test('uses the dynamic accent when enabled and available', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(style: AppStyle.classic),
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
        const AppSettings(
          style: AppStyle.classic,
          dynamicColor: false,
          seedColor: 0xFF00BA7C,
        ),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.primary, const Color(0xFF00BA7C));
    });

    test('Dim when pure black is off', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(style: AppStyle.classic, pureBlack: false),
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.surface, const Color(0xFF15202B));
      expect(
        themes.dark.extension<AppPalette>()?.hairline,
        const Color(0xFF38444D),
      );
      expect(themes.light.colorScheme.surface, white);
    });

    test('Lights out applies to the dark theme only', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(style: AppStyle.classic),
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

  group('contrast (WCAG)', () {
    // Every look, with every offered accent, a few awkward seeds and
    // Material You accents of both brightnesses.
    final seeds = [
      for (final option in AccentColorOption.options) Color(option.argb),
      const Color(0xFFFFD400),
      const Color(0xFFFFFFFF),
      const Color(0xFF000000),
      Colors.red,
      Colors.green,
    ];
    final dynamicSchemes = [
      for (final seed in [Colors.teal, Colors.pink, Colors.amber])
        for (final brightness in Brightness.values)
          ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    ];
    final schemes = <String, ColorScheme>{
      for (final seed in seeds) ...{
        'light ${seed.toARGB32().toRadixString(16)}': scheme(
          Brightness.light,
          seed: seed,
        ),
        'Dim ${seed.toARGB32().toRadixString(16)}': scheme(
          Brightness.dark,
          seed: seed,
        ),
        'Lights out ${seed.toARGB32().toRadixString(16)}': scheme(
          Brightness.dark,
          seed: seed,
          pureBlack: true,
        ),
      },
      for (final (i, dynamicScheme) in dynamicSchemes.indexed) ...{
        'dynamic $i': scheme(
          dynamicScheme.brightness,
          dynamicScheme: dynamicScheme,
        ),
        'dynamic $i Lights out': scheme(
          dynamicScheme.brightness,
          dynamicScheme: dynamicScheme,
          pureBlack: true,
        ),
      },
    };

    /// The surfaces controls and text sit on: the page, the composer's
    /// fill, raised panels and containers.
    List<Color> backgrounds(ColorScheme s) => [
      s.surface,
      s.surfaceContainerLow,
      s.surfaceContainer,
      s.surfaceContainerHigh,
    ];

    test('control outlines reach 3:1 on every surface', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        for (final background in backgrounds(s)) {
          expect(
            contrastRatio(s.outline, background),
            greaterThanOrEqualTo(kNonTextContrast),
            reason: '$name outline on ${background.toARGB32()}',
          );
        }
      }
    });

    test('hairlines stay for separators only', () {
      for (final tones in [AppTones.light, AppTones.dim, AppTones.lightsOut]) {
        expect(
          contrastRatio(tones.hairline, tones.surface),
          lessThan(kNonTextContrast),
        );
        expect(tones.controlOutline, isNot(tones.hairline));
      }
    });

    test('the control outline draws every interactive outline', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        final theme = buildAppTheme(s);
        final outline = s.outline;
        expect(
          theme.extension<AppPalette>()?.controlOutline,
          outline,
          reason: name,
        );
        final inputs = theme.inputDecorationTheme;
        expect(
          (inputs.enabledBorder! as OutlineInputBorder).borderSide.color,
          outline,
        );
        expect(
          (inputs.border! as OutlineInputBorder).borderSide.color,
          outline,
        );
        expect(
          (theme.chipTheme.side! as WidgetStateBorderSide).resolve({})?.color,
          outline,
        );
        expect(
          theme.outlinedButtonTheme.style!.side!.resolve({})?.color,
          outline,
        );
        expect(
          theme.segmentedButtonTheme.style!.side!.resolve({})?.color,
          outline,
        );
      }
    });

    test('secondary text reaches 4.5:1 on every surface', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        final secondary = appPalette(s).secondaryText;
        expect(s.onSurfaceVariant, secondary);
        for (final background in backgrounds(s)) {
          expect(
            contrastRatio(secondary, background),
            greaterThanOrEqualTo(kTextContrast),
            reason: '$name secondary text on ${background.toARGB32()}',
          );
        }
      }
    });

    test('the focus ring (the accent) reaches 3:1 on every surface', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        for (final background in backgrounds(s)) {
          expect(
            contrastRatio(s.primary, background),
            greaterThanOrEqualTo(kNonTextContrast),
            reason: '$name accent on ${background.toARGB32()}',
          );
        }
      }
    });

    test("a palette without the app's tones still outlines at 3:1", () {
      const palette = AppPalette(
        hairline: Color(0xFFEFF3F4),
        secondaryText: Color(0xFF536471),
        like: Color(0xFFF91880),
        success: Color(0xFF00BA7C),
        barBackground: Color(0xFFFFFFFF),
      );
      for (final tones in [AppTones.light, AppTones.dim, AppTones.lightsOut]) {
        expect(
          contrastRatio(palette.controlOutline, tones.surface),
          greaterThanOrEqualTo(kNonTextContrast),
        );
      }
      final material = ColorScheme.fromSeed(seedColor: blue);
      expect(AppPalette.fromScheme(material).controlOutline, material.outline);
    });
  });
}
