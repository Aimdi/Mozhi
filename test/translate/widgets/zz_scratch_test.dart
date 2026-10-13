import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');
const _hebrew = Language(code: 'he', name: 'Hebrew', nativeName: 'עברית');

const _done = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour le monde',
);

TranslateState _streaming(String text) => readyState(
  engine: claude,
  input: 'Hello world',
  status: TranslateStatus.translating,
  result: TranslationResult(
    engineId: 'ai:claude',
    engineName: 'Claude',
    text: text,
    isComplete: false,
  ),
);

TranslateState _finished(
  TranslationResult result, {
  Language target = french,
}) => readyState(
  engine: claude,
  input: 'Hello world',
  result: result,
  target: target,
);

/// Lets the test emit states one by one after the first build.
Future<StreamController<TranslateState>> _listen(
  TranslateHarness harness,
  TranslateState initial,
) async {
  final controller = StreamController<TranslateState>();
  addTearDown(controller.close);
  whenListen(harness.translate, controller.stream, initialState: initial);
  return controller;
}

Future<void> _emit(
  WidgetTester tester,
  StreamController<TranslateState> controller,
  TranslateState state,
) async {
  controller.add(state);
  await tester.pump();
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('A1 language buttons', () {
    testWidgets('keep the button tap action and a descriptive label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      Finder button(String key) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(FilledButton),
      );
      expect(
        tester.getSemantics(button('translate_source_button')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
          label: 'Source language: Detected: English',
        ),
      );
      final target = tester.getSemantics(button('translate_target_button'));
      expect(
        target,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
          label: 'Target language: French',
        ),
      );

      // Activating the node (TalkBack double tap, web click) opens the
      // picker.
      tester.semantics.tap(find.semantics.byLabel('Target language: French'));
      await tester.pumpAndSettle();
      expect(find.text('Translate to'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('flag an uncertain detection of a single word', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Poison',
            detectedSource: 'de',
          ),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(
        find.bySemanticsLabel('Source language: Detected: German?'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });
  });

  group('alt', () {
    testWidgets('alternatives announce their count', (tester) async {
      final initial = _finished(_done)
          .copyWith(alternativesStatus: ExtraStatus.loading);
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const ExtrasSection(),
        supportsAnnounce: true,
      );
      await tester.tap(find.text('Alternatives'));
      // The progress bar never settles.
      await tester.pump(const Duration(milliseconds: 500));
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('translate_alternatives_progress')),
      );
      expect(progress.semanticsLabel, 'Loading…');
      await _emit(
        tester,
        controller,
        initial.copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: '',
            alternatives: [
              Alternative(text: 'Salut le monde'),
              Alternative(text: 'Coucou le monde'),
            ],
          ),
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('2 alternatives'),
      ]);
    });

  });
}
