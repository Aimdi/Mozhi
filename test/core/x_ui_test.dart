import 'dart:ui' show ImageFilter;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

void main() {
  final lightScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1D9BF0));
  final darkScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1D9BF0),
    brightness: Brightness.dark,
  );

  const custom = AppPalette(
    hairline: Color(0xFF111111),
    secondaryText: Color(0xFF222222),
    like: Color(0xFF333333),
    success: Color(0xFF444444),
    barBackground: Color(0xFF555555),
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    ThemeData? theme,
    bool reduceMotion = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData(colorScheme: lightScheme),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  group('AppPalette', () {
    test('fromScheme derives light tones', () {
      final palette = AppPalette.fromScheme(lightScheme);
      expect(palette.hairline, const Color(0xFFEFF3F4));
      expect(palette.secondaryText, const Color(0xFF536471));
      expect(palette.like, const Color(0xFFF91880));
      expect(palette.success, const Color(0xFF00BA7C));
      expect(
        palette.barBackground,
        lightScheme.surface.withValues(alpha: 0.85),
      );
    });

    test('fromScheme derives dark tones', () {
      final palette = AppPalette.fromScheme(darkScheme);
      expect(palette.hairline, const Color(0xFF2F3336));
      expect(palette.secondaryText, const Color(0xFF8B98A5));
    });

    test('copyWith replaces only the given colours', () {
      expect(custom.copyWith().hairline, custom.hairline);
      expect(custom.copyWith().secondaryText, custom.secondaryText);
      expect(custom.copyWith().like, custom.like);
      expect(custom.copyWith().success, custom.success);
      expect(custom.copyWith().barBackground, custom.barBackground);
      const red = Color(0xFFFF0000);
      final copy = custom.copyWith(
        hairline: red,
        secondaryText: red,
        like: red,
        success: red,
        barBackground: red,
      );
      expect([
        copy.hairline,
        copy.secondaryText,
        copy.like,
        copy.success,
        copy.barBackground,
      ], everyElement(red));
    });

    test('lerp blends every colour and keeps itself without other', () {
      expect(custom.lerp(null, 0.5), same(custom));
      final other = custom.copyWith(
        hairline: const Color(0xFF333333),
        secondaryText: const Color(0xFF444444),
        like: const Color(0xFF555555),
        success: const Color(0xFF666666),
        barBackground: const Color(0xFF777777),
      );
      final mid = custom.lerp(other, 0.5);
      expect(mid.hairline, Color.lerp(custom.hairline, other.hairline, 0.5));
      expect(
        mid.secondaryText,
        Color.lerp(custom.secondaryText, other.secondaryText, 0.5),
      );
      expect(mid.like, Color.lerp(custom.like, other.like, 0.5));
      expect(mid.success, Color.lerp(custom.success, other.success, 0.5));
      expect(
        mid.barBackground,
        Color.lerp(custom.barBackground, other.barBackground, 0.5),
      );
      expect(custom.lerp(other, 1).hairline, other.hairline);
    });

    testWidgets('of reads the registered palette', (tester) async {
      late AppPalette palette;
      await pump(
        tester,
        Builder(
          builder: (context) {
            palette = AppPalette.of(context);
            return const SizedBox();
          },
        ),
        theme: ThemeData(colorScheme: lightScheme, extensions: const [custom]),
      );
      expect(palette, same(custom));
    });

    testWidgets('of falls back to the scheme', (tester) async {
      late AppPalette palette;
      await pump(
        tester,
        Builder(
          builder: (context) {
            palette = AppPalette.of(context);
            return const SizedBox();
          },
        ),
        theme: ThemeData(colorScheme: darkScheme),
      );
      expect(palette.hairline, const Color(0xFF2F3336));
    });
  });

  group('Hairline', () {
    testWidgets('is a 1 px horizontal divider in the hairline colour', (
      tester,
    ) async {
      await pump(
        tester,
        const SizedBox(width: 200, child: Hairline(indent: 16)),
        theme: ThemeData(extensions: const [custom]),
      );
      final divider = tester.widget<Divider>(find.byType(Divider));
      expect(divider.height, 1);
      expect(divider.thickness, 1);
      expect(divider.indent, 16);
      expect(divider.color, custom.hairline);
      expect(find.byType(VerticalDivider), findsNothing);
    });

    testWidgets('can be vertical', (tester) async {
      await pump(
        tester,
        const SizedBox(height: 100, child: Hairline(vertical: true)),
        theme: ThemeData(extensions: const [custom]),
      );
      final divider = tester.widget<VerticalDivider>(
        find.byType(VerticalDivider),
      );
      expect(divider.width, 1);
      expect(divider.thickness, 1);
      expect(divider.color, custom.hairline);
    });
  });

  group('BlurBar', () {
    BoxDecoration decoration(WidgetTester tester) =>
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(BlurBar),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;

    testWidgets('blurs what is underneath by default', (tester) async {
      await pump(
        tester,
        const BlurBar(child: Text('bar')),
        theme: ThemeData(extensions: const [custom]),
      );
      expect(find.text('bar'), findsOneWidget);
      expect(find.byType(ClipRect), findsWidgets);
      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(filter.filter, ImageFilter.blur(sigmaX: 16, sigmaY: 16));
      final box = decoration(tester);
      expect(box.color, custom.barBackground);
      final border = box.border! as Border;
      expect(border.top, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('skips the filter with sigma 0 and draws edges', (
      tester,
    ) async {
      await pump(
        tester,
        const BlurBar(top: true, bottom: true, sigma: 0, child: Text('bar')),
        theme: ThemeData(extensions: const [custom]),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      final border = decoration(tester).border! as Border;
      expect(border.top, BorderSide(color: custom.hairline));
      expect(border.bottom, BorderSide(color: custom.hairline));
    });

    testWidgets('a custom sigma', (tester) async {
      await pump(
        tester,
        const BlurBar(sigma: 4, bottom: true, child: Text('')),
      );
      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(filter.filter, ImageFilter.blur(sigmaX: 4, sigmaY: 4));
      final border = decoration(tester).border! as Border;
      expect(border.top, BorderSide.none);
      expect(border.bottom.style, BorderStyle.solid);
    });
  });

  group('LanguageAvatar', () {
    test('initials', () {
      expect(LanguageAvatar.initials(''), '?');
      expect(LanguageAvatar.initials('   '), '?');
      expect(LanguageAvatar.initials('auto'), '✦');
      expect(LanguageAvatar.initials(' auto '), '✦');
      expect(LanguageAvatar.initials('en'), 'EN');
      expect(LanguageAvatar.initials('pt-BR'), 'PT');
      expect(LanguageAvatar.initials('zh_Hant'), 'ZH');
      expect(LanguageAvatar.initials('pirate speak'), 'PI');
      expect(LanguageAvatar.initials('x'), 'X');
      expect(LanguageAvatar.initials('ελληνικά'), 'ΕΛ');
    });

    test('colours are stable per code and per brightness', () {
      for (final code in ['en', 'fr', 'pt-BR', 'auto', 'Pirate']) {
        final light = LanguageAvatar.colorFor(code, Brightness.light);
        expect(LanguageAvatar.colorFor(code, Brightness.light), light);
        // Case does not change the colour.
        expect(
          LanguageAvatar.colorFor(code.toUpperCase(), Brightness.light),
          light,
        );
        final dark = LanguageAvatar.colorFor(code, Brightness.dark);
        expect(dark, isNot(light));
        expect(
          HSLColor.fromColor(dark).lightness,
          lessThan(HSLColor.fromColor(light).lightness),
        );
        expect(light.a, 1);
      }
      expect(LanguageAvatar.colorFor('', Brightness.light).a, 1);
      final colours = {
        for (final code in ['en', 'fr', 'de', 'es', 'ja', 'ko', 'ru', 'ar'])
          LanguageAvatar.colorFor(code, Brightness.light),
      };
      expect(colours.length, greaterThan(1));
    });

    testWidgets('a round decorative avatar with initials', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const LanguageAvatar(code: 'de', size: 32));
      expect(tester.getSize(find.byType(LanguageAvatar)), const Size(32, 32));
      expect(find.text('DE'), findsOneWidget);
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(LanguageAvatar),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, LanguageAvatar.colorFor('de', Brightness.light));
      final text = tester.widget<Text>(find.text('DE'));
      expect(text.style?.fontSize, closeTo(32 * 0.36, 0.001));
      expect(text.style?.color, Colors.white);
      expect(find.bySemanticsLabel('DE'), findsNothing);
      handle.dispose();
    });

    testWidgets('defaults to 40 dp and uses the dark colour', (tester) async {
      await pump(
        tester,
        const LanguageAvatar(code: 'auto'),
        theme: ThemeData(colorScheme: darkScheme),
      );
      expect(tester.getSize(find.byType(LanguageAvatar)), const Size(40, 40));
      expect(find.text('✦'), findsOneWidget);
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(LanguageAvatar),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        (box.decoration as BoxDecoration).color,
        LanguageAvatar.colorFor('auto', Brightness.dark),
      );
    });
  });

  group('XActionButton', () {
    Icon icon(WidgetTester tester) => tester.widget<Icon>(
      find.descendant(
        of: find.byType(XActionButton),
        matching: find.byType(Icon),
      ),
    );

    double scale(WidgetTester tester) => tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(XActionButton),
            matching: find.byType(Transform),
          ),
        )
        .transform
        .storage[0];

    Widget button({
      bool active = false,
      VoidCallback? onPressed,
      IconData? activeIcon,
      Color? activeColor,
      String? label,
    }) => XActionButton(
      icon: Icons.favorite_border,
      activeIcon: activeIcon,
      tooltip: 'Like',
      onPressed: onPressed,
      active: active,
      activeColor: activeColor,
      label: label,
    );

    testWidgets('a quiet 48 dp target that reports taps', (tester) async {
      var taps = 0;
      await pump(
        tester,
        button(onPressed: () => taps++),
        theme: ThemeData(colorScheme: lightScheme, extensions: const [custom]),
      );
      expect(
        tester.getSize(find.byType(XActionButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byType(XActionButton)).width,
        greaterThanOrEqualTo(48),
      );
      expect(icon(tester).color, custom.secondaryText);
      expect(icon(tester).icon, Icons.favorite_border);
      expect(find.byTooltip('Like'), findsOneWidget);
      await tester.tap(find.byType(XActionButton));
      expect(taps, 1);
    });

    testWidgets('semantics: a named button, toggled only with an activeIcon', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, button(onPressed: () {}));
      expect(
        tester.getSemantics(find.byType(InkResponse)),
        isSemantics(
          label: 'Like',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: false,
        ),
      );
      await pump(
        tester,
        button(onPressed: () {}, activeIcon: Icons.favorite, active: true),
      );
      expect(
        tester.getSemantics(find.byType(InkResponse)),
        isSemantics(
          label: 'Like',
          isButton: true,
          hasToggledState: true,
          isToggled: true,
        ),
      );
      handle.dispose();
    });

    testWidgets(
      'keeps its tap action for screen readers',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, button(onPressed: () {}));
        expect(
          tester.getSemantics(find.byType(InkResponse)),
          isSemantics(label: 'Like', hasTapAction: true),
        );
        handle.dispose();
      },
      // Known issue: `excludeSemantics: true` drops the InkResponse's tap
      // action; XActionButton's Semantics needs `onTap: widget.onPressed`.
    );

    testWidgets('disabled: faded and not enabled', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        button(),
        theme: ThemeData(colorScheme: lightScheme, extensions: const [custom]),
      );
      expect(icon(tester).color, custom.secondaryText.withValues(alpha: 0.4));
      expect(
        tester.getSemantics(find.byType(InkResponse)),
        isSemantics(hasEnabledState: true, isEnabled: false),
      );
      handle.dispose();
    });

    testWidgets('active: active icon and colour, default primary', (
      tester,
    ) async {
      await pump(
        tester,
        button(onPressed: () {}, active: true, activeIcon: Icons.favorite),
      );
      expect(icon(tester).icon, Icons.favorite);
      expect(icon(tester).color, lightScheme.primary);

      await pump(
        tester,
        button(onPressed: () {}, active: true, activeColor: Colors.pink),
      );
      // Without an activeIcon the icon stays.
      expect(icon(tester).icon, Icons.favorite_border);
      expect(icon(tester).color, Colors.pink);
    });

    testWidgets('shows a label in the icon colour', (tester) async {
      await pump(
        tester,
        button(
          onPressed: () {},
          label: '12',
          active: true,
          activeColor: Colors.green,
        ),
      );
      expect(find.text('12'), findsOneWidget);
      expect(tester.widget<Text>(find.text('12')).style?.color, Colors.green);
    });

    testWidgets('pops when it becomes active', (tester) async {
      await pump(tester, button(onPressed: () {}));
      expect(scale(tester), 1);
      await pump(tester, button(onPressed: () {}, active: true));
      await tester.pump(const Duration(milliseconds: 180));
      expect(scale(tester), greaterThan(1.2));
      await tester.pumpAndSettle();
      expect(scale(tester), closeTo(1, 0.001));
      // Staying active, or turning inactive, does not pop again.
      await pump(tester, button(onPressed: () {}, active: true, label: 'x'));
      await tester.pump(const Duration(milliseconds: 180));
      expect(scale(tester), closeTo(1, 0.001));
      await pump(tester, button(onPressed: () {}));
      await tester.pump(const Duration(milliseconds: 180));
      expect(scale(tester), closeTo(1, 0.001));
    });

    testWidgets('does not pop with reduced motion', (tester) async {
      await pump(tester, button(onPressed: () {}), reduceMotion: true);
      await pump(
        tester,
        button(onPressed: () {}, active: true),
        reduceMotion: true,
      );
      await tester.pump(const Duration(milliseconds: 180));
      expect(scale(tester), 1);
    });

    testWidgets('disposes its animation', (tester) async {
      await pump(tester, button(onPressed: () {}));
      await pump(tester, button(onPressed: () {}, active: true));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });

  group('CountRing', () {
    CircularProgressIndicator ring(WidgetTester tester) =>
        tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        );

    testWidgets('a small accent ring without a number', (tester) async {
      await pump(
        tester,
        const CountRing(count: 50, limit: 100),
        theme: ThemeData(colorScheme: lightScheme, extensions: const [custom]),
      );
      await tester.pumpAndSettle();
      expect(ring(tester).value, 0.5);
      expect(ring(tester).color, lightScheme.primary);
      expect(ring(tester).backgroundColor, custom.hairline);
      expect(tester.getSize(find.byType(CountRing)), const Size(22, 22));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('amber and spelled out near the limit', (tester) async {
      await pump(
        tester,
        const CountRing(count: 95, limit: 100),
        theme: ThemeData(colorScheme: lightScheme, extensions: const [custom]),
      );
      await tester.pumpAndSettle();
      expect(ring(tester).color, const Color(0xFFFFD400));
      expect(find.text('5'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('5')).style?.color,
        custom.secondaryText,
      );
      expect(tester.getSize(find.byType(CountRing)), const Size(30, 30));
    });

    testWidgets('red past the limit, full ring', (tester) async {
      await pump(tester, const CountRing(count: 120, limit: 100));
      await tester.pumpAndSettle();
      expect(ring(tester).value, 1);
      expect(ring(tester).color, lightScheme.error);
      expect(find.text('-20'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('-20')).style?.color,
        lightScheme.error,
      );
    });

    testWidgets('an empty ring without a limit', (tester) async {
      await pump(tester, const CountRing(count: 3, limit: 0));
      await tester.pumpAndSettle();
      expect(ring(tester).value, 0);
    });
  });
}
