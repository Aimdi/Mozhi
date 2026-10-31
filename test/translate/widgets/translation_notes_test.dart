import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/output_card.dart';
import 'package:mozhi/translate/widgets/translation_notes.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  final l10n = AppLocalizationsEn();

  TranslateState withResult(
    TranslationResult result, {
    TranslationFallback? fallback,
  }) => translatedState(result: result).copyWith(fallback: () => fallback);

  group(TranslationNotes, () {
    testWidgets('shows nothing without notes or while streaming', (
      tester,
    ) async {
      final plain = translatedState();
      expect(TranslationNotes.hasNotes(plain), isFalse);
      expect(TranslationNotes.hasNotes(readyState()), isFalse);
      final streaming = withResult(
        helloResult.copyWith(isComplete: false, maskedPersonalData: 1),
      );
      expect(TranslationNotes.hasNotes(streaming), isFalse);
      final harness = TranslateHarness(state: plain);
      await harness.pump(tester, child: TranslationNotes(state: plain));
      expect(find.byKey(const Key('translate_notes')), findsNothing);
      await harness.pump(tester, child: TranslationNotes(state: streaming));
      expect(find.byKey(const Key('translate_notes')), findsNothing);
    });

    testWidgets('lists the fallback, kept data and warnings', (tester) async {
      final state = withResult(
        helloResult.copyWith(
          maskedPersonalData: 2,
          warnings: const [
            TranslationWarning(TranslationWarningKind.links),
            TranslationWarning(
              TranslationWarningKind.glossary,
              items: ['serveur', 'nuage'],
            ),
          ],
        ),
        fallback: const TranslationFallback(
          fromEngineName: 'Google',
          reason: TranslationWarningKind.echo,
          engineName: 'Offline (on-device)',
          onDevice: true,
        ),
      );
      final harness = TranslateHarness(state: state);
      final semantics = tester.ensureSemantics();
      await harness.pump(tester, child: TranslationNotes(state: state));
      expect(
        find.text(
          'Google returned the original text. Translated on this device.',
        ),
        findsOneWidget,
      );
      expect(find.text('2 items kept on this device'), findsOneWidget);
      expect(find.text('Links may be missing or changed'), findsOneWidget);
      expect(
        find.text('Glossary terms not used: serveur, nuage'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Translation checks'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('2 items kept on this device')),
        matchesSemantics(
          label: '2 items kept on this device',
          hint: l10n.translatePersonalDataKeptHint,
        ),
      );
      semantics.dispose();
    });

    testWidgets('renders in dark mode', (tester) async {
      final state = withResult(
        helloResult.copyWith(
          warnings: const [TranslationWarning(TranslationWarningKind.echo)],
        ),
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(
        tester,
        child: TranslationNotes(state: state),
        themeMode: ThemeMode.dark,
      );
      expect(
        find.text('The translation is the same as the original'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    test('has a line for every warning', () {
      const target = Language(code: 'fr', name: 'French');
      final lines = {
        for (final kind in TranslationWarningKind.values)
          TranslationNotes.warningText(
            l10n,
            TranslationWarning(kind, items: const ['x']),
            target: target,
          ),
      };
      expect(lines, hasLength(TranslationWarningKind.values.length));
      expect(lines, contains('This may not be in French'));
      expect(lines, contains('This looks like a reply, not a translation'));
    });

    test('says why and where the fallback translated', () {
      String text(TranslationWarningKind reason, {bool onDevice = false}) =>
          TranslationNotes.fallbackText(
            l10n,
            TranslationFallback(
              fromEngineName: 'Google',
              reason: reason,
              engineName: 'DeepL',
              onDevice: onDevice,
            ),
          );
      expect(
        text(TranslationWarningKind.wrongLanguage),
        'Google answered in the wrong language. Translated with DeepL.',
      );
      expect(
        text(TranslationWarningKind.length),
        'Google returned an incomplete or garbled translation. '
        'Translated with DeepL.',
      );
      expect(
        text(TranslationWarningKind.notATranslation, onDevice: true),
        'Google replied instead of translating. Translated on this device.',
      );
      expect(
        text(TranslationWarningKind.echo),
        'Google returned the original text. Translated with DeepL.',
      );
    });

    test('says when DuckDuckGo took over from Google', () {
      expect(
        TranslationNotes.fallbackText(
          l10n,
          const TranslationFallback(
            fromEngineName: 'Google',
            engineName: 'DuckDuckGo',
            onDevice: false,
            allServersFailed: true,
          ),
        ),
        'Google failed on every server, so DuckDuckGo translated this.',
      );
    });
  });

  group('OutputCard', () {
    testWidgets('names DuckDuckGo when it took over from Google', (
      tester,
    ) async {
      final state = withResult(
        const TranslationResult(
          engineId: 'mozhi:duckduckgo',
          engineName: 'DuckDuckGo',
          text: 'Bonjour le monde',
          destination: PublicInstanceDestination(
            'mozhi.example',
            engine: 'duckduckgo',
          ),
        ),
        fallback: const TranslationFallback(
          fromEngineName: 'Google',
          engineName: 'DuckDuckGo',
          onDevice: false,
          allServersFailed: true,
        ),
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.text(
          'Google failed on every server, so DuckDuckGo translated this.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('translate_output_footer')))
            .data,
        contains('DuckDuckGo'),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_output_destination')),
          matching: find.textContaining('DuckDuckGo via mozhi.example'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the notes of a finished translation', (tester) async {
      final state = withResult(helloResult.copyWith(maskedPersonalData: 1));
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('1 item kept on this device'), findsOneWidget);
    });

    testWidgets('keeps the finished part with the error and Retry', (
      tester,
    ) async {
      final state =
          translatedState(result: helloResult.copyWith(isComplete: false))
              .copyWith(
                status: TranslateStatus.failure,
                error: () =>
                    const LlmApiException('overloaded', statusCode: 529),
              );
      final harness = TranslateHarness(state: state);
      when(harness.translate.translate).thenAnswer((_) async {});
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Bonjour le monde'), findsOneWidget);
      final error = find.byKey(const Key('translate_partial_error'));
      expect(error, findsOneWidget);
      await tester.tap(
        find.descendant(of: error, matching: find.text('Retry')).first,
      );
      verify(harness.translate.translate).called(1);
    });
  });
}
