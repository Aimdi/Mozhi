import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/categories/appearance_settings.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockSettingsCubit settings;

  setUp(() => settings = createSettingsCubit());

  Future<void> pump(
    WidgetTester tester, {
    AppSettings state = const AppSettings(),
    ThemeData? theme,
    double textScale = 1,
  }) async {
    when(() => settings.state).thenReturn(state);
    tester.setScreenSize(Size(800, textScale > 1 ? 10000 : 4000));
    await tester.pumpView(
      const SettingsCategoryPage(category: SettingsCategory.appearance),
      settings: settings,
      theme: theme,
      textScale: textScale,
    );
    await tester.pumpAndSettle();
  }

  /// The swatches of the accent picker.
  final swatchFinder = find.descendant(
    of: find.byType(AccentColorPicker),
    matching: find.byType(AnimatedContainer),
  );

  RadioGroup<AppStyle> styleGroup(WidgetTester tester) =>
      tester.widget(find.byType(RadioGroup<AppStyle>));

  group('Style', () {
    testWidgets('comes first, Terminal selected by default', (tester) async {
      await pump(tester);
      expect(find.text('Style'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Classic'), findsOneWidget);
      expect(styleGroup(tester).groupValue, AppStyle.terminal);
      expect(
        tester.getTopLeft(find.text('Style')).dy,
        lessThan(tester.getTopLeft(find.text('Theme')).dy),
      );
      // A preview of each look, hidden from screen readers.
      expect(find.byType(StylePreview), findsNWidgets(2));
    });

    testWidgets('switches to Classic', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('settings_style_classic')));
      verify(() => settings.setStyle(AppStyle.classic)).called(1);
      // The current style again is a no-op.
      await tester.tap(find.byKey(const Key('settings_style_terminal')));
      verifyNever(() => settings.setStyle(AppStyle.terminal));
    });

    testWidgets('switches back to Terminal', (tester) async {
      await pump(tester, state: const AppSettings(style: AppStyle.classic));
      expect(styleGroup(tester).groupValue, AppStyle.classic);
      await tester.tap(find.text('Terminal'));
      verify(() => settings.setStyle(AppStyle.terminal)).called(1);
    });

    testWidgets('is one labelled group for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(find.bySemanticsLabel('Style'), findsOneWidget);
      // The previews add nothing to the radio buttons' names.
      expect(find.bySemanticsLabel('>_'), findsNothing);
      handle.dispose();
    });
  });

  group('Terminal style', () {
    testWidgets('offers the four terminal accents, amber selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(find.byKey(const Key('settings_terminal_accent')), findsOne);
      expect(find.text('Accent color'), findsOneWidget);
      for (final name in ['Amber', 'Green', 'Cyan', 'Pink']) {
        expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
      }
      expect(
        tester.getSemantics(find.bySemanticsLabel('Amber')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          isInMutuallyExclusiveGroup: true,
          hasSelectedState: true,
          isSelected: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Cyan')),
        isSemantics(isSelected: false),
      );
      // Not by colour alone: the selected swatch has a check mark.
      expect(find.byIcon(Icons.check), findsWidgets);
      // The classic accents are not offered.
      expect(find.bySemanticsLabel('Blue'), findsNothing);
      handle.dispose();
    });

    testWidgets('picks an accent', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Cyan'));
      verify(() => settings.setTerminalAccent(0xFF7DD3FC)).called(1);
      await tester.tap(find.bySemanticsLabel('Pink'));
      verify(() => settings.setTerminalAccent(0xFFFF6B9A)).called(1);
    });

    testWidgets('marks the chosen accent', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        state: AppSettings(terminalAccent: kTerminalAccents[1]),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Green')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Amber')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('hides the classic-only settings', (tester) async {
      await pump(tester);
      expect(find.text('Dynamic color'), findsNothing);
      expect(find.text('Dark theme'), findsNothing);
      expect(find.text('Lights out'), findsNothing);
      // The rest stays.
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Show romanization'), findsOneWidget);
    });

    testWidgets('explains the theme modes of the terminal style', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.text(
          'In the Terminal style, System means dark; Light gives the paper '
          'look',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Light'));
      verify(() => settings.setThemeMode(ThemeMode.light)).called(1);
    });

    testWidgets('explains the theme modes with large text too', (tester) async {
      await pump(tester, textScale: 2);
      expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
      expect(find.byKey(const Key('settings_theme_subtitle')), findsOneWidget);
    });

    testWidgets('renders in the terminal themes with square swatches', (
      tester,
    ) async {
      final themes = AppThemes.fromSettings(const AppSettings());
      for (final theme in [themes.dark, themes.light]) {
        await pump(tester, theme: theme);
        expect(tester.takeException(), isNull);
        final swatches = tester
            .widgetList<AnimatedContainer>(swatchFinder)
            .map((c) => c.decoration! as BoxDecoration);
        expect(swatches, hasLength(4));
        expect(swatches.map((d) => d.shape), everyElement(BoxShape.rectangle));
      }
    });
  });

  testWidgets('every settings page fits 320 dp with large text in the '
      'terminal theme', (tester) async {
    final themes = AppThemes.fromSettings(const AppSettings());
    when(() => settings.state).thenReturn(const AppSettings());
    for (final theme in [themes.dark, themes.light]) {
      for (final category in [null, ...SettingsCategory.values]) {
        tester.setScreenSize(const Size(320, 640));
        await tester.pumpView(
          category == null
              ? const SettingsPage()
              : SettingsCategoryPage(category: category),
          settings: settings,
          theme: theme,
          textScale: 2,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$category');
      }
    }
  });

  group('Classic style', () {
    const classic = AppSettings(style: AppStyle.classic, dynamicColor: false);

    testWidgets('keeps its settings and no terminal accents', (tester) async {
      await pump(tester, state: classic);
      expect(find.text('Dark theme'), findsOneWidget);
      expect(find.text('Dynamic color'), findsOneWidget);
      expect(find.byKey(const Key('settings_terminal_accent')), findsNothing);
      expect(find.bySemanticsLabel('Amber'), findsNothing);
      expect(find.bySemanticsLabel('Blue'), findsOneWidget);
      expect(find.byKey(const Key('settings_theme_subtitle')), findsNothing);
    });

    testWidgets('keeps round swatches in the classic theme', (tester) async {
      await pump(
        tester,
        state: classic,
        theme: AppThemes.fromSettings(classic).light,
      );
      final swatches = tester
          .widgetList<AnimatedContainer>(swatchFinder)
          .map((c) => c.decoration! as BoxDecoration);
      expect(swatches, isNotEmpty);
      expect(swatches.map((d) => d.shape), everyElement(BoxShape.circle));
    });
  });

  group('search', () {
    Future<List<SettingsSearchEntry>> index(
      WidgetTester tester,
      AppSettings state,
    ) async {
      late List<SettingsSearchEntry> entries;
      await tester.pumpView(
        Builder(
          builder: (context) {
            entries = settingsSearchIndex(context, state);
            return const SizedBox.shrink();
          },
        ),
        settings: settings,
      );
      return entries;
    }

    testWidgets('finds the style by its words', (tester) async {
      final entries = await index(tester, const AppSettings());
      for (final query in [
        'terminal',
        'style',
        'classic',
        'font',
        'monospace',
      ]) {
        expect(
          entries.where((e) => e.matches(query)).map((e) => e.anchor),
          contains(AppearanceAnchors.style),
          reason: query,
        );
      }
    });

    testWidgets('lists the rows of the current style', (tester) async {
      var anchors = {
        for (final e in await index(tester, const AppSettings())) e.anchor,
      };
      expect(anchors, contains(AppearanceAnchors.terminalAccent));
      expect(anchors, isNot(contains(AppearanceAnchors.darkLook)));
      expect(anchors, isNot(contains(AppearanceAnchors.accentColor)));
      expect(anchors, isNot(contains(AppearanceAnchors.dynamicColor)));

      anchors = {
        for (final e in await index(
          tester,
          const AppSettings(style: AppStyle.classic, dynamicColor: false),
        ))
          e.anchor,
      };
      expect(anchors, isNot(contains(AppearanceAnchors.terminalAccent)));
      expect(anchors, contains(AppearanceAnchors.darkLook));
      expect(anchors, contains(AppearanceAnchors.accentColor));
    });

    testWidgets('every appearance result names a row of the page', (
      tester,
    ) async {
      for (final state in [
        const AppSettings(),
        const AppSettings(style: AppStyle.classic, dynamicColor: false),
      ]) {
        final entries = (await index(
          tester,
          state,
        )).where((e) => e.category == SettingsCategory.appearance).toList();
        await pump(tester, state: state);
        for (final entry in entries) {
          expect(
            find.byKey(SettingsAnchor.highlightKey(entry.anchor)),
            findsOneWidget,
            reason: '${state.style.name}: ${entry.anchor}',
          );
          expect(
            find.text(entry.title),
            findsWidgets,
            reason: '${state.style.name}: ${entry.title}',
          );
        }
      }
    });

    testWidgets('finds the terminal accents by name', (tester) async {
      final entries = await index(tester, const AppSettings());
      expect(entries.where((e) => e.matches('cyan')).map((e) => e.anchor), [
        AppearanceAnchors.terminalAccent,
      ]);
    });
  });
}
