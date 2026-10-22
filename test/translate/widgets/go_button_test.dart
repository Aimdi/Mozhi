import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/composer_card.dart' show ComposerGoButton;
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../../helpers/helpers.dart';
import '../helpers/helpers.dart';

Finder get _button => find.byKey(const Key('translate_translate_button'));

Finder get _progress => find.byKey(const Key('translate_go_progress'));

IconButton _iconButton(WidgetTester tester) =>
    tester.widget<IconButton>(_button);

/// Pumps the go button for [initial] and returns a controller whose states
/// the button sees next.
Future<StreamController<TranslateState>> _pump(
  WidgetTester tester,
  TranslateHarness harness,
  TranslateState initial,
) async {
  final states = StreamController<TranslateState>.broadcast();
  addTearDown(states.close);
  when(() => harness.translate.stream).thenAnswer((_) => states.stream);
  await harness.pump(tester, child: const TranslateGoButton());
  return states;
}

/// Shows [state] to the button.
Future<void> _emit(
  TranslateHarness harness,
  StreamController<TranslateState> states,
  TranslateState state,
  WidgetTester tester,
) async {
  harness.setState(state);
  states.add(state);
  // The state arrives, then the button rebuilds.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('TranslateGoButton', () {
    testWidgets('is disabled without input', (tester) async {
      final harness = TranslateHarness(state: readyState(input: '   '));
      await harness.pump(tester, child: const TranslateGoButton());
      expect(_button, findsOneWidget);
      expect(_iconButton(tester).onPressed, isNull);
    });

    testWidgets('translates right away when pressed', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester, child: const TranslateGoButton());
      await tester.tap(_button);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('taps lightly when pressed', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester, child: const TranslateGoButton());
      await tester.tap(_button);
      await tester.pump();
      expect(clipboard.haptics, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets('stays still with haptic feedback off', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(
        state: readyState(input: 'Hello'),
        settings: const AppSettings(hapticFeedback: false),
      );
      await harness.pump(tester, child: const TranslateGoButton());
      await tester.tap(_button);
      await tester.pump();
      expect(clipboard.haptics, isEmpty);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('translates again when there is a translation', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const TranslateGoButton());
      await tester.tap(_button);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('is named "Translate" with the shortcut as its tooltip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester, child: const TranslateGoButton());
      expect(
        tester.getSemantics(
          find.descendant(of: _button, matching: find.byType(Icon)),
        ),
        isSemantics(
          label: 'Translate',
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      expect(findTooltipMessage('Translate (Ctrl+Enter)'), findsOneWidget);
      expect(find.byIcon(ComposerGoButton.defaultIcon), findsOneWidget);
      // A 48 dp touch target.
      final size = tester.getSize(_button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      handle.dispose();
    });

    testWidgets('shows progress and stops a translation that takes a while', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final idle = readyState(input: 'Hello');
      final harness = TranslateHarness(state: idle);
      final states = await _pump(tester, harness, idle);

      await _emit(
        harness,
        states,
        readyState(input: 'Hello', status: TranslateStatus.translating),
        tester,
      );
      // Quick translations never flash the ring; a press still translates.
      expect(_progress, findsNothing);
      expect(find.byIcon(ComposerGoButton.defaultIcon), findsOneWidget);

      await pumpPastLoadingDelay(tester);
      expect(_progress, findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(findTooltipMessage('Stop translating'), findsOneWidget);
      expect(
        tester.getSemantics(
          find.descendant(of: _button, matching: find.byType(Icon)),
        ),
        isSemantics(
          label: 'Stop translating',
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );

      await tester.tap(_button);
      verify(harness.translate.stopTranslation).called(1);
      verifyNever(harness.translate.translate);

      await _emit(harness, states, translatedState(input: 'Hello'), tester);
      expect(_progress, findsNothing);
      expect(find.byIcon(ComposerGoButton.defaultIcon), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a translation that ends quickly never shows progress', (
      tester,
    ) async {
      final idle = readyState(input: 'Hello');
      final harness = TranslateHarness(state: idle);
      final states = await _pump(tester, harness, idle);
      await _emit(
        harness,
        states,
        readyState(input: 'Hello', status: TranslateStatus.translating),
        tester,
      );
      await _emit(harness, states, translatedState(input: 'Hello'), tester);
      await pumpPastLoadingDelay(tester);
      expect(_progress, findsNothing);
    });

    testWidgets('shows progress while a compare run takes a while', (
      tester,
    ) async {
      final idle = readyState(input: 'Hello').copyWith(compareMode: true);
      final harness = TranslateHarness(state: idle);
      final states = await _pump(tester, harness, idle);
      await tester.tap(_button);
      // TranslateCubit.translate compares in compare mode.
      verify(harness.translate.translate).called(1);

      await _emit(harness, states, idle.copyWith(comparing: true), tester);
      await pumpPastLoadingDelay(tester);
      expect(_progress, findsOneWidget);
      await tester.tap(_button);
      verify(harness.translate.stopTranslation).called(1);
    });

    group('with instant translation', () {
      Color? background(WidgetTester tester) =>
          _iconButton(tester).style?.backgroundColor?.resolve({});

      testWidgets('is a quiet arrow while typing translates by itself', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hello'));
        await harness.pump(tester, child: const TranslateGoButton());

        expect(background(tester), Colors.transparent);
        // Still translates right away when pressed.
        await tester.tap(_button);
        verify(harness.translate.translate).called(1);
      });

      testWidgets('is filled when typing does not translate', (tester) async {
        final harness = TranslateHarness(
          state: readyState(input: 'Hello'),
          settings: const AppSettings(instantTranslate: false),
        );
        await harness.pump(tester, child: const TranslateGoButton());

        final scheme = Theme.of(tester.element(_button)).colorScheme;
        expect(background(tester), scheme.primary);
      });

      testWidgets('follows the AI setting for AI engines', (tester) async {
        final harness = TranslateHarness(
          state: readyState(engine: claude, input: 'Hello'),
          settings: const AppSettings(instantTranslateAi: false),
        );
        await harness.pump(tester, child: const TranslateGoButton());

        final scheme = Theme.of(tester.element(_button)).colorScheme;
        expect(background(tester), scheme.primary);
      });

      testWidgets('is filled in compare mode, where it compares', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: readyState(input: 'Hello').copyWith(compareMode: true),
        );
        await harness.pump(tester, child: const TranslateGoButton());

        final scheme = Theme.of(tester.element(_button)).colorScheme;
        expect(background(tester), scheme.primary);
      });

      testWidgets('takes [instant] over the settings', (tester) async {
        final harness = TranslateHarness(
          state: readyState(input: 'Hello'),
          settings: const AppSettings(instantTranslate: false),
        );
        await harness.pump(
          tester,
          child: const TranslateGoButton(instant: true),
        );

        expect(background(tester), Colors.transparent);
      });

      testWidgets('still turns into Stop while a translation runs', (
        tester,
      ) async {
        final idle = readyState(input: 'Hello');
        final harness = TranslateHarness(state: idle);
        final states = await _pump(tester, harness, idle);
        await _emit(
          harness,
          states,
          readyState(input: 'Hello', status: TranslateStatus.translating),
          tester,
        );
        await pumpPastLoadingDelay(tester);

        final scheme = Theme.of(tester.element(_button)).colorScheme;
        expect(background(tester), scheme.secondaryContainer);
        expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      });

      test('translateGoInstant follows the engine kind and compare mode', () {
        const settings = AppSettings(instantTranslateAi: false);
        expect(translateGoInstant(readyState(), settings), isTrue);
        expect(
          translateGoInstant(readyState(engine: claude), settings),
          isFalse,
        );
        expect(
          translateGoInstant(
            readyState().copyWith(compareMode: true),
            settings,
          ),
          isFalse,
        );
        expect(translateGoInstant(const TranslateState(), settings), isFalse);
      });
    });

    testWidgets('fits a 48 dp target with a 40 dp circle', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester, child: const TranslateGoButton());

      expect(
        tester.getSize(find.byType(TranslateGoButton)),
        const Size.square(ComposerGoButton.targetSize),
      );
      expect(
        _iconButton(tester).style?.fixedSize?.resolve({}),
        const Size.square(ComposerGoButton.visualSize),
      );
    });

    testWidgets('is filled without a SettingsCubit above', (tester) async {
      await tester.pumpApp(
        BlocProvider<TranslateCubit>.value(
          value: TranslateHarness(state: readyState(input: 'Hello')).translate,
          child: const Scaffold(body: Center(child: TranslateGoButton())),
        ),
      );

      final scheme = Theme.of(tester.element(_button)).colorScheme;
      expect(
        _iconButton(tester).style?.backgroundColor?.resolve({}),
        scheme.primary,
      );
    });

    testWidgets('keeps the keyboard focus when it turns into Stop', (
      tester,
    ) async {
      final idle = readyState(input: 'Hello');
      final harness = TranslateHarness(state: idle);
      final states = await _pump(tester, harness, idle);
      final focus = Focus.of(
        tester.element(
          find.descendant(of: _button, matching: find.byType(Icon)),
        ),
      )..requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await _emit(
        harness,
        states,
        readyState(input: 'Hello', status: TranslateStatus.translating),
        tester,
      );
      await pumpPastLoadingDelay(tester);
      expect(_progress, findsOneWidget);
      expect(focus.hasFocus, isTrue);
    });
  });
}
