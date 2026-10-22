import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/quality_modes_page.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'mozhi.example.com',
  mozhiEngine: 'google',
);
const _claude = TranslationEngine(
  id: 'ai:p1',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
  providerId: 'p1',
);
const _deepl = TranslationEngine(
  id: 'mt:p3',
  kind: EngineKind.mt,
  name: 'DeepL API',
  providerId: 'p3',
);
const _offline = TranslationEngine(
  id: TranslationEngine.offlineId,
  kind: EngineKind.offline,
  name: 'Offline (on-device)',
  isLocal: true,
);

const _qwen = AiProviderConfig(
  id: 'p2',
  name: 'Local Qwen',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'qwen3',
);

void main() {
  setUpAll(registerFallbacks);

  group(QualityModesPage, () {
    late MockSettingsCubit settings;
    late MockTranslationRepository repository;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit();
      repository = MockTranslationRepository();
      router = createRouter();
      when(() => repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => [_google, _claude, _deepl, _offline]);
    });

    Future<void> pump(
      WidgetTester tester, {
      AppSettings? state,
      Size size = const Size(400, 1200),
      double textScale = 1,
      ThemeData? theme,
      bool settle = true,
    }) async {
      if (state != null) when(() => settings.state).thenReturn(state);
      tester.setScreenSize(size);
      await tester.pumpView(
        const QualityModesPage(),
        settings: settings,
        repository: repository,
        router: router,
        textScale: textScale,
        theme: theme,
      );
      if (settle) await tester.pumpAndSettle();
    }

    Finder tile(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(ListTile));

    testWidgets('explains both modes', (tester) async {
      await pump(tester);
      expect(find.text('Quality modes'), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Best'), findsOneWidget);
      expect(
        find.textContaining('Google or DeepL through a Mozhi instance'),
        findsOneWidget,
      );
      expect(
        find.textContaining('such as your strongest AI model'),
        findsOneWidget,
      );
      expect(find.text('Not set'), findsNWidgets(2));
      expect(find.text('Tap to choose an engine'), findsNWidgets(2));
      verify(() => repository.getEngines()).called(1);
    });

    testWidgets('shows the chosen engines', (tester) async {
      await pump(
        tester,
        state: const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:p1',
        ),
      );
      expect(find.text('Google'), findsOneWidget);
      expect(find.text('mozhi.example.com'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('claude-opus-5-5'), findsOneWidget);
      expect(find.text('Not set'), findsNothing);
    });

    testWidgets('shows a chosen engine without a subtitle', (tester) async {
      await pump(tester, state: const AppSettings(fastEngineId: 'mt:p3'));
      expect(find.text('DeepL API'), findsOneWidget);
      final listTile = tester.widget<ListTile>(tile('DeepL API'));
      expect(listTile.subtitle, isNull);
    });

    testWidgets('a mode without an engine uses the usual one', (tester) async {
      await pump(tester, state: const AppSettings(bestEngineId: 'ai:p1'));
      expect(find.text('Not set'), findsOneWidget);
      expect(
        find.text('Uses your usual engine. Tap to choose another one.'),
        findsOneWidget,
      );
      expect(find.text('Tap to choose an engine'), findsNothing);
    });

    testWidgets('names unavailable engines', (tester) async {
      await pump(
        tester,
        state: const AppSettings(
          providers: [_qwen],
          fastEngineId: 'mozhi:deepl',
          bestEngineId: 'ai:p2',
        ),
      );
      expect(find.text('deepl'), findsOneWidget);
      expect(find.text('Local Qwen'), findsOneWidget);
      expect(find.text('Not available right now'), findsNWidgets(2));
    });

    testWidgets('names unavailable engines of removed providers by id', (
      tester,
    ) async {
      await pump(
        tester,
        state: const AppSettings(fastEngineId: 'mt:gone', bestEngineId: 'odd'),
      );
      expect(find.text('gone'), findsOneWidget);
      expect(find.text('odd'), findsOneWidget);
    });

    testWidgets('shows progress while loading and disables the pickers', (
      tester,
    ) async {
      final engines = Completer<List<TranslationEngine>>();
      when(() => repository.getEngines()).thenAnswer((_) => engines.future);
      await pump(
        tester,
        state: const AppSettings(bestEngineId: 'ai:p1'),
        settle: false,
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Loading engines'), findsOneWidget);
      // The id is shown while the engines load, without a status.
      expect(find.text('p1'), findsOneWidget);
      expect(find.text('Not available right now'), findsNothing);
      expect(tester.widget<ListTile>(tile('p1')).enabled, isFalse);

      engines.complete([_claude]);
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Claude'), findsOneWidget);
    });

    testWidgets('shows load errors and retries with a refresh', (tester) async {
      when(() => repository.getEngines()).thenThrow(StateError('offline'));
      await pump(tester);
      expect(
        find.text(
          "Couldn't load the engines. Check your Mozhi instances and "
          'AI providers.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<ListTile>(tile('Not set').first).enabled, isFalse);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      verify(() => repository.getEngines(refresh: true)).called(1);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('says when there are no engines', (tester) async {
      when(() => repository.getEngines()).thenAnswer((_) async => []);
      await pump(tester);
      expect(
        find.text(
          'No engines available. Add a Mozhi instance or an AI provider '
          'first.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Not set').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    group('picker', () {
      const chosen = AppSettings(
        fastEngineId: 'mozhi:google',
        bestEngineId: 'ai:p1',
      );

      testWidgets('lists every engine and none', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Not set').first);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Fast engine'), findsOneWidget);
        expect(find.text('None'), findsOneWidget);
        for (final engine in [_google, _claude, _deepl, _offline]) {
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(engine.name),
            ),
            findsOneWidget,
          );
        }
        for (final icon in [
          Icons.dns_outlined,
          Icons.auto_awesome_outlined,
          Icons.translate,
          Icons.download_for_offline_outlined,
        ]) {
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byIcon(icon),
            ),
            findsOneWidget,
          );
        }
      });

      testWidgets('picks the fast engine and keeps the best one', (
        tester,
      ) async {
        await pump(tester, state: const AppSettings(bestEngineId: 'ai:p1'));
        await tester.tap(find.text('Not set'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Google'));
        await tester.pumpAndSettle();
        // Choosing only moves the selection; Save confirms it.
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(
          () => settings.setQualityEngines(fast: 'mozhi:google', best: 'ai:p1'),
        ).called(1);
      });

      testWidgets('picks the best engine and keeps the fast one', (
        tester,
      ) async {
        await pump(tester, state: chosen);
        await tester.tap(find.text('Claude'));
        await tester.pumpAndSettle();
        expect(find.text('Best engine'), findsOneWidget);
        await tester.tap(find.text('DeepL API'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verify(
          () => settings.setQualityEngines(fast: 'mozhi:google', best: 'mt:p3'),
        ).called(1);
      });

      testWidgets('picks none', (tester) async {
        await pump(tester, state: chosen);
        await tester.tap(find.text('Google'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('None'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verify(() => settings.setQualityEngines(best: 'ai:p1')).called(1);
      });

      testWidgets('picking the current engine changes nothing', (tester) async {
        await pump(tester, state: chosen);
        await tester.tap(find.text('Google'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Google'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(
          () => settings.setQualityEngines(
            fast: any(named: 'fast'),
            best: any(named: 'best'),
          ),
        );
      });

      testWidgets('arrow keys move the choice without closing the dialog', (
        tester,
      ) async {
        await pump(tester, state: const AppSettings(bestEngineId: 'ai:p1'));
        await tester.tap(find.text('Not set'));
        await tester.pumpAndSettle();
        // Tab reaches the selected radio ("None") of the group.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(
          () => settings.setQualityEngines(
            fast: any(named: 'fast'),
            best: any(named: 'best'),
          ),
        );

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setQualityEngines(fast: 'mt:p3', best: 'ai:p1'))
            .called(1);
      });

      testWidgets('cancel changes nothing', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Not set').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(
          () => settings.setQualityEngines(
            fast: any(named: 'fast'),
            best: any(named: 'best'),
          ),
        );
      });
    });

    group('without AI engines', () {
      setUp(() {
        when(() => repository.getEngines()).thenAnswer((_) async => [_google]);
      });

      testWidgets('suggests adding an AI provider for Best', (tester) async {
        await pump(tester);
        expect(
          find.text('Add an AI provider to use your strongest model as Best.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Add provider'));
        verify(
          () => router.push<Object?>(
            '/settings/providers',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });
    });

    testWidgets('does not suggest a provider when an AI engine exists', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Add provider'), findsNothing);
    });

    testWidgets('fits 320dp with large text', (tester) async {
      await pump(tester, size: const Size(320, 2000), textScale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in dark mode', (tester) async {
      await pump(
        tester,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      expect(find.text('Fast'), findsOneWidget);
    });
  });
}
