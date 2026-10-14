import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';

import '../helpers/helpers.dart';

const _slowly = CustomSemanticsAction(label: 'Listen slowly');

/// The listen button's (merged) semantics node.
Finder _mergedButton() => find.ancestor(
  of: find.byType(IconButton),
  matching: find.byType(MergeSemantics),
);

FinderBase<SemanticsNode> _slowAction() =>
    find.semantics.byAction(SemanticsAction.customAction);

void main() {
  setUpAll(registerTranslateFallbacks);

  group(ListenButton, () {
    late TranslateHarness harness;

    setUp(() => harness = TranslateHarness());

    Future<void> pump(
      WidgetTester tester, {
      String text = 'Bonjour',
      String? languageCode = 'fr',
      String? tooltip,
      String? stopTooltip,
    }) => harness.pump(
      tester,
      child: ListenButton(
        id: 'target',
        text: text,
        languageCode: languageCode,
        tooltip: tooltip,
        stopTooltip: stopTooltip,
      ),
    );

    void verifySlow() => verify(
      () => harness.speech.speak(
        id: 'target',
        text: 'Bonjour',
        languageCode: 'fr',
        slow: true,
      ),
    ).called(1);

    void verifyNoToggle() => verifyNever(
      () => harness.speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    );

    void failSpeak() => when(
      () => harness.speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        slow: any(named: 'slow'),
      ),
    ).thenThrow(Exception('offline'));

    Future<void> focusButton(WidgetTester tester) async {
      Focus.of(tester.element(find.byIcon(Icons.volume_up_outlined)))
          .requestFocus();
      await tester.pump();
    }

    Future<void> pressShift(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    testWidgets('a tap toggles reading aloud at normal speed', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(IconButton));
      verify(
        () => harness.speech.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
        ),
      ).called(1);
      verifyNever(
        () => harness.speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
        ),
      );
    });

    testWidgets('the tooltip mentions the long press', (tester) async {
      await pump(tester, tooltip: 'Listen to German');
      expect(findListenTooltip('Listen to German'), findsOneWidget);
    });

    testWidgets('a touch long press shows the tooltip while it reads slowly', (
      tester,
    ) async {
      await pump(tester, tooltip: 'Listen to German');
      final shown = find.text(listenTooltip('Listen to German'));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(IconButton)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(shown, findsOneWidget);
      verify(
        () => harness.speech.speak(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          slow: true,
        ),
      ).called(1);

      await gesture.up();
      await tester.pump();
      // Still readable after lifting the finger, then it goes away.
      expect(shown, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(shown, findsNothing);
      verifyNoToggle();
    });

    testWidgets('a mouse hover shows the tooltip without reading', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(IconButton)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(listenTooltip('Listen')), findsOneWidget);
      verifyNever(
        () => harness.speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
        ),
      );
    });

    testWidgets('a long press reads the text slowly', (tester) async {
      await pump(tester);
      await tester.longPress(find.byType(IconButton));
      await tester.pumpAndSettle();
      verifySlow();
      verifyNoToggle();
    });

    testWidgets('a long press while playing starts over slowly', (
      tester,
    ) async {
      when(() => harness.speech.current).thenReturn('target');
      await pump(tester, stopTooltip: 'Stop reading');
      expect(findListenTooltip('Stop reading'), findsOneWidget);
      await tester.longPress(find.byType(IconButton));
      await tester.pumpAndSettle();
      verifySlow();
      verifyNoToggle();
    });

    testWidgets('a slow read that fails shows the listen error', (
      tester,
    ) async {
      failSpeak();
      await pump(tester);
      await tester.longPress(find.byType(IconButton));
      await tester.pump();
      expect(find.text("Couldn't play audio."), findsOneWidget);
    });

    group('semantics', () {
      testWidgets('meet the tap target guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });

      testWidgets('label the button and offer a "Listen slowly" action', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        final node = tester.getSemantics(_mergedButton());
        expect(
          node,
          isSemantics(
            label: 'Listen',
            isButton: true,
            hasTapAction: true,
            hasLongPressAction: true,
            customActions: const [_slowly],
            onLongPressHint: 'Listen slowly',
          ),
        );
        // The tooltip line about the long press is not read out.
        expect(node.tooltip, isEmpty);

        tester.semantics.customAction(_slowAction(), _slowly);
        await tester.pump();
        verifySlow();
        verifyNoToggle();
        handle.dispose();
      });

      testWidgets('label the stop button while playing', (tester) async {
        final handle = tester.ensureSemantics();
        when(() => harness.speech.current).thenReturn('target');
        await pump(tester);
        expect(
          tester.getSemantics(_mergedButton()),
          isSemantics(
            label: 'Stop',
            customActions: const [_slowly],
            onLongPressHint: 'Listen slowly',
          ),
        );
        handle.dispose();
      });

      testWidgets('the slow action reports failures', (tester) async {
        final handle = tester.ensureSemantics();
        failSpeak();
        await pump(tester);
        tester.semantics.customAction(_slowAction(), _slowly);
        await tester.pump();
        expect(find.text("Couldn't play audio."), findsOneWidget);
        handle.dispose();
      });
    });

    group('keyboard', () {
      testWidgets('Shift+Enter on the focused button reads slowly', (
        tester,
      ) async {
        await pump(tester);
        await focusButton(tester);
        await pressShift(tester, LogicalKeyboardKey.enter);
        verifySlow();
        verifyNoToggle();
      });

      testWidgets('Shift+Space and Shift+numpad Enter read slowly too', (
        tester,
      ) async {
        await pump(tester);
        await focusButton(tester);
        await pressShift(tester, LogicalKeyboardKey.space);
        await pressShift(tester, LogicalKeyboardKey.numpadEnter);
        verify(
          () => harness.speech.speak(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
            slow: true,
          ),
        ).called(2);
      });

      testWidgets('holding Shift+Enter reads slowly once', (tester) async {
        await pump(tester);
        await focusButton(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        verify(
          () => harness.speech.speak(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
            slow: true,
          ),
        ).called(2);
        verifyNoToggle();
      });

      testWidgets('Enter alone toggles at normal speed', (tester) async {
        await pump(tester);
        await focusButton(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        verify(
          () => harness.speech.toggle(
            id: 'target',
            text: 'Bonjour',
            languageCode: 'fr',
          ),
        ).called(1);
      });
    });

    group('context menu', () {
      testWidgets('a right click offers "Listen slowly"', (tester) async {
        await pump(tester);
        await tester.tap(
          find.byType(IconButton),
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        verifyNoToggle();
        await tester.tap(find.byKey(const Key('listen_slowly_menu_item')));
        await tester.pumpAndSettle();
        verifySlow();
        expect(find.text('Listen slowly'), findsNothing);
      });

      testWidgets('is read out apart from the button', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        await tester.tap(
          find.byType(IconButton),
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(_mergedButton()),
          isSemantics(label: 'Listen', isButton: true),
        );
        final item = find.semantics.byLabel('Listen slowly');
        expect(item, findsOne);
        tester.semantics.tap(item);
        await tester.pumpAndSettle();
        verifySlow();
        handle.dispose();
      });
    });

    group('while disabled', () {
      for (final (name, text, code) in [
        ('without text', '  ', 'fr'),
        ('without a language', 'Bonjour', null),
      ]) {
        testWidgets('offers no slow replay $name', (tester) async {
          final handle = tester.ensureSemantics();
          await pump(tester, text: text, languageCode: code);
          expect(findTooltipMessage('Listen'), findsOneWidget);
          final button = tester.widget<IconButton>(find.byType(IconButton));
          expect(button.onPressed, isNull);
          expect(button.onLongPress, isNull);
          expect(find.byType(MenuAnchor), findsNothing);
          expect(
            tester.getSemantics(find.byType(IconButton)),
            isSemantics(
              label: 'Listen',
              isEnabled: false,
              hasLongPressAction: false,
            ),
          );
          expect(
            tester
                .getSemantics(find.byType(IconButton))
                .getSemanticsData()
                .customSemanticsActionIds,
            anyOf(isNull, isEmpty),
          );
          // A long press still shows the label.
          final gesture = await tester.startGesture(
            tester.getCenter(find.byType(IconButton)),
          );
          await tester.pump(const Duration(milliseconds: 700));
          expect(find.text('Listen'), findsOneWidget);
          await gesture.up();
          await tester.pumpAndSettle();
          verifyNever(
            () => harness.speech.speak(
              id: any(named: 'id'),
              text: any(named: 'text'),
              languageCode: any(named: 'languageCode'),
              slow: any(named: 'slow'),
            ),
          );
          handle.dispose();
        });
      }
    });
  });
}
