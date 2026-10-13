import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/settings/models/app_settings.dart';

void main() {
  const seed = Color(0xFF3F51B5);

  group('appColorScheme', () {
    test('is generated from the seed without a dynamic scheme', () {
      final scheme = appColorScheme(
        brightness: Brightness.light,
        seedColor: seed,
      );
      expect(scheme, ColorScheme.fromSeed(seedColor: seed));
    });

    test('uses the dynamic scheme of the same brightness', () {
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: Brightness.dark,
      );
      expect(
        appColorScheme(
          brightness: Brightness.dark,
          seedColor: seed,
          dynamicScheme: dynamicScheme,
        ),
        dynamicScheme,
      );
    });

    test('ignores a dynamic scheme of the other brightness', () {
      final dynamicScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final scheme = appColorScheme(
        brightness: Brightness.dark,
        seedColor: seed,
        dynamicScheme: dynamicScheme,
      );
      expect(scheme.brightness, Brightness.dark);
      expect(scheme, isNot(dynamicScheme));
    });

    test('pure black turns dark surfaces black', () {
      final scheme = appColorScheme(
        brightness: Brightness.dark,
        seedColor: seed,
        pureBlack: true,
      );
      expect(scheme.surface, Colors.black);
      expect(scheme.surfaceContainerLowest, Colors.black);
      expect(scheme.surfaceDim, Colors.black);
    });

    test('pure black does not affect light schemes', () {
      final scheme = appColorScheme(
        brightness: Brightness.light,
        seedColor: seed,
        pureBlack: true,
      );
      expect(scheme.surface, isNot(Colors.black));
    });
  });

  group('buildAppTheme', () {
    final theme = buildAppTheme(ColorScheme.fromSeed(seedColor: seed));

    test('is Material 3 with the given scheme', () {
      expect(theme.useMaterial3, isTrue);
      expect(
        theme.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: seed).primary,
      );
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
    });

    test('has rounded cards, filled inputs and compact chips', () {
      expect(
        theme.cardTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
        ),
      );
      expect(theme.cardTheme.elevation, 0);
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(
        theme.inputDecorationTheme.border,
        isA<OutlineInputBorder>().having(
          (b) => b.borderRadius,
          'borderRadius',
          BorderRadius.circular(kCardRadius),
        ),
      );
      expect(theme.chipTheme.showCheckmark, isTrue);
      expect(
        theme.chipTheme.padding,
        const EdgeInsets.symmetric(horizontal: 4),
      );
      expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
    });

    test('bolds titles', () {
      expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w600);
    });

    test('resolves bold labels for the selected navigation item', () {
      final style = theme.navigationBarTheme.labelTextStyle!;
      expect(
        style.resolve({WidgetState.selected})?.fontWeight,
        FontWeight.w700,
      );
      expect(style.resolve({})?.fontWeight, FontWeight.w500);
    });
  });

  group('AppThemes.fromSettings', () {
    final lightDynamic = ColorScheme.fromSeed(seedColor: Colors.green);
    final darkDynamic = ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.dark,
    );

    test('builds light and dark themes from the seed', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(dynamicColor: false),
      );
      expect(themes.light.brightness, Brightness.light);
      expect(themes.dark.brightness, Brightness.dark);
      expect(
        themes.light.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: seed).primary,
      );
    });

    test('uses dynamic colors when enabled and available', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(themes.light.colorScheme.primary, lightDynamic.primary);
      expect(themes.dark.colorScheme.primary, darkDynamic.primary);
    });

    test('ignores dynamic colors when disabled', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(dynamicColor: false, seedColor: 0xFFB00020),
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );
      expect(
        themes.light.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: const Color(0xFFB00020)).primary,
      );
    });

    test('applies pure black to the dark theme only', () {
      final themes = AppThemes.fromSettings(
        const AppSettings(pureBlack: true),
        darkDynamic: darkDynamic,
      );
      expect(themes.dark.colorScheme.surface, Colors.black);
      expect(themes.dark.scaffoldBackgroundColor, Colors.black);
      expect(themes.light.colorScheme.surface, isNot(Colors.black));
    });
  });
}
