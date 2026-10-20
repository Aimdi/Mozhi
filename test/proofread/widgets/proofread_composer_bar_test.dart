import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/voice/voice.dart' show SpeechInputService;
import 'package:translation_repository/translation_repository.dart';

import '../../translate/helpers/helpers.dart' show FakeSpeechInput;
import '../helpers/proofread_helpers.dart';

void main() {
  late MockProofreadCubit cubit;
  late MockTranslateCubit translateCubit;

  setUpAll(() => registerFallbackValue(ProofreadVariety.enGb));

  setUp(() {
    cubit = MockProofreadCubit();
    translateCubit = MockTranslateCubit();
    stubProofreadCubit(cubit);
    when(() => cubit.isClosed).thenReturn(false);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
  });

  Future<void> pumpBar(
    WidgetTester tester,
    ProofreadState state, {
    Size size = const Size(400, 800),
  }) async {
    setSurface(tester, size);
    whenListen(
      cubit,
      const Stream<ProofreadState>.empty(),
      initialState: state,
    );
    await tester.pumpProofread(
      const Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(12),
            child: ProofreadComposerBar(),
          ),
        ),
      ),
      translateCubit: translateCubit,
      proofreadCubit: cubit,
    );
  }

  group('ProofreadComposerBar', () {
    testWidgets('is [options | go | language]', (tester) async {
      await pumpBar(tester, readyState.copyWith(input: 'text'));

      final options = tester.getCenter(
        find.byKey(const Key('proofread_options_button')),
      );
      final go = tester.getCenter(find.byKey(const Key('proofread_button')));
      final language = tester.getCenter(
        find.byKey(const Key('proofread_language_button')),
      );
      expect(options.dx, lessThan(go.dx));
      expect(go.dx, lessThan(language.dx));
      for (final key in [
        'proofread_options_button',
        'proofread_button',
        'proofread_language_button',
      ]) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
          reason: key,
        );
      }
    });

    testWidgets('fits a small phone at 200% text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpBar(
        tester,
        readyState.copyWith(variety: () => ProofreadVariety.es419),
        size: const Size(320, 640),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens the options', (tester) async {
      await pumpBar(tester, readyState);

      await tester.tap(find.byKey(const Key('proofread_options_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('proofread_options_sheet')), findsOneWidget);
      expect(find.byType(ProofreadControls), findsOneWidget);
    });

    testWidgets('the options stay above the keyboard', (tester) async {
      await pumpBar(tester, readyState.copyWith(context: 'An email'));
      // A 300 dp keyboard at the bottom of the 800 dp screen.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      const keyboardTop = 800.0 - 300;

      await tester.tap(find.byKey(const Key('proofread_options_button')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('proofread_options_sheet'))).bottom,
        lessThanOrEqualTo(keyboardTop),
      );

      // The context field scrolls into view above the keyboard.
      await tester.showKeyboard(find.byKey(const Key('proofread_context')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('proofread_context'))).bottom,
        lessThanOrEqualTo(keyboardTop),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ProofreadLanguageButton', () {
    testWidgets('says "Detect language" by default', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBar(tester, readyState);

      expect(find.text('Detect language'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Language: detected automatically'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp('Detect language')), findsNothing);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
      semantics.dispose();
    });

    testWidgets('names the detected language with a sparkle', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpBar(
        tester,
        successState().copyWith(
          result: () => const ProofreadResult(
            correctedText: 'I have a cat.',
            detectedLanguage: 'en',
          ),
        ),
      );

      expect(find.text('English'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      expect(
        find.bySemanticsLabel('Language: Detected: English'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('names a chosen region', (tester) async {
      await pumpBar(
        tester,
        successState().copyWith(variety: () => ProofreadVariety.enGb),
      );

      expect(find.text('English (UK)'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    });

    testWidgets('picks a region from the list', (tester) async {
      await pumpBar(tester, readyState);

      await tester.tap(find.byKey(const Key('proofread_language_button')));
      await tester.pumpAndSettle();

      expect(find.text('Language'), findsOneWidget);
      final auto = find.byKey(const ValueKey('proofread_language_auto'));
      expect(tester.widget<ListTile>(auto).selected, isTrue);
      expect(
        find.text("Keep the author's spelling and vocabulary"),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('proofread_language_en-GB')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('proofread_language_en-GB')));
      await tester.pumpAndSettle();

      verify(() => cubit.setVariety(ProofreadVariety.enGb)).called(1);
      expect(
        find.byKey(const ValueKey('proofread_language_auto')),
        findsNothing,
      );
    });

    testWidgets('goes back to detecting the language', (tester) async {
      await pumpBar(
        tester,
        readyState.copyWith(variety: () => ProofreadVariety.enUs),
      );

      await tester.tap(find.byKey(const Key('proofread_language_button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('proofread_language_en-US')),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('proofread_language_auto')));
      await tester.pumpAndSettle();

      verify(() => cubit.setVariety(null)).called(1);
    });

    testWidgets('keeps the language when dismissed', (tester) async {
      await pumpBar(tester, readyState);

      await tester.tap(find.byKey(const Key('proofread_language_button')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      verifyNever(() => cubit.setVariety(any()));
    });
  });

  group('proofreadLanguageLabel', () {
    testWidgets('prefers the region, then the detected language', (
      tester,
    ) async {
      late AppLocalizations l10n;
      await tester.pumpProofread(
        Builder(
          builder: (context) {
            l10n = context.l10n;
            return const SizedBox();
          },
        ),
        translateCubit: translateCubit,
      );
      ProofreadState detected(String? code) => readyState.copyWith(
        result: () =>
            ProofreadResult(correctedText: 'x', detectedLanguage: code),
      );

      expect(proofreadLanguageLabel(l10n, readyState), (
        'Detect language',
        false,
      ));
      expect(proofreadLanguageLabel(l10n, detected('de')), ('German', true));
      expect(proofreadLanguageLabel(l10n, detected(' ')), (
        'Detect language',
        false,
      ));
      expect(proofreadLanguageLabel(l10n, detected('qq')), (
        'Detect language',
        false,
      ));
      expect(
        proofreadLanguageLabel(
          l10n,
          detected('de').copyWith(variety: () => ProofreadVariety.deAt),
        ),
        ('German (Austria)', false),
      );
    });
  });

  group('proofreadOptionsModified', () {
    test('counts every option of the sheet, not the language', () {
      expect(proofreadOptionsModified(readyState), isFalse);
      expect(
        proofreadOptionsModified(
          readyState.copyWith(variety: () => ProofreadVariety.enUs),
        ),
        isFalse,
      );
      expect(
        proofreadOptionsModified(readyState.copyWith(context: '  ')),
        isFalse,
      );
      expect(
        proofreadOptionsModified(readyState.copyWith(context: 'thesis')),
        isTrue,
      );
      expect(
        proofreadOptionsModified(
          readyState.copyWith(readingLevel: ReadingLevel.a1),
        ),
        isTrue,
      );
    });
  });

  group('ProofreadInputCard voice input', () {
    Future<void> pumpCard(
      WidgetTester tester,
      ProofreadState state, {
      SpeechInputService? speech,
      bool compact = false,
    }) async {
      setSurface(tester, const Size(400, 800));
      whenListen(
        cubit,
        const Stream<ProofreadState>.empty(),
        initialState: state,
      );
      Widget card = Scaffold(body: ProofreadInputCard(compact: compact));
      if (speech != null) {
        card = RepositoryProvider<SpeechInputService>.value(
          value: speech,
          child: card,
        );
      }
      await tester.pumpProofread(
        card,
        translateCubit: translateCubit,
        proofreadCubit: cubit,
      );
    }

    testWidgets('is not offered without a speech service', (tester) async {
      await pumpCard(tester, readyState);
      expect(find.byKey(const Key('proofread_voice_input')), findsNothing);
    });

    testWidgets('appends dictated text in the chosen region', (tester) async {
      final speech = FakeSpeechInput();
      await pumpCard(
        tester,
        readyState.copyWith(
          input: 'Hello',
          variety: () => ProofreadVariety.enGb,
        ),
        speech: speech.service,
      );
      final mic = find.descendant(
        of: find.byKey(const Key('proofread_voice_input')),
        matching: find.byType(IconButton),
      );

      await tester.tap(mic);
      await tester.pump();
      expect(speech.languages, ['en-GB']);

      speech.say('wor');
      await tester.pump();
      verify(() => cubit.setInput('Hello wor')).called(1);
      speech.say('world', isFinal: true);
      await tester.pump();
      verify(() => cubit.setInput('Hello world')).called(1);
      speech.say('  ', isFinal: true);
      await tester.pump();
      verifyNever(() => cubit.setInput('Hello world '));
      final field = tester.widget<TextField>(
        find.byKey(const Key('proofread_input')),
      );
      expect(field.controller!.text, 'Hello world');
    });

    testWidgets('dictates in the device language while detecting', (
      tester,
    ) async {
      final speech = FakeSpeechInput();
      await pumpCard(tester, readyState, speech: speech.service);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('proofread_voice_input')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pump();
      expect(speech.languages, [null]);
      speech.say('Hi there', isFinal: true);
      await tester.pump();
      verify(() => cubit.setInput('Hi there')).called(1);
    });

    testWidgets('the docked composer has paste at its top end', (tester) async {
      await pumpCard(tester, readyState, compact: true);

      expect(find.byKey(const Key('proofread_paste')), findsOneWidget);
      expect(find.byKey(const Key('proofread_clear')), findsNothing);
      expect(find.textContaining('characters'), findsNothing);
      expect(
        tester.getCenter(find.byKey(const Key('proofread_paste'))).dy,
        lessThan(
          tester.getRect(find.byKey(const Key('proofread_input'))).bottom,
        ),
      );
    });

    testWidgets('the docked composer hides paste once there is text', (
      tester,
    ) async {
      await pumpCard(tester, readyState.copyWith(input: 'x'), compact: true);
      expect(find.byKey(const Key('proofread_paste')), findsNothing);
    });
  });
}
