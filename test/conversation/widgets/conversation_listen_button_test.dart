import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../helpers.dart';

const _slowly = CustomSemanticsAction(label: 'Listen slowly');
const _key = Key('listen');

Finder _mergedButton() =>
    find.ancestor(of: find.byKey(_key), matching: find.byType(MergeSemantics));

void main() {
  group(ConversationListenButton, () {
    late int toggles;
    late int slows;

    setUp(() {
      toggles = 0;
      slows = 0;
    });

    Future<void> pump(
      WidgetTester tester, {
      bool enabled = true,
      bool playing = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: ConversationListenButton(
                buttonKey: _key,
                playing: playing,
                color: Colors.teal,
                onListen: enabled ? () => toggles++ : null,
                onListenSlowly: enabled ? () => slows++ : null,
              ),
            ),
          ),
        ),
      );
    }

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

    testWidgets('a tap listens at normal speed', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(_key));
      expect((toggles, slows), (1, 0));
      expect(tester.widget<IconButton>(find.byKey(_key)).color, Colors.teal);
    });

    testWidgets('the tooltip mentions the long press', (tester) async {
      await pump(tester);
      expect(findTooltipMessage(listenTooltip('Listen')), findsOneWidget);
      await pump(tester, playing: true);
      expect(findTooltipMessage(listenTooltip('Stop')), findsOneWidget);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    });

    testWidgets('a long press listens slowly and shows the tooltip', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text(listenTooltip('Listen')), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect((toggles, slows), (0, 1));
    });

    testWidgets('semantics: label, tap targets and the slow action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
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
      expect(node.tooltip, isEmpty);
      tester.semantics.customAction(
        find.semantics.byAction(SemanticsAction.customAction),
        _slowly,
      );
      await tester.pump();
      expect((toggles, slows), (0, 1));
      handle.dispose();
    });

    testWidgets('Shift+Enter/Space/numpad Enter listen slowly, held once', (
      tester,
    ) async {
      await pump(tester);
      await focusButton(tester);
      await pressShift(tester, LogicalKeyboardKey.enter);
      await pressShift(tester, LogicalKeyboardKey.space);
      await pressShift(tester, LogicalKeyboardKey.numpadEnter);
      expect(slows, 3);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect((toggles, slows), (0, 4));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect((toggles, slows), (1, 4));
    });

    testWidgets('a right click offers "Listen slowly"', (tester) async {
      await pump(tester);
      await tester.tap(
        find.byKey(_key),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('conversation_listen_slowly_menu_item')),
      );
      await tester.pumpAndSettle();
      expect((toggles, slows), (0, 1));
      expect(find.text('Listen slowly'), findsNothing);
    });

    testWidgets('offers no slow replay while disabled', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, enabled: false);
      expect(findTooltipMessage('Listen'), findsOneWidget);
      expect(find.byType(MenuAnchor), findsNothing);
      expect(
        tester.getSemantics(find.byKey(_key)),
        isSemantics(
          label: 'Listen',
          isEnabled: false,
          hasLongPressAction: false,
        ),
      );
      await tester.longPress(find.byKey(_key));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect((toggles, slows), (0, 0));
      handle.dispose();
    });
  });
}
