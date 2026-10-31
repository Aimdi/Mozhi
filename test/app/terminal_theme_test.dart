import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

void main() {
  const square = RoundedRectangleBorder();

  ThemeData terminal(Brightness brightness, [int accent = kTerminalAmber]) {
    final themes = AppThemes.fromSettings(AppSettings(terminalAccent: accent));
    return brightness == Brightness.dark ? themes.dark : themes.light;
  }

  T resolve<T>(WidgetStateProperty<T>? property, [Set<WidgetState>? s]) =>
      property!.resolve(s ?? {});

  group('AppTones (terminal)', () {
    test('picks the dark or the paper tones', () {
      expect(AppTones.terminal(Brightness.dark), AppTones.terminalDark);
      expect(AppTones.terminal(Brightness.light), AppTones.terminalPaper);
    });

    test("dark: the design's background, panel, text and border", () {
      const tones = AppTones.terminalDark;
      expect(tones.surface, const Color(0xFF0B0B0B));
      expect(tones.raised, const Color(0xFF141412));
      expect(tones.text, const Color(0xFFE8E2D0));
      expect(tones.secondaryText, const Color(0xFFA39A86));
      expect(tones.hairline, const Color(0xFF3A372F));
    });

    test('paper: the light variant', () {
      const tones = AppTones.terminalPaper;
      expect(tones.surface, const Color(0xFFF4F1E8));
      expect(tones.raised, const Color(0xFFECE8DC));
      expect(tones.text, const Color(0xFF1C1A16));
      expect(tones.secondaryText, const Color(0xFF5E574A));
      expect(tones.hairline, const Color(0xFFB9B2A2));
    });
  });

  group('terminalColorScheme', () {
    test('uses the accents as they are on the dark background', () {
      for (final accent in kTerminalAccents) {
        final scheme = terminalColorScheme(
          brightness: Brightness.dark,
          accent: Color(accent),
        );
        expect(scheme.primary, Color(accent));
        expect(scheme.onPrimary, kTerminalInk);
        expect(scheme.primaryContainer, scheme.primary);
        expect(scheme.onPrimaryContainer, scheme.onPrimary);
        expect(scheme.surface, AppTones.terminalDark.surface);
        expect(scheme.surfaceContainer, AppTones.terminalDark.raised);
        expect(scheme.onSurface, AppTones.terminalDark.text);
        expect(scheme.onSurfaceVariant, AppTones.terminalDark.secondaryText);
        expect(scheme.outline, AppTones.terminalDark.controlOutline);
        expect(scheme.outlineVariant, AppTones.terminalDark.hairline);
        expect(scheme.surfaceTint, Colors.transparent);
      }
    });

    test('darkens the accent on paper, keeping its hue', () {
      final scheme = terminalColorScheme(
        brightness: Brightness.light,
        accent: const Color(kTerminalAmber),
      );
      expect(scheme.brightness, Brightness.light);
      expect(scheme.surface, AppTones.terminalPaper.surface);
      expect(
        HSLColor.fromColor(scheme.primary).lightness,
        lessThan(HSLColor.fromColor(const Color(kTerminalAmber)).lightness),
      );
      expect(
        HSLColor.fromColor(scheme.primary).hue,
        closeTo(HSLColor.fromColor(const Color(kTerminalAmber)).hue, 1),
      );
      // The darkened amber is too dark for the dark ink: white text.
      expect(scheme.onPrimary, Colors.white);
    });

    test('picks a readable ink for any accent', () {
      final scheme = terminalColorScheme(
        brightness: Brightness.dark,
        accent: const Color(0xFF808080),
      );
      expect(
        contrastRatio(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(kTextContrast),
      );
    });
  });

  group('AppThemes.fromSettings (terminal)', () {
    test('is the default style', () {
      expect(const AppSettings().style, AppStyle.terminal);
      final themes = AppThemes.fromSettings(const AppSettings());
      expect(themes.dark.extension<AppLook>(), AppLook.terminal);
      expect(themes.light.extension<AppLook>(), AppLook.terminal);
      expect(themes.dark.colorScheme.primary, const Color(kTerminalAmber));
      expect(themes.dark.scaffoldBackgroundColor, const Color(0xFF0B0B0B));
      expect(themes.light.scaffoldBackgroundColor, const Color(0xFFF4F1E8));
    });

    test('ignores the classic colour settings', () {
      final lightDynamic = ColorScheme.fromSeed(seedColor: Colors.green);
      final darkDynamic = ColorScheme.fromSeed(
        seedColor: Colors.green,
        brightness: Brightness.dark,
      );
      final themes = AppThemes.fromSettings(
        const AppSettings(seedColor: 0xFF00BA7C, pureBlack: false),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.primary, const Color(kTerminalAmber));
      expect(themes.dark.colorScheme.surface, const Color(0xFF0B0B0B));
    });

    test('uses the chosen accent', () {
      final cyan = kTerminalAccents[2];
      final themes = AppThemes.fromSettings(AppSettings(terminalAccent: cyan));
      expect(themes.dark.colorScheme.primary, Color(cyan));
    });

    test('the classic style keeps the classic look', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(style: AppStyle.classic),
      );
      expect(themes.dark.extension<AppLook>(), AppLook.classic);
      expect(
        themes.dark.textTheme.bodyMedium?.fontFamily,
        isNot(kTerminalFontFamily),
      );
    });

    test('registers the terminal palette', () {
      final dark = terminal(Brightness.dark).extension<AppPalette>()!;
      expect(dark.hairline, AppTones.terminalDark.hairline);
      expect(dark.secondaryText, AppTones.terminalDark.secondaryText);
      expect(dark.controlOutline, AppTones.terminalDark.controlOutline);
      // Found from the scheme too (no explicit palette).
      final scheme = terminalColorScheme(
        brightness: Brightness.light,
        accent: const Color(kTerminalAmber),
      );
      const paper = AppTones.terminalPaper;
      for (final palette in [
        appPalette(scheme),
        buildAppTheme(scheme, look: AppLook.terminal).extension<AppPalette>()!,
      ]) {
        expect(palette.hairline, paper.hairline);
        expect(palette.secondaryText, paper.secondaryText);
        expect(palette.controlOutline, paper.controlOutline);
      }
    });
  });

  group('buildAppTheme (terminal)', () {
    final dark = terminal(Brightness.dark);
    final paper = terminal(Brightness.light);
    final colors = dark.colorScheme;

    test('JetBrains Mono everywhere, bold headings, no letter spacing', () {
      final text = dark.textTheme;
      final styles = [
        text.displayLarge,
        text.displayMedium,
        text.displaySmall,
        text.headlineLarge,
        text.headlineMedium,
        text.headlineSmall,
        text.titleLarge,
        text.titleMedium,
        text.titleSmall,
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
        text.labelLarge,
        text.labelMedium,
        text.labelSmall,
      ];
      for (final style in styles) {
        expect(style?.fontFamily, kTerminalFontFamily);
        expect(style?.letterSpacing, 0);
      }
      for (final style in styles.take(7)) {
        expect(style?.fontWeight, FontWeight.w800);
      }
      expect(text.headlineSmall?.fontSize, TerminalTypeScale.headlineSmall);
      expect(text.headlineSmall?.fontSize, 22);
      expect(text.bodyMedium?.fontSize, 14);
      expect(text.labelMedium?.fontSize, 12);
      expect(dark.primaryTextTheme.bodyMedium?.fontFamily, kTerminalFontFamily);
      expect(paper.textTheme.bodyMedium?.fontFamily, kTerminalFontFamily);
    });

    test('filled and elevated buttons are square accent blocks', () {
      for (final style in [
        dark.filledButtonTheme.style!,
        dark.elevatedButtonTheme.style!,
      ]) {
        expect(resolve(style.shape), square);
        expect(resolve(style.elevation), 0);
        expect(resolve(style.backgroundColor), colors.primary);
        expect(resolve(style.foregroundColor), kTerminalInk);
        expect(resolve(style.iconColor), kTerminalInk);
        expect(resolve(style.textStyle)?.fontWeight, FontWeight.w800);
        expect(resolve(style.minimumSize)!.height, greaterThanOrEqualTo(44));
        const disabled = {WidgetState.disabled};
        expect(
          resolve(style.backgroundColor, disabled)?.a,
          closeTo(0.12, 0.01),
        );
        expect(
          resolve(style.foregroundColor, disabled)?.a,
          closeTo(0.38, 0.01),
        );
        expect(resolve(style.iconColor, disabled)?.a, closeTo(0.38, 0.01));
        expect(resolve(style.overlayColor), isNull);
        expect(resolve(style.overlayColor, {WidgetState.pressed}), isNotNull);
      }
      expect(
        resolve(paper.filledButtonTheme.style!.foregroundColor),
        paper.colorScheme.onPrimary,
      );
    });

    test('outlined, text and icon buttons are square', () {
      final outlined = dark.outlinedButtonTheme.style!;
      expect(resolve(outlined.shape), square);
      expect(resolve(outlined.side)?.color, colors.outline);
      expect(resolve(outlined.side)?.width, 1);
      expect(resolve(dark.textButtonTheme.style!.shape), square);
      expect(resolve(dark.iconButtonTheme.style!.shape), square);
      expect(resolve(dark.menuButtonTheme.style!.shape), square);
    });

    test('segmented buttons: square, the selection an accent block', () {
      final style = dark.segmentedButtonTheme.style!;
      expect(resolve(style.shape), square);
      expect(resolve(style.side)?.color, colors.outline);
      const selected = {WidgetState.selected};
      expect(resolve(style.backgroundColor, selected), colors.primary);
      expect(resolve(style.foregroundColor, selected), colors.onPrimary);
      expect(resolve(style.foregroundColor), colors.onSurface);
    });

    test('chips, cards, menus, dialogs and sheets are square boxes', () {
      expect(dark.chipTheme.shape, square);
      expect(dark.chipTheme.showCheckmark, isTrue);
      expect(
        (dark.chipTheme.side! as WidgetStateBorderSide).resolve({
          WidgetState.selected,
        })?.color,
        colors.primary,
      );
      final hairline = AppTones.terminalDark.hairline;
      for (final shape in [
        dark.cardTheme.shape,
        dark.popupMenuTheme.shape,
        dark.dialogTheme.shape,
        dark.bottomSheetTheme.shape,
        resolve(dark.menuTheme.style!.shape),
        resolve(dark.dropdownMenuTheme.menuStyle!.shape),
      ]) {
        final box = shape! as RoundedRectangleBorder;
        expect(box.borderRadius, BorderRadius.zero);
        expect(box.side.color, hairline);
      }
      expect(dark.cardTheme.elevation, 0);
      expect(dark.dialogTheme.elevation, 0);
      expect(dark.dialogTheme.backgroundColor, colors.surfaceContainer);
      expect(dark.bottomSheetTheme.elevation, 0);
      expect(dark.bottomSheetTheme.modalElevation, 0);
      expect(dark.popupMenuTheme.elevation, 0);
      expect(dark.expansionTileTheme.shape, square);
      expect(dark.listTileTheme.shape, square);
      expect(dark.drawerTheme.shape, square);
      expect(dark.checkboxTheme.shape, square);
      expect(dark.toggleButtonsTheme.borderRadius, BorderRadius.zero);
    });

    test('FAB, snack bars, tooltips and the search bar are square', () {
      final fab = dark.floatingActionButtonTheme;
      expect(fab.shape, square);
      expect(fab.backgroundColor, colors.primary);
      expect(fab.foregroundColor, colors.onPrimary);
      expect(fab.elevation, 0);
      expect(fab.highlightElevation, 0);
      expect(dark.snackBarTheme.shape, square);
      expect(dark.snackBarTheme.elevation, 0);
      expect(dark.snackBarTheme.backgroundColor, colors.inverseSurface);
      final tooltip = dark.tooltipTheme.decoration! as BoxDecoration;
      expect(tooltip.borderRadius, isNull);
      expect(tooltip.color, colors.inverseSurface);
      final search = dark.searchBarTheme;
      expect(resolve(search.shape), square);
      expect(resolve(search.side)?.color, colors.outline);
      expect(resolve(search.elevation), 0);
    });

    test('inputs are square outlines with a 2 px accent focus', () {
      final inputs = dark.inputDecorationTheme;
      final enabled = inputs.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderRadius, BorderRadius.zero);
      expect(enabled.borderSide.color, colors.outline);
      expect(
        (inputs.border! as OutlineInputBorder).borderRadius,
        BorderRadius.zero,
      );
      final focused = inputs.focusedBorder! as OutlineInputBorder;
      expect(focused.borderSide.color, colors.primary);
      expect(focused.borderSide.width, 2);
      expect(
        (inputs.disabledBorder! as OutlineInputBorder).borderSide.color,
        AppTones.terminalDark.hairline,
      );
      expect(
        (inputs.errorBorder! as OutlineInputBorder).borderSide.color,
        colors.error,
      );
      expect(
        (inputs.focusedErrorBorder! as OutlineInputBorder).borderSide.width,
        2,
      );
      expect(inputs.hintStyle?.color, AppTones.terminalDark.secondaryText);
      expect(dark.textSelectionTheme.cursorColor, colors.primary);
    });

    test('tabs: a square accent underline', () {
      final indicator = dark.tabBarTheme.indicator! as UnderlineTabIndicator;
      expect(indicator.borderRadius, BorderRadius.zero);
      expect(indicator.borderSide.color, colors.primary);
    });

    test('app bars: the background, a bottom border, no elevation', () {
      final bar = dark.appBarTheme;
      expect(bar.backgroundColor, colors.surface);
      expect(bar.elevation, 0);
      expect(bar.scrolledUnderElevation, 0);
      expect(bar.toolbarHeight, 60);
      expect(
        bar.shape,
        Border(bottom: BorderSide(color: AppTones.terminalDark.hairline)),
      );
      expect(bar.titleTextStyle?.fontFamily, kTerminalFontFamily);
      expect(bar.titleTextStyle?.color, colors.onSurface);
    });

    test('navigation: square accent indicator, quiet unselected tabs', () {
      final bar = dark.navigationBarTheme;
      expect(bar.backgroundColor, colors.surface);
      expect(bar.indicatorColor, colors.primary);
      expect(bar.indicatorShape, square);
      expect(bar.elevation, 0);
      const selected = {WidgetState.selected};
      expect(resolve(bar.iconTheme, selected)?.color, colors.onPrimary);
      expect(
        resolve(bar.iconTheme)?.color,
        AppTones.terminalDark.secondaryText,
      );
      expect(
        resolve(bar.labelTextStyle, selected)?.fontWeight,
        FontWeight.w700,
      );
      expect(resolve(bar.labelTextStyle)?.fontWeight, FontWeight.w500);
      expect(
        resolve(bar.labelTextStyle)?.color,
        AppTones.terminalDark.secondaryText,
      );
      expect(resolve(bar.labelTextStyle)?.fontSize, 12);

      final rail = dark.navigationRailTheme;
      expect(rail.backgroundColor, colors.surface);
      expect(rail.useIndicator, isTrue);
      expect(rail.indicatorColor, colors.primary);
      expect(rail.indicatorShape, square);
      expect(rail.selectedIconTheme?.color, colors.onPrimary);
      expect(
        rail.unselectedLabelTextStyle?.color,
        AppTones.terminalDark.secondaryText,
      );
      expect(dark.navigationDrawerTheme.indicatorShape, square);
    });

    test('switches: accent track and dark thumb when on, outlined off', () {
      final s = dark.switchTheme;
      const on = {WidgetState.selected};
      expect(resolve(s.trackColor, on), colors.primary);
      expect(resolve(s.thumbColor, on), colors.onPrimary);
      expect(resolve(s.trackColor), colors.surface);
      expect(resolve(s.thumbColor), colors.outline);
      expect(resolve(s.trackOutlineColor), colors.outline);
      expect(resolve(s.trackOutlineColor, on), colors.primary);
      expect(resolve(s.trackOutlineWidth), 1);
      expect(
        resolve(s.trackOutlineColor, {WidgetState.focused}),
        colors.onSurface,
      );
      expect(resolve(s.trackOutlineWidth, {WidgetState.focused}), 2);
      const disabled = {WidgetState.disabled};
      expect(resolve(s.trackColor, disabled)?.a, closeTo(0.12, 0.01));
      expect(resolve(s.thumbColor, disabled)?.a, closeTo(0.38, 0.01));
      expect(
        resolve(s.trackOutlineColor, disabled),
        AppTones.terminalDark.hairline,
      );
      expect(resolve(s.thumbIcon), isNull);
    });

    test('dividers and progress use the borders and the accent', () {
      expect(dark.dividerTheme.color, AppTones.terminalDark.hairline);
      expect(dark.progressIndicatorTheme.color, colors.primary);
      expect(
        dark.progressIndicatorTheme.linearTrackColor,
        AppTones.terminalDark.hairline,
      );
    });

    testWidgets('AppLook.of reads the terminal look', (tester) async {
      late AppLook look;
      await tester.pumpWidget(
        MaterialApp(
          theme: dark,
          home: Builder(
            builder: (context) {
              look = AppLook.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(look.isTerminal, isTrue);
      expect(look.cardRadius, BorderRadius.zero);
      expect(look.control, square);
    });
  });

  group('contrast (WCAG, terminal)', () {
    final schemes = <String, ColorScheme>{
      for (final accent in kTerminalAccents)
        for (final brightness in Brightness.values)
          '${brightness == Brightness.dark ? 'dark' : 'paper'} '
              '${accent.toRadixString(16)}': terminalColorScheme(
            brightness: brightness,
            accent: Color(accent),
          ),
    };

    /// The surfaces text and controls sit on: the page and the panels.
    List<Color> backgrounds(ColorScheme s) => [
      s.surface,
      s.surfaceContainerLow,
      s.surfaceContainer,
      s.surfaceContainerHigh,
    ];

    void expectAll(
      String what,
      Color Function(ColorScheme s) foreground,
      double minimum,
    ) {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        for (final background in backgrounds(s)) {
          expect(
            contrastRatio(foreground(s), background),
            greaterThanOrEqualTo(minimum),
            reason: '$name: $what on ${background.toARGB32()}',
          );
        }
      }
    }

    test('text and secondary text reach 4.6:1 on every panel', () {
      expectAll('text', (s) => s.onSurface, kTextContrast);
      expectAll('secondary text', (s) => s.onSurfaceVariant, kTextContrast);
      expectAll(
        'palette secondary text',
        (s) => appPalette(s).secondaryText,
        kTextContrast,
      );
    });

    test('the accent reads as text on every panel', () {
      expectAll('accent', (s) => s.primary, kTextContrast);
    });

    test('control outlines reach 3:1 on every panel', () {
      expectAll('outline', (s) => s.outline, kNonTextContrast);
    });

    test('the text on the accent reaches 4.6:1', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        expect(
          contrastRatio(s.onPrimary, s.primary),
          greaterThanOrEqualTo(kTextContrast),
          reason: name,
        );
        // The filled buttons keep the dark ink wherever it reads.
        if (contrastRatio(kTerminalInk, s.primary) >= kTextContrast) {
          expect(s.onPrimary, kTerminalInk, reason: name);
        }
      }
    });

    test('snack bars: text and action read on the inverse surface', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        expect(
          contrastRatio(s.onInverseSurface, s.inverseSurface),
          greaterThanOrEqualTo(kTextContrast),
          reason: name,
        );
        expect(
          contrastRatio(s.inversePrimary, s.inverseSurface),
          greaterThanOrEqualTo(kTextContrast),
          reason: name,
        );
      }
    });

    test('the switch thumb stands out from its track', () {
      for (final MapEntry(key: name, value: s) in schemes.entries) {
        expect(
          contrastRatio(s.onPrimary, s.primary),
          greaterThanOrEqualTo(kNonTextContrast),
          reason: name,
        );
        expect(
          contrastRatio(s.outline, s.surface),
          greaterThanOrEqualTo(kNonTextContrast),
          reason: name,
        );
      }
    });

    test('the borders are decorative (hairlines)', () {
      for (final tones in [AppTones.terminalDark, AppTones.terminalPaper]) {
        expect(
          contrastRatio(tones.hairline, tones.surface),
          lessThan(kNonTextContrast),
        );
        expect(tones.controlOutline, isNot(tones.hairline));
      }
    });
  });
}
