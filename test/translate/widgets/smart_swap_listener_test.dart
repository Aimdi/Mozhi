import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../helpers/helpers.dart';

const _notice = SmartSwapNotice(
  id: 1,
  previousTarget: french,
  newTarget: english,
);

TranslateState _swapped([SmartSwapNotice? notice = _notice]) => readyState(
  input: 'Bonjour',
  target: english,
).copyWith(smartSwapNotice: () => notice);

const _message = 'Translating into English instead';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('SmartSwapListener', () {
    late StreamController<TranslateState> states;
    late TranslateHarness harness;

    setUp(() {
      states = StreamController<TranslateState>.broadcast();
      harness = TranslateHarness();
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      when(harness.translate.undoSmartSwap).thenAnswer((_) async {});
    });

    tearDown(() => states.close());

    Future<void> pump(WidgetTester tester) => harness.pump(
      tester,
      child: const SmartSwapListener(child: SizedBox.shrink()),
    );

    testWidgets('shows a notice once and consumes it', (tester) async {
      await pump(tester);
      expect(find.text(_message), findsNothing);

      states.add(_swapped());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text(_message), findsOneWidget);
      verify(harness.translate.consumeSmartSwapNotice).called(1);

      // The consumed notice, or the same one again, is not shown twice.
      states
        ..add(_swapped(null))
        ..add(_swapped());
      await tester.pump();
      verifyNever(harness.translate.consumeSmartSwapNotice);
    });

    for (final accessible in [false, true]) {
      testWidgets(
        'stays until dismissed (accessible navigation: $accessible)',
        (tester) async {
          // Keyboard users, with or without a screen reader, need time to
          // reach Undo (WCAG 2.2.1).
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(accessibleNavigation: accessible);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await pump(tester);
          states.add(_swapped());
          await tester.pumpAndSettle();
          final bar = tester.widget<SnackBar>(find.byType(SnackBar));
          expect(bar.persist, isTrue);
          expect(bar.showCloseIcon, isTrue);

          await tester.pump(const Duration(minutes: 1));
          await tester.pumpAndSettle();
          expect(find.text(_message), findsOneWidget);

          await tester.tap(find.byTooltip('Close'));
          await tester.pumpAndSettle();
          expect(find.text(_message), findsNothing);
        },
      );
    }

    testWidgets('Undo can be reached with the keyboard after a while', (
      tester,
    ) async {
      await pump(tester);
      states.add(_swapped());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      final undo = find.widgetWithText(TextButton, 'Undo');
      expect(undo, findsOneWidget);
      Focus.of(tester.element(find.text('Undo'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      verify(harness.translate.undoSmartSwap).called(1);
    });

    testWidgets('Undo calls undoSmartSwap', (tester) async {
      await pump(tester);
      states.add(_swapped());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      verify(harness.translate.undoSmartSwap).called(1);
    });

    testWidgets('a newer notice replaces the shown one', (tester) async {
      await pump(tester);
      states.add(_swapped());
      await tester.pumpAndSettle();
      states.add(
        _swapped(
          const SmartSwapNotice(
            id: 2,
            previousTarget: english,
            newTarget: german,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Translating into German instead'), findsOneWidget);
      expect(find.text(_message), findsNothing);
      verify(harness.translate.consumeSmartSwapNotice).called(2);
    });

    testWidgets('shows a notice that was pending before it was built', (
      tester,
    ) async {
      harness.setState(_swapped());
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text(_message), findsOneWidget);
      verify(harness.translate.consumeSmartSwapNotice).called(1);
    });

    testWidgets('is part of the translate screen', (tester) async {
      await harness.pump(tester);
      expect(find.byType(SmartSwapListener), findsOneWidget);
      states.add(_swapped());
      await tester.pumpAndSettle();
      expect(find.text(_message), findsOneWidget);
    });
  });
}
