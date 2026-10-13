import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

const _ollama = AiProviderConfig(
  id: 'p2',
  name: 'Local Gemma',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'gemma3',
  enabled: false,
);

const _deepl = AiProviderConfig(
  id: 'mt1',
  name: 'Work translator',
  provider: LlmProvider.openAiCompatible,
  baseUrl: '',
  model: '',
  service: MtService.deepl,
);

const _libre = AiProviderConfig(
  id: 'mt2',
  name: 'Home translator',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'http://192.168.1.20:5000',
  model: 'ignored-model',
  service: MtService.libreTranslate,
);

void main() {
  setUpAll(registerFallbacks);

  group('ProvidersPage', () {
    late MockSettingsCubit settings;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(providers: [_claude, _ollama]),
      );
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      AppSettings? state,
      Size size = const Size(800, 1400),
      double textScale = 1,
    }) async {
      if (state != null) when(() => settings.state).thenReturn(state);
      tester.setScreenSize(size);
      await tester.pumpView(
        const ProvidersPage(),
        settings: settings,
        router: router,
        textScale: textScale,
      );
    }

    testWidgets('lists providers with model and privacy badge', (tester) async {
      await pump(tester);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('claude-opus-5-5'), findsOneWidget);
      expect(find.text('Local Gemma'), findsOneWidget);
      expect(find.text('gemma3'), findsOneWidget);
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.textContaining('secure storage'), findsOneWidget);
    });

    testWidgets('toggles a provider', (tester) async {
      await pump(tester);
      final switches = find.byType(Switch);
      expect(tester.widget<Switch>(switches.first).value, isTrue);
      expect(tester.widget<Switch>(switches.last).value, isFalse);
      await tester.tap(switches.first);
      verify(() => settings.setProviderEnabled('p1', enabled: false)).called(1);
      await tester.tap(switches.last);
      verify(() => settings.setProviderEnabled('p2', enabled: true)).called(1);
    });

    testWidgets('opens the editor for a provider', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Claude'));
      verify(
        () => router.push<Object?>(
          '/settings/providers/edit?id=p1',
          extra: any(named: 'extra'),
        ),
      ).called(1);
    });

    testWidgets('adds a provider from a preset', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a provider'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Ollama'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Local'),
        ),
        findsWidgets,
      );
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      verify(
        () => router.push<Object?>(
          '/settings/providers/edit?preset=ollama',
          extra: any(named: 'extra'),
        ),
      ).called(1);
    });

    group('machine translation', () {
      Finder sheetScrollable() => find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          )
          .first;

      testWidgets('the chooser lists the services in their own section', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.text('Add provider'));
        await tester.pumpAndSettle();
        expect(find.text('AI models'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('AI models')),
          isSemantics(isHeader: true),
        );
        await tester.scrollUntilVisible(
          find.text('LibreTranslate'),
          200,
          scrollable: sheetScrollable(),
        );
        final header = find.text('Machine translation');
        expect(header, findsOneWidget);
        expect(tester.getSemantics(header), isSemantics(isHeader: true));
        expect(find.textContaining('Classic translation services'), findsOne);
        // Below every AI preset.
        expect(
          tester.getTopLeft(header).dy,
          greaterThan(tester.getTopLeft(find.text('Ollama')).dy),
        );
        for (final preset in AiProviderPreset.mtServices) {
          expect(find.text(preset.name), findsOneWidget);
          expect(find.text(preset.description), findsOneWidget);
          expect(
            tester.getTopLeft(find.text(preset.name)).dy,
            greaterThan(tester.getTopLeft(header).dy),
          );
        }
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byIcon(Icons.translate),
          ),
          findsNWidgets(AiProviderPreset.mtServices.length),
        );
        await tester.tap(find.text('DeepL API'));
        await tester.pumpAndSettle();
        verify(
          () => router.push<Object?>(
            '/settings/providers/edit?preset=deepl',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('listed services show the service and host', (tester) async {
        await pump(
          tester,
          state: const AppSettings(providers: [_claude, _deepl, _libre]),
        );
        expect(find.text('Work translator'), findsOneWidget);
        expect(find.text('DeepL API'), findsOneWidget);
        expect(find.text('Home translator'), findsOneWidget);
        expect(find.text('LibreTranslate · 192.168.1.20'), findsOneWidget);
        expect(find.text('ignored-model'), findsNothing);
        expect(find.text('claude-opus-5-5'), findsOneWidget);
        // The self-hosted server is local, DeepL is in the cloud.
        expect(find.text('Local'), findsOneWidget);
        expect(find.text('Cloud'), findsNWidgets(2));
        expect(find.byIcon(Icons.translate), findsNWidgets(2));
      });

      testWidgets('a DeepL proxy shows its host', (tester) async {
        await pump(
          tester,
          state: AppSettings(
            providers: [_deepl.copyWith(baseUrl: 'deepl.example.com/v2')],
          ),
        );
        expect(find.text('DeepL API · deepl.example.com'), findsOneWidget);
      });
    });

    testWidgets('dismissing the preset sheet does nothing', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(
        () => router.push<Object?>(any(), extra: any(named: 'extra')),
      );
    });

    group('empty state', () {
      testWidgets('explains bring-your-own-key and local models', (
        tester,
      ) async {
        await pump(tester, state: const AppSettings());
        expect(find.text('Bring your own AI'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('Bring your own AI')),
          isSemantics(isHeader: true),
        );
        expect(find.textContaining('Ollama or LM Studio'), findsOneWidget);
        expect(find.textContaining('alternative translations'), findsOne);
        expect(find.byType(FloatingActionButton), findsNothing);
      });

      testWidgets('adds a provider', (tester) async {
        await pump(tester, state: const AppSettings());
        await tester.tap(find.text('Add provider'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Anthropic'));
        await tester.pumpAndSettle();
        verify(
          () => router.push<Object?>(
            '/settings/providers/edit?preset=anthropic',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('fits 320dp with large text', (tester) async {
        await pump(
          tester,
          state: const AppSettings(),
          size: const Size(320, 640),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('list fits 320dp with large text', (tester) async {
      await pump(tester, size: const Size(320, 900), textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });

  test('providerEditorLocation encodes parameters', () {
    expect(
      providerEditorLocation(providerId: 'a b'),
      '/settings/providers/edit?id=a+b',
    );
    expect(
      providerEditorLocation(presetId: 'openai'),
      '/settings/providers/edit?preset=openai',
    );
  });
}
