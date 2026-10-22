import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
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
      expect(find.text('Best · Claude'), findsOneWidget);
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

  group('Continue', () {
    final entry = HistoryEntry(
      id: '1',
      text: 'Where is the   train station?',
      translation: 'Où est la gare ?',
      source: Language.auto,
      target: french,
      engineId: deepl.id,
      engineName: deepl.name,
      createdAt: DateTime(2026, 10, 20),
      detectedSource: 'en',
    );
    final lookUp = HistoryEntry(
      id: '2',
      text: 'gare',
      translation: 'station',
      source: french,
      target: english,
      engineId: claude.id,
      engineName: claude.name,
      createdAt: DateTime(2026, 10, 21),
      kind: HistoryEntryKind.dictionary,
    );
    final continueButton = find.byKey(const Key('translate_hero_continue'));

    TranslateHarness harnessWith({
      List<HistoryEntry>? entries,
      AppSettings settings = const AppSettings(),
      bool paused = false,
      TranslateState? state,
    }) {
      final harness = TranslateHarness(
        state: state,
        settings: settings,
        history: HistoryState(
          status: HistoryStatus.ready,
          entries: entries ?? [lookUp, entry],
          incognito: paused,
        ),
      );
      when(() => harness.translate.restoreHistoryEntry(any())).thenReturn(true);
      return harness;
    }

    testWidgets('offers the last translation in one line', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = harnessWith();
      await harness.pump(tester, child: const TranslateHero());
      expect(continueButton, findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Where is the train station?'), findsOneWidget);
      expect(find.text('\u2068EN\u2069 → \u2068FR\u2069'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(r'Continue: Where is the train station\?, .*English.*French'),
        ),
        findsOneWidget,
      );
      await tester.tap(continueButton);
      verify(() => harness.translate.restoreHistoryEntry(entry)).called(1);
      handle.dispose();
    });

    testWidgets('names an undetected source by its sparkle', (tester) async {
      final harness = harnessWith(
        entries: [
          HistoryEntry(
            id: '5',
            text: 'Hallo',
            translation: 'Bonjour',
            source: Language.auto,
            target: french,
            engineId: deepl.id,
            engineName: deepl.name,
            createdAt: DateTime(2026, 10, 22),
          ),
        ],
      );
      await harness.pump(tester, child: const TranslateHero());
      expect(find.text('\u2068✦\u2069 → \u2068FR\u2069'), findsOneWidget);
    });

    testWidgets('is hidden while history is off or paused', (tester) async {
      for (final harness in [
        harnessWith(settings: const AppSettings(saveHistory: false)),
        harnessWith(settings: const AppSettings(incognito: true)),
        harnessWith(paused: true),
        harnessWith(entries: [lookUp]),
        harnessWith(entries: const []),
      ]) {
        await harness.pump(tester, child: const TranslateHero());
        expect(continueButton, findsNothing);
      }
    });

    testWidgets("is hidden when the engine lacks the entry's languages", (
      tester,
    ) async {
      final custom = HistoryEntry(
        id: '3',
        text: 'Ahoy',
        translation: 'Arr',
        source: german,
        target: const Language.custom('Pirate speak'),
        engineId: claude.id,
        engineName: claude.name,
        createdAt: DateTime(2026, 10, 22),
      );
      final unknownSource = HistoryEntry(
        id: '4',
        text: 'Hola',
        translation: 'Bonjour',
        source: const Language(code: 'es', name: 'Spanish'),
        target: french,
        engineId: deepl.id,
        engineName: deepl.name,
        createdAt: DateTime(2026, 10, 22),
      );
      const noEngine = TranslateState();
      for (final harness in [
        harnessWith(entries: [custom]),
        harnessWith(entries: [unknownSource]),
        harnessWith(state: noEngine),
      ]) {
        await harness.pump(tester, child: const TranslateHero());
        expect(continueButton, findsNothing);
      }
    });

    test('translateHeroContinueEntry takes custom languages AI engines '
        'offer', () {
      final custom = HistoryEntry(
        id: '3',
        text: 'Ahoy',
        translation: 'Arr',
        source: const Language.custom('Gen Z'),
        target: french,
        engineId: claude.id,
        engineName: claude.name,
        createdAt: DateTime(2026, 10, 22),
      );
      expect(
        translateHeroContinueEntry(
          settings: const AppSettings(),
          history: HistoryState(entries: [custom]),
          state: readyState(engine: claude),
        ),
        custom,
      );
      expect(
        translateHeroContinueEntry(
          settings: const AppSettings(),
          history: null,
          state: readyState(),
        ),
        isNull,
      );
    });
  });

  group('TranslatePasteOffer', () {
    late bool hasText;
    late String? clipboard;
    late int asked;
    late int read;
    final defaults = (
      has: TranslatePasteOffer.hasClipboardText,
      read: TranslatePasteOffer.readClipboardText,
      asks: TranslatePasteOffer.asksOnResume,
    );

    test('asks only on Android, through the platform clipboard', () async {
      // Tests run as Android.
      expect(defaults.asks(), isTrue);
      expect(defaults.has, same(Clipboard.hasStrings));
    });

    testWidgets('reads the platform clipboard', (tester) async {
      FakeClipboard(tester, pasteText: 'Hallo');
      expect(await defaults.read(), 'Hallo');
    });

    setUp(() {
      hasText = true;
      clipboard = 'Guten Morgen';
      asked = 0;
      read = 0;
      TranslatePasteOffer.hasClipboardText = () async {
        asked++;
        return hasText;
      };
      TranslatePasteOffer.readClipboardText = () async {
        read++;
        return clipboard;
      };
      TranslatePasteOffer.asksOnResume = () => true;
    });

    tearDown(() {
      TranslatePasteOffer.hasClipboardText = defaults.has;
      TranslatePasteOffer.readClipboardText = defaults.read;
      TranslatePasteOffer.asksOnResume = defaults.asks;
    });

    final offer = find.byKey(const Key('translate_paste_offer'));

    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('only asks whether there is text, when the app resumes', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      expect(offer, findsNothing);
      expect(asked, 0);
      await resume(tester);
      expect(asked, 1);
      // Nothing was read, nothing translated.
      expect(read, 0);
      verifyNever(
        () => harness.translate.setInput(
          any(),
          pasted: any(named: 'pasted'),
          dictated: any(named: 'dictated'),
        ),
      );
      expect(offer, findsOneWidget);
      expect(find.text('Paste and translate'), findsOneWidget);
    });

    testWidgets('reads and pastes the text only when tapped', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      await tester.tap(offer);
      await tester.pump();
      await tester.pump();
      expect(read, 1);
      verify(() => harness.translate.setInput('Guten Morgen', pasted: true))
          .called(1);
      expect(offer, findsNothing);
    });

    testWidgets('says "Paste" when pasted text is not translated by itself', (
      tester,
    ) async {
      final harness = TranslateHarness(
        settings: const AppSettings(instantTranslate: false),
      );
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      expect(find.text('Paste copied text'), findsOneWidget);
    });

    testWidgets('can be dismissed', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(offer, findsNothing);
      expect(read, 0);
    });

    testWidgets('is not offered without text or with input', (tester) async {
      hasText = false;
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      expect(offer, findsNothing);

      hasText = true;
      harness.setState(readyState(input: 'Hallo'));
      await resume(tester);
      expect(offer, findsNothing);
      expect(asked, 1);
    });

    testWidgets('ignores an empty or unreadable clipboard', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      clipboard = '  ';
      await tester.tap(offer);
      await tester.pump();
      verifyNever(
        () => harness.translate.setInput(
          any(),
          pasted: any(named: 'pasted'),
          dictated: any(named: 'dictated'),
        ),
      );

      TranslatePasteOffer.hasClipboardText = () async => throw Exception();
      await resume(tester);
      expect(offer, findsNothing);
    });

    testWidgets('never asks where that would read the clipboard', (
      tester,
    ) async {
      TranslatePasteOffer.asksOnResume = () => false;
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      await resume(tester);
      expect(asked, 0);
      expect(offer, findsNothing);
    });
  });
}
