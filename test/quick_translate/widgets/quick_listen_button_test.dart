import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _slowly = CustomSemanticsAction(label: 'Listen slowly');
const String _id = QuickListenButton.defaultId;

Finder _button() => find.byKey(const Key('quick_translate_listen'));

/// The listen button's (merged) semantics node.
Finder _mergedButton() =>
    find.ancestor(of: _button(), matching: find.byType(MergeSemantics));

void main() {
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late int errors;
  VoidCallback? lastListenOnline;
  VoidCallback? lastRetry;

  setUp(() {
    speech = MockSpeechService();
    speaking = StreamController<String?>.broadcast();
    errors = 0;
    lastListenOnline = null;
    lastRetry = null;
    when(() => speech.speaking).thenAnswer((_) => speaking.stream);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        slow: any(named: 'slow'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() => speaking.close());

  Future<void> pump(
    WidgetTester tester, {
    String text = 'Bonjour',
    String? languageCode = 'fr',
    SettingsCubit? settings,
  }) {
    final Widget button = Center(
      child: QuickListenButton(
        speech: speech,
        text: text,
        languageCode: languageCode,
        onError: (_, listenOnline, retry) {
          errors++;
          lastListenOnline = listenOnline;
          lastRetry = retry;
        },
      ),
    );
    return tester.pumpQuick(
      settings == null
          ? button
          : BlocProvider<SettingsCubit>.value(value: settings, child: button),
    );
  }

  void verifySlow([int times = 1]) => verify(
    () =>
        speech.speak(id: _id, text: 'Bonjour', languageCode: 'fr', slow: true),
  ).called(times);

  void verifyNoSlow() => verifyNever(
    () => speech.speak(
      id: any(named: 'id'),
      text: any(named: 'text'),
      languageCode: any(named: 'languageCode'),
      slow: any(named: 'slow'),
    ),
  );

  void verifyNoToggle() => verifyNever(
    () => speech.toggle(
      id: any(named: 'id'),
      text: any(named: 'text'),
      languageCode: any(named: 'languageCode'),
    ),
  );

  void failSpeak() => when(
    () => speech.speak(
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

  group(QuickListenButton, () {
    testWidgets('a tap toggles at normal speed', (tester) async {
      await pump(tester);
      await tester.tap(_button());
      await tester.pump();
      verify(() => speech.toggle(id: _id, text: 'Bonjour', languageCode: 'fr'))
          .called(1);
      verifyNoSlow();
    });

    testWidgets('the tooltip mentions the long press', (tester) async {
      await pump(tester);
      expect(findTooltipMessage(listenTooltip('Listen')), findsOneWidget);
      speaking.add(_id);
      await tester.pump();
      await tester.pump();
      expect(findTooltipMessage(listenTooltip('Stop')), findsOneWidget);
    });

    testWidgets('a long press reads slowly and shows the tooltip', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(_button()));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text(listenTooltip('Listen')), findsOneWidget);
      verifySlow();
      await gesture.up();
      await tester.pumpAndSettle(const Duration(seconds: 3));
      verifyNoToggle();
    });

    for (final enabled in [true, false]) {
      testWidgets('a long press vibrates only with haptic feedback on '
          '(${enabled ? 'on' : 'off'})', (tester) async {
        final haptics = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method.startsWith('HapticFeedback')) {
              haptics.add(call.method);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pump(
          tester,
          settings: mockSettings(AppSettings(hapticFeedback: enabled)),
        );

        await tester.longPress(_button());
        await tester.pumpAndSettle(const Duration(seconds: 3));

        verifySlow();
        expect(haptics, enabled ? ['HapticFeedback.vibrate'] : isEmpty);
      });
    }

    testWidgets('a long press while playing starts over slowly', (
      tester,
    ) async {
      await pump(tester);
      speaking.add(_id);
      await tester.pump();
      await tester.pump();
      await tester.longPress(_button());
      await tester.pumpAndSettle();
      verifySlow();
      verifyNoToggle();
    });

    testWidgets('offers to listen through Mozhi with consent, once', (
      tester,
    ) async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:google',
        source: 'fr',
        target: 'fr',
      );
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenThrow(const SpeechUnavailableException('fr', cause: consent));
      await pump(tester);
      await tester.tap(_button());
      await tester.pumpAndSettle();
      expect(errors, 1);
      expect(lastListenOnline, isNotNull);

      lastListenOnline!();
      await tester.pumpAndSettle();
      verify(
        () => speech.toggle(
          id: any(named: 'id'),
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: consent,
        ),
      ).called(1);
      // Refused again with consent: nothing more is offered.
      expect(errors, 2);
      expect(lastListenOnline, isNull);
    });

    testWidgets('a failing slow read reports the error', (tester) async {
      failSpeak();
      await pump(tester);
      await tester.longPress(_button());
      await tester.pumpAndSettle();
      expect(errors, 1);
    });

    group('semantics', () {
      testWidgets('meet the tap target guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });

      testWidgets('offer a "Listen slowly" action', (tester) async {
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
        expect(node.tooltip, isEmpty);
        tester.semantics.customAction(
          find.semantics.byAction(SemanticsAction.customAction),
          _slowly,
        );
        await tester.pump();
        verifySlow();
        verifyNoToggle();
        handle.dispose();
      });

      testWidgets('the slow action reports failures', (tester) async {
        final handle = tester.ensureSemantics();
        failSpeak();
        await pump(tester);
        tester.semantics.customAction(
          find.semantics.byAction(SemanticsAction.customAction),
          _slowly,
        );
        await tester.pump();
        expect(errors, 1);
        handle.dispose();
      });
    });

    group('keyboard', () {
      testWidgets('Shift+Enter, Shift+Space and Shift+numpad Enter read '
          'slowly', (tester) async {
        await pump(tester);
        await focusButton(tester);
        await pressShift(tester, LogicalKeyboardKey.enter);
        await pressShift(tester, LogicalKeyboardKey.space);
        await pressShift(tester, LogicalKeyboardKey.numpadEnter);
        verifySlow(3);
        verifyNoToggle();
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
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        verifySlow();
        verifyNoToggle();
      });

      testWidgets('Enter alone toggles at normal speed', (tester) async {
        await pump(tester);
        await focusButton(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        verify(
          () => speech.toggle(id: _id, text: 'Bonjour', languageCode: 'fr'),
        ).called(1);
        verifyNoSlow();
      });
    });

    testWidgets('a right click offers "Listen slowly"', (tester) async {
      await pump(tester);
      await tester.tap(
        _button(),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      verifyNoToggle();
      await tester.tap(
        find.byKey(const Key('quick_translate_listen_slowly_menu_item')),
      );
      await tester.pumpAndSettle();
      verifySlow();
      expect(find.text('Listen slowly'), findsNothing);
    });

    for (final (name, text, code) in [
      ('without text', '  ', 'fr'),
      ('without a language', 'Bonjour', null),
    ]) {
      testWidgets('offers no slow replay $name', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, text: text, languageCode: code);
        expect(findTooltipMessage('Listen'), findsOneWidget);
        expect(find.byType(MenuAnchor), findsNothing);
        expect(
          tester.getSemantics(_button()),
          isSemantics(
            label: 'Listen',
            isEnabled: false,
            hasLongPressAction: false,
          ),
        );
        await tester.longPress(_button());
        await tester.pumpAndSettle(const Duration(seconds: 3));
        verifyNoSlow();
        handle.dispose();
      });
    }
  });

  group('retry', () {
    final serversFailed = SpeechUnavailableException(
      'fr',
      cause: AllInstancesFailedException(
        'boom',
        engine: TranslationEngine.mozhi('google', 'Google'),
        instances: const [MozhiInstance(url: 'https://mozhi.example')],
      ),
    );

    testWidgets('reads aloud again after a failure', (tester) async {
      var calls = 0;
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenAnswer((_) async {
        if (calls++ == 0) throw serversFailed;
      });
      await pump(tester);
      await tester.tap(_button());
      await tester.pump();
      expect(errors, 1);
      expect(lastRetry, isNotNull);

      lastRetry!();
      await tester.pump();
      verify(() => speech.toggle(id: _id, text: 'Bonjour', languageCode: 'fr'))
          .called(2);
      expect(errors, 1);
    });

    testWidgets('a retry does not stop a reading that started', (tester) async {
      var calls = 0;
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenAnswer((_) async {
        if (calls++ == 0) throw serversFailed;
      });
      await pump(tester);
      await tester.tap(_button());
      await tester.pump();
      speaking.add(_id);
      await tester.pump();
      await tester.pump();

      lastRetry!();
      await tester.pump();
      verify(() => speech.toggle(id: _id, text: 'Bonjour', languageCode: 'fr'))
          .called(1);
    });

    testWidgets('retries a slow reading slowly', (tester) async {
      failSpeak();
      await pump(tester);
      await tester.longPress(_button());
      await tester.pump();
      verifySlow();
      expect(errors, 1);

      lastRetry!();
      await tester.pump();
      verifySlow();
      expect(errors, 2);
    });
  });
}
