import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../helpers/helpers.dart';

/// Google as Fast, Claude as Best.
TranslateState _state({
  QualityMode mode = QualityMode.off,
  bool fast = true,
  bool best = true,
}) =>
    translatedState(
      engine: switch (mode) {
        QualityMode.fast => google,
        QualityMode.best => claude,
        QualityMode.off => deepl,
      },
    ).copyWith(
      qualityMode: mode,
      fastEngine: () => fast ? google : null,
      bestEngine: () => best ? claude : null,
    );

TranslateHarness _harness(TranslateState state) {
  final harness = TranslateHarness(state: state);
  when(() => harness.translate.setQualityMode(any())).thenAnswer((_) async {});
  return harness;
}

Finder get _toggle => find.byKey(const Key('translate_quality_toggle'));

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbackValue(QualityMode.off);
  });

  group('QualityToggle', () {
    testWidgets('shows nothing without quality engines', (tester) async {
      final harness = _harness(_state(fast: false, best: false));
      await harness.pump(tester, child: const QualityToggle());
      expect(_toggle, findsNothing);
    });

    testWidgets('offers Fast and Best with their engines', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, child: const QualityToggle());
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Best'), findsOneWidget);
      expect(find.byTooltip('Fast: translate with Google'), findsOneWidget);
      expect(find.byTooltip('Best: translate with Claude'), findsOneWidget);
      final toggle = tester.widget<SegmentedButton<QualityMode>>(_toggle);
      expect(toggle.selected, isEmpty);
      expect(find.bySemanticsLabel('Quality mode'), findsOneWidget);
    });

    testWidgets('offers only the configured mode', (tester) async {
      final harness = _harness(_state(fast: false));
      await harness.pump(tester, child: const QualityToggle());
      expect(find.text('Fast'), findsNothing);
      expect(find.text('Best'), findsOneWidget);
    });

    testWidgets('selecting a mode calls setQualityMode', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, child: const QualityToggle());
      await tester.tap(find.text('Best'));
      verify(() => harness.translate.setQualityMode(QualityMode.best))
          .called(1);
      await tester.tap(find.text('Fast'));
      verify(() => harness.translate.setQualityMode(QualityMode.fast))
          .called(1);
    });

    testWidgets('tapping the selected mode turns it off', (tester) async {
      final harness = _harness(_state(mode: QualityMode.fast));
      await harness.pump(tester, child: const QualityToggle());
      final toggle = tester.widget<SegmentedButton<QualityMode>>(_toggle);
      expect(toggle.selected, {QualityMode.fast});
      // The check mark shows the selection without relying on colour.
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('Fast'));
      verify(() => harness.translate.setQualityMode(QualityMode.off)).called(1);
    });

    testWidgets('compact shows icons with spoken names', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = _harness(_state(mode: QualityMode.best));
      await harness.pump(
        tester,
        child: const QualityToggle(layout: QualityToggleLayout.icons),
      );
      expect(find.text('Fast'), findsNothing);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.byIcon(Icons.workspace_premium_outlined), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Fast')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Best')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.bolt));
      verify(() => harness.translate.setQualityMode(QualityMode.fast))
          .called(1);
      handle.dispose();
    });

    testWidgets('segments are at least 48 dp tall', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, child: const QualityToggle());
      expect(tester.getSize(_toggle).height, greaterThanOrEqualTo(48));
    });

    test('translateQualityIcon', () {
      expect(translateQualityIcon(QualityMode.off), Icons.speed);
      expect(translateQualityIcon(QualityMode.fast), Icons.bolt);
      expect(
        translateQualityIcon(QualityMode.best),
        Icons.workspace_premium_outlined,
      );
    });
  });

  group('menu layout', () {
    Future<TranslateHarness> open(
      WidgetTester tester,
      TranslateState state,
    ) async {
      final harness = _harness(state);
      await harness.pump(
        tester,
        child: const QualityToggle(layout: QualityToggleLayout.menu),
      );
      await tester.tap(find.byKey(const Key('translate_quality_menu')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('lists the modes with their engines', (tester) async {
      await open(tester, _state(mode: QualityMode.best));
      expect(find.text('Usual engine'), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      final best = tester.widget<CheckedPopupMenuItem<QualityMode>>(
        find.byKey(const ValueKey('translate_quality_best')),
      );
      expect(best.checked, isTrue);
      final off = tester.widget<CheckedPopupMenuItem<QualityMode>>(
        find.byKey(const ValueKey('translate_quality_off')),
      );
      expect(off.checked, isFalse);
    });

    testWidgets('choosing a mode calls setQualityMode', (tester) async {
      final harness = await open(tester, _state(mode: QualityMode.best));
      await tester.tap(find.byKey(const ValueKey('translate_quality_off')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setQualityMode(QualityMode.off)).called(1);
    });

    testWidgets('choosing the current mode does nothing', (tester) async {
      final harness = await open(tester, _state());
      await tester.tap(find.byKey(const ValueKey('translate_quality_off')));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.setQualityMode(any()));
    });

    testWidgets('the button shows the mode', (tester) async {
      final harness = _harness(_state(mode: QualityMode.fast));
      await harness.pump(
        tester,
        child: const QualityToggle(layout: QualityToggleLayout.menu),
      );
      expect(find.byTooltip('Quality mode: Fast'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);

      harness.setState(_state());
      await harness.pump(
        tester,
        child: const QualityToggle(
          key: Key('other'),
          layout: QualityToggleLayout.menu,
        ),
      );
      expect(find.byTooltip('Quality mode: Usual engine'), findsOneWidget);
      expect(find.byIcon(Icons.speed), findsOneWidget);
    });

    test('translateQualityLabel', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(translateQualityLabel(l10n, QualityMode.off), 'Usual engine');
      expect(translateQualityLabel(l10n, QualityMode.fast), 'Fast');
      expect(translateQualityLabel(l10n, QualityMode.best), 'Best');
    });
  });

  group('app bar', () {
    testWidgets('uses icon segments on wider phones', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, size: const Size(540, 900));
      expect(_toggle, findsOneWidget);
      expect(find.text('Fast'), findsNothing);
      final selector = tester.getRect(
        find.byKey(const Key('translate_engine_selector')),
      );
      final toggle = tester.getRect(_toggle);
      expect(toggle.left, greaterThanOrEqualTo(selector.right));
    });

    testWidgets('uses the menu on narrow phones', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, size: const Size(360, 800));
      expect(_toggle, findsNothing);
      expect(find.byKey(const Key('translate_quality_menu')), findsOneWidget);
      expect(find.text('DeepL'), findsOneWidget);
    });

    testWidgets('shows labels on larger screens', (tester) async {
      final harness = _harness(_state());
      await harness.pump(tester, size: const Size(1200, 800));
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Best'), findsOneWidget);
    });

    testWidgets('fits a 320 dp app bar at 200 % text', (tester) async {
      final harness = _harness(_state(mode: QualityMode.best));
      await harness.pump(tester, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('translate_quality_menu')), findsOneWidget);
      expect(find.byTooltip('More tools'), findsOneWidget);
    });

    Finder appBarTitle() => find.descendant(
      of: find.byType(AppBar),
      matching: find.text('Translate'),
    );

    testWidgets('keeps the screen title next to labels when there is room', (
      tester,
    ) async {
      final harness = _harness(_state());
      await harness.pump(tester, size: const Size(1200, 800));
      expect(appBarTitle(), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
    });

    testWidgets('makes room on 600-840 dp screens instead of overflowing', (
      tester,
    ) async {
      final harness = _harness(_state(mode: QualityMode.best));
      await harness.pump(tester, size: const Size(620, 900));
      expect(tester.takeException(), isNull);
      expect(_toggle, findsOneWidget);
      expect(find.text('Best'), findsNothing);
      expect(appBarTitle(), findsNothing);
      // Without a toggle the title still shows.
      final plain = _harness(_state(fast: false, best: false));
      await plain.pump(tester, size: const Size(620, 900));
      expect(appBarTitle(), findsOneWidget);
    });

    testWidgets('fits a 600-840 dp app bar at 200 % text', (tester) async {
      final harness = _harness(_state(mode: QualityMode.best));
      await harness.pump(tester, size: const Size(620, 900), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.text('Best'), findsNothing);
      // Everything stays reachable.
      expect(
        find.byKey(const Key('translate_engine_selector')),
        findsOneWidget,
      );
      expect(find.byTooltip('More tools'), findsOneWidget);
      for (final finder in [
        find.byKey(const Key('translate_engine_selector')),
        _toggle,
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.right, lessThanOrEqualTo(620));
        expect(rect.left, greaterThanOrEqualTo(0));
      }
    });

    testWidgets('the screen title gives way at 300 % text', (tester) async {
      final harness = _harness(_state(fast: false, best: false));
      await harness.pump(tester, size: const Size(620, 900), textScale: 3);
      expect(tester.takeException(), isNull);
    });

    test('layoutFor follows the width and the text size', () {
      expect(QualityToggle.layoutFor(600), QualityToggleLayout.labels);
      expect(QualityToggle.layoutFor(440), QualityToggleLayout.icons);
      expect(QualityToggle.layoutFor(280), QualityToggleLayout.menu);
      expect(
        QualityToggle.layoutFor(600, textScaler: const TextScaler.linear(2)),
        QualityToggleLayout.icons,
      );
      // Phones (no screen title) never get labels.
      expect(
        QualityToggle.layoutFor(600, withTitle: false),
        QualityToggleLayout.icons,
      );
    });

    testWidgets('is absent without quality engines', (tester) async {
      final harness = _harness(_state(fast: false, best: false));
      await harness.pump(tester);
      expect(_toggle, findsNothing);
      expect(find.byKey(const Key('translate_quality_menu')), findsNothing);
    });
  });

  group('EngineSheet quality modes entry', () {
    Future<TranslateHarness> open(
      WidgetTester tester,
      TranslateState state,
    ) async {
      final harness = _harness(state);
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1400),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('explains how to set up quality modes', (tester) async {
      final harness = await open(tester, _state(fast: false, best: false));
      expect(find.text('Quality modes'), findsOneWidget);
      expect(
        find.text(
          'Choose a Fast and a Best engine to switch between them next to '
          'the engine name',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('translate_quality_settings')));
      await tester.pumpAndSettle();
      verify(() => harness.router.go(translateQualityLocation)).called(1);
      expect(translateQualityLocation, '/settings/quality');
    });

    testWidgets('offers to change configured engines', (tester) async {
      await open(tester, _state());
      expect(find.text('Change the Fast and Best engines'), findsOneWidget);
    });
  });
}
