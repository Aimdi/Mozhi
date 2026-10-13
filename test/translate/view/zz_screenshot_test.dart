// Temporary visual QA (deleted after use).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _out =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/shots';
const _fonts = '/opt/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';

Future<void> _loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Italic']) {
    roboto.addFont(
      Future.value(
        ByteData.sublistView(File('$_fonts/Roboto-$w.ttf').readAsBytesSync()),
      ),
    );
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('$_fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
        ),
      ),
    );
  await icons.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  final renderView = tester.binding.renderViews.first;
  final layer = renderView.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(renderView.paintBounds);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  extraShots();
  setUpAll(() async {
    registerTranslateFallbacks();
    await _loadFonts();
  });

  const aiResult = TranslationResult(
    engineId: 'ai:claude',
    engineName: 'Claude',
    text: 'Bonjour à tous, merci d’être venus si nombreux ce soir.',
    detectedSource: 'en',
    elapsed: Duration(milliseconds: 1840),
  );

  Future<void> pumpShot(
    WidgetTester tester,
    TranslateHarness harness,
    String name,
    Size size, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    await harness.pump(tester, size: size, themeMode: mode);
    await _shot(tester, name);
  }

  testWidgets('phone light', (tester) async {
    final harness = TranslateHarness(
      state: translatedState(
        engine: claude,
        input: 'Hello everyone, thanks for coming tonight.',
        result: aiResult,
      ).copyWith(options: const TranslationOptions(formality: Formality.more)),
      settings: const AppSettings(instantTranslateAi: false),
    );
    await pumpShot(tester, harness, 'phone_light', const Size(400, 860));
  });

  testWidgets('phone dark mozhi', (tester) async {
    final harness = TranslateHarness(state: translatedState());
    await pumpShot(
      tester,
      harness,
      'phone_dark',
      const Size(400, 860),
      mode: ThemeMode.dark,
    );
  });

  testWidgets('wide', (tester) async {
    final harness = TranslateHarness(
      state: translatedState(
        engine: claude,
        input: 'Hello everyone, thanks for coming tonight.',
        result: aiResult,
      ),
    );
    await pumpShot(tester, harness, 'wide', const Size(1280, 800));
  });

  testWidgets('compare', (tester) async {
    final harness = TranslateHarness(
      state: translatedState().copyWith(
        compareMode: true,
        comparing: true,
        compareEntries: const [
          CompareEntry.success(helloResult),
          CompareEntry.failure(
            engineId: 'ai:claude',
            engineName: 'Claude',
            error: LlmApiException('x', statusCode: 401),
          ),
        ],
      ),
    );
    await pumpShot(tester, harness, 'compare', const Size(400, 860));
  });

  testWidgets('picker', (tester) async {
    final harness = TranslateHarness(
      state: readyState(engine: claude),
      settings: const AppSettings(recentLanguages: [german]),
    );
    await harness.pump(tester, size: const Size(400, 860));
    await tester.tap(find.byKey(const Key('translate_target_button')));
    await tester.pumpAndSettle();
    await _shot(tester, 'picker');
  });

  testWidgets('engines', (tester) async {
    final harness = TranslateHarness(state: readyState());
    await harness.pump(tester, size: const Size(400, 860));
    await tester.tap(find.byKey(const Key('translate_engine_selector')));
    await tester.pumpAndSettle();
    await _shot(tester, 'engines');
  });

  testWidgets('options', (tester) async {
    final harness = TranslateHarness(state: readyState(engine: claude));
    await harness.pump(tester, size: const Size(400, 860));
    await tester.tap(find.byKey(const Key('translate_options_button')));
    await tester.pumpAndSettle();
    await _shot(tester, 'options');
  });

  testWidgets('empty', (tester) async {
    final harness = TranslateHarness(
      state: const TranslateState(enginesStatus: EnginesStatus.failure),
    );
    await pumpShot(tester, harness, 'empty', const Size(400, 860));
  });

  testWidgets('narrow large text', (tester) async {
    final harness = TranslateHarness(
      state: translatedState(engine: claude, result: aiResult),
      settings: const AppSettings(instantTranslateAi: false),
    );
    await harness.pump(tester, size: const Size(320, 900), textScale: 1.6);
    await _shot(tester, 'narrow_large');
  });
}

void extraShots() {
  const result = TranslationResult(
    engineId: 'ai:claude',
    engineName: 'Claude',
    text: 'Il pleut des cordes, prends ton parapluie.',
    elapsed: Duration(milliseconds: 2100),
  );
  testWidgets('insights', (tester) async {
    final harness = TranslateHarness(
      state: translatedState(
        engine: claude,
        input: "It's raining cats and dogs, take your umbrella.",
        result: result,
      ).copyWith(
        insightsStatus: ExtraStatus.ready,
        insights: const [
          WordInsight(
            sourceText: 'raining cats and dogs',
            targetText: 'pleut des cordes',
            type: 'idiom',
            explanation: 'French uses "ropes" instead of cats and dogs.',
            variations: [
              Alternative(text: 'pleut à verse', explanation: 'neutral'),
              Alternative(text: 'tombe des trombes d’eau', explanation: 'vivid'),
            ],
          ),
        ],
        alternativesStatus: ExtraStatus.ready,
        alternatives: () => const AlternativeTranslations(
          description: 'Idiomatic and informal, matching the original tone.',
          alternatives: [
            Alternative(
              text: 'Il pleut à verse, prends ton parapluie.',
              explanation: 'more neutral',
            ),
          ],
        ),
      ),
    );
    await harness.pump(tester, size: const Size(400, 1100));
    await tester.tap(find.byKey(const Key('translate_insights_button')));
    await tester.tap(find.text('Alternatives'));
    await tester.pumpAndSettle();
    await _shot(tester, 'insights');
    await tester.tapOnText(find.textRange.ofSubstring('pleut des cordes'));
    await tester.pumpAndSettle();
    await _shot(tester, 'insight_sheet');
  });

  testWidgets('explain + dictionary', (tester) async {
    final harness = TranslateHarness(
      state: translatedState(
        engine: claude,
        input: 'umbrella',
        result: const TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'parapluie',
        ),
      ).copyWith(
        dictionaryStatus: ExtraStatus.ready,
        dictionary: () => const DictionaryEntry(
          word: 'umbrella',
          pronunciation: 'ʌmˈbrɛlə',
          partsOfSpeech: ['noun'],
          senses: [
            DictionarySense(
              definition: 'a device for protection against rain',
              partOfSpeech: 'noun',
              translations: ['parapluie', 'ombrelle'],
            ),
            DictionarySense(
              definition: 'something that covers many things',
              partOfSpeech: 'noun',
              translations: ['égide'],
              usage: 'figurative',
            ),
          ],
          examples: [
            DictionaryExample(
              source: 'Take an umbrella.',
              translation: 'Prends un parapluie.',
            ),
          ],
          synonyms: ['parasol', 'brolly'],
        ),
        explainStatus: ExtraStatus.loading,
        explanation:
            '## Word choice\n**Parapluie** literally means "against rain".\n\n'
            '- *ombrelle* is a sun umbrella\n- `pépin` is informal slang',
      ),
    );
    await harness.pump(tester, size: const Size(400, 1300));
    await _shot(tester, 'dictionary');
    await tester.tap(find.byKey(const Key('translate_explain_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await _shot(tester, 'explain');
  });
}
