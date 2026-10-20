import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

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
      expect(find.byIcon(Icons.rocket_launch), findsOneWidget);
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
      expect(find.byIcon(Icons.rocket_launch), findsOneWidget);

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
      expect(find.byIcon(Icons.rocket_launch), findsOneWidget);
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
