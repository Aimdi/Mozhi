import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/live/live_engine_picker.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

const _google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'via mozhi.example.org',
  mozhiEngine: 'google',
);
const _gemma = TranslationEngine(
  id: 'ai:gemma',
  kind: EngineKind.ai,
  name: 'Gemma',
  providerId: 'gemma',
  isLocal: true,
  onDevice: true,
);

void main() {
  late _MockSettingsCubit settings;
  late _MockTranslateCubit translate;

  setUp(() {
    settings = _MockSettingsCubit();
    translate = _MockTranslateCubit();
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => translate.state).thenReturn(
      TranslateState(engines: [_google, TranslationEngine.offline(), _gemma]),
    );
  });

  Future<void> open(WidgetTester tester, {bool withTranslator = true}) async {
    final button = Builder(
      builder: (context) => TextButton(
        onPressed: () => unawaited(showLiveEnginePicker(context)),
        child: const Text('open'),
      ),
    );
    await tester.pumpApp(
      BlocProvider<SettingsCubit>.value(
        value: settings,
        child: withTranslator
            ? BlocProvider<TranslateCubit>.value(
                value: translate,
                child: Scaffold(body: button),
              )
            : Scaffold(body: button),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('liveEngineChoices', () {
    test('the offline engine first, then on-device AI, then the others', () {
      expect(
        liveEngineChoices([_google, TranslationEngine.offline(), _gemma])
            .map((engine) => engine.id),
        [TranslationEngine.offlineId, 'ai:gemma', 'mozhi:google'],
      );
    });

    test('offers the offline engine also when it is not listed', () {
      expect(liveEngineChoices([_google, _google]).map((engine) => engine.id), [
        TranslationEngine.offlineId,
        'mozhi:google',
      ]);
    });
  });

  group('showLiveEnginePicker', () {
    testWidgets('lists the engines, the offline one chosen by default', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Translate live with'), findsOneWidget);
      final offline = tester.widget<ListTile>(
        find.byKey(const Key('live_engine_offline:mlkit')),
      );
      expect(offline.selected, isTrue);
      expect(find.text('On this device · Recommended'), findsOneWidget);
      expect(find.text('On this device'), findsOneWidget);
      expect(
        find.text('Sends the text off this device · via mozhi.example.org'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('live_engine_ai:gemma')))
            .selected,
        isFalse,
      );
    });

    testWidgets('a network engine is stored only after the OK', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('live_engine_mozhi:google')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('live_engine_confirm')), findsOneWidget);
      expect(find.text('Translate live with Google?'), findsOneWidget);
      expect(
        find.textContaining('Google will get the text of everything'),
        findsOneWidget,
      );
      verifyNever(() => settings.setLiveEngine(any()));

      await tester.tap(find.byKey(const Key('live_engine_confirm_ok')));
      await tester.pumpAndSettle();
      verify(() => settings.setLiveEngine('mozhi:google')).called(1);
    });

    testWidgets('cancelling the question keeps the engine', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('live_engine_mozhi:google')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_engine_confirm_cancel')));
      await tester.pumpAndSettle();

      verifyNever(() => settings.setLiveEngine(any()));
    });

    testWidgets('dismissing the sheet keeps the engine', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('live_engine_picker')), findsNothing);
      verifyNever(() => settings.setLiveEngine(any()));
    });

    testWidgets('an on-device engine needs no question', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('live_engine_ai:gemma')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('live_engine_confirm')), findsNothing);
      verify(() => settings.setLiveEngine('ai:gemma')).called(1);
    });

    testWidgets('back to the offline engine stores the default', (
      tester,
    ) async {
      when(() => settings.state)
          .thenReturn(const AppSettings(liveEngineId: 'mozhi:google'));
      await open(tester);
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('live_engine_mozhi:google')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('live_engine_offline:mlkit')));
      await tester.pumpAndSettle();

      verify(() => settings.setLiveEngine(null)).called(1);
    });

    testWidgets('choosing the engine in use changes nothing', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('live_engine_offline:mlkit')));
      await tester.pumpAndSettle();
      verifyNever(() => settings.setLiveEngine(any()));
    });

    testWidgets('without a translator only the offline engine shows', (
      tester,
    ) async {
      await open(tester, withTranslator: false);
      expect(find.byType(ListTile), findsOneWidget);
      expect(
        find.byKey(const Key('live_engine_offline:mlkit')),
        findsOneWidget,
      );
    });
  });
}
