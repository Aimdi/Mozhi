import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _enFr = LanguagePair(source: english, target: french);
const _enDe = LanguagePair(source: english, target: german);
const _deEn = LanguagePair(source: german, target: english);
const _frDe = LanguagePair(source: french, target: german);
const _pirate = LanguagePair(
  source: english,
  target: Language.custom('Pirate speak'),
);

Finder _pair(int index) => find.byKey(ValueKey('translate_empty_pair:$index'));

void main() {
  setUpAll(registerTranslateFallbacks);
  setUp(() => TranslateHero.clock = () => DateTime(2026, 10, 20, 9));
  tearDown(() => TranslateHero.clock = DateTime.now);

  group('translateGreeting', () {
    test('follows the time of day', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      String at(int hour) =>
          translateGreeting(l10n, DateTime(2026, 1, 1, hour));
      expect(at(4), 'Good evening');
      expect(at(5), 'Good morning');
      expect(at(11), 'Good morning');
      expect(at(12), 'Good afternoon');
      expect(at(17), 'Good afternoon');
      expect(at(18), 'Good evening');
      expect(at(23), 'Good evening');
    });
  });

  group('TranslateHero', () {
    testWidgets('greets and offers the camera and documents', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      expect(find.text('Good morning'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Good morning')),
        isSemantics(label: 'Good morning', isHeader: true),
      );
      expect(find.text('Recent pairs'), findsNothing);
      expect(find.text('Press ? for keyboard shortcuts'), findsNothing);

      await tester.tap(find.text('Camera'));
      verify(() => harness.router.push<void>(ImageTranslatePage.location))
          .called(1);
      await tester.tap(find.text('Document'));
      verify(() => harness.router.push<void>('/documents')).called(1);
      // 48 dp touch targets.
      for (final key in ['translate_hero_camera', 'translate_hero_document']) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
        );
      }
      handle.dispose();
    });

    testWidgets('offers recent pairs other than the current one', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(source: english),
        settings: const AppSettings(
          recentPairs: [_enFr, _enDe, _deEn, _frDe, _pirate],
        ),
      );
      await harness.pump(tester, child: const TranslateHero());
      expect(find.text('Recent pairs'), findsOneWidget);
      // English → French is in use; at most three others.
      expect(_pair(0), findsOneWidget);
      expect(_pair(2), findsOneWidget);
      expect(_pair(3), findsNothing);
      expect(
        find.descendant(of: _pair(0), matching: find.textContaining('German')),
        findsOneWidget,
      );

      await tester.tap(_pair(1));
      verify(() => harness.translate.applyLanguagePair(_deEn)).called(1);
    });

    testWidgets('disables pairs with a custom language the engine cannot '
        'take', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(recentPairs: [_pirate]),
      );
      await harness.pump(tester, child: const TranslateHero());
      final chip = tester.widget<ActionChip>(_pair(0));
      expect(chip.onPressed, isNull);
    });

    testWidgets('points to the keyboard shortcuts on large screens', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateHero(),
        size: const Size(1280, 800),
      );
      expect(find.text('Press ? for keyboard shortcuts'), findsOneWidget);
    });

    testWidgets('shows the quality chip above the app mark', (tester) async {
      final harness = TranslateHarness(
        state: readyState(engine: claude).copyWith(
          qualityMode: QualityMode.best,
          fastEngine: () => google,
          bestEngine: () => claude,
        ),
      );
      await harness.pump(tester, child: const TranslateHero());
      final chip = find.byKey(const Key('translate_quality_chip'));
      expect(chip, findsOneWidget);
      expect(find.text('Best'), findsOneWidget);
      final mark = tester.getRect(find.byIcon(Icons.translate_rounded));
      final rect = tester.getRect(chip);
      expect(rect.bottom, lessThanOrEqualTo(mark.top - 24));
      expect(rect.center.dx, closeTo(mark.center.dx, 0.5));
    });

    testWidgets('has no quality chip without quality modes', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      expect(find.byKey(const Key('translate_quality_chip')), findsNothing);
      expect(find.byType(QualityChip), findsNothing);
    });
  });
}
