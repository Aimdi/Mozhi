import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _existing = AiProviderConfig(
  id: 'p1',
  name: 'My GPT',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://api.openai.com/v1',
  model: 'gpt-5-mini',
  apiKey: 'sk-secret',
  presetId: 'openai',
  effort: 'medium',
  temperature: 0.7,
  headers: {'X-Test': '1'},
  enabled: false,
  supportsVision: true,
);

void main() {
  setUpAll(registerFallbacks);

  group('ProviderEditorPage', () {
    late MockSettingsCubit settings;
    late MockTranslationRepository repository;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit(const AppSettings(providers: [_existing]));
      repository = MockTranslationRepository();
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      String? providerId,
      String? presetId,
      Size size = const Size(800, 2000),
      double textScale = 1,
    }) async {
      tester.setScreenSize(size);
      await tester.pumpView(
        ProviderEditorPage(providerId: providerId, presetId: presetId),
        settings: settings,
        repository: repository,
        router: router,
        textScale: textScale,
      );
    }

    Finder field(String label) => find.widgetWithText(TextFormField, label);

    String textOf(WidgetTester tester, String label) =>
        tester.widget<TextFormField>(field(label)).controller!.text;

    AiProviderConfig savedConfig() =>
        verify(() => settings.saveProvider(captureAny())).captured.single
            as AiProviderConfig;

    group('new provider', () {
      testWidgets('prefills from a preset', (tester) async {
        await pump(tester, presetId: 'anthropic');
        expect(find.text('Add AI provider'), findsOneWidget);
        expect(textOf(tester, 'Name'), 'Anthropic');
        expect(textOf(tester, 'Base URL'), 'https://api.anthropic.com/v1');
        expect(textOf(tester, 'Model'), 'claude-opus-5-5');
        expect(find.text('Low (fastest)'), findsOneWidget);
        // Anthropic has no temperature control.
        expect(find.text('Temperature'), findsNothing);
        expect(find.text('Get an API key'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'claude-sonnet-5-5'), findsOne);
        expect(find.byTooltip('Delete'), findsNothing);
      });

      testWidgets('validates required fields', (tester) async {
        await pump(tester, presetId: 'anthropic');
        await tester.enterText(field('Name'), '');
        await tester.enterText(field('Model'), '');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        // Name, API key (required for Anthropic) and model.
        expect(find.text('Required'), findsNWidgets(3));
        verifyNever(() => settings.saveProvider(any()));
      });

      testWidgets('validates the base URL', (tester) async {
        await pump(tester, presetId: 'custom');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.text('Required'), findsWidgets);
        await tester.enterText(field('Base URL'), 'not a url');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('Enter a valid http:// or https:// URL'),
          findsOneWidget,
        );
        verifyNever(() => settings.saveProvider(any()));
      });

      testWidgets('saves a new provider and closes', (tester) async {
        await pump(tester, presetId: 'anthropic');
        await tester.enterText(field('API key'), '  sk-ant  ');
        await tester.tap(find.widgetWithText(ChoiceChip, 'claude-haiku-5-5'));
        await tester.pump();
        await tester.tap(find.text('Supports images'));
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final config = savedConfig();
        expect(config.id, matches(RegExp(r'^p\d+$')));
        expect(config.name, 'Anthropic');
        expect(config.provider, LlmProvider.anthropic);
        expect(config.baseUrl, 'https://api.anthropic.com/v1');
        expect(config.model, 'claude-haiku-5-5');
        expect(config.apiKey, 'sk-ant');
        expect(config.presetId, 'anthropic');
        expect(config.effort, 'low');
        expect(config.temperature, isNull);
        expect(config.enabled, isTrue);
        expect(config.supportsVision, isTrue);
        verify(() => router.pop<Object?>()).called(1);
        expect(find.text('Provider saved'), findsOneWidget);
      });

      testWidgets('falls back to the providers list when it cannot pop', (
        tester,
      ) async {
        when(router.canPop).thenReturn(false);
        await pump(tester, presetId: 'ollama');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verify(() => settings.saveProvider(any())).called(1);
        verify(
          () => router.go('/settings/providers', extra: any(named: 'extra')),
        ).called(1);
      });

      testWidgets('blank editor defaults to OpenAI-compatible', (tester) async {
        await pump(tester);
        expect(find.text('OpenAI-compatible'), findsOneWidget);
        expect(textOf(tester, 'Base URL'), 'https://api.openai.com/v1');
        expect(find.text('API key (optional)'), findsOneWidget);
      });

      testWidgets('switching type updates the default base URL', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.text('OpenAI-compatible'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ollama (native API)').last);
        await tester.pumpAndSettle();
        expect(textOf(tester, 'Base URL'), 'http://localhost:11434');

        await tester.tap(find.text('Ollama (native API)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Anthropic').last);
        await tester.pumpAndSettle();
        expect(textOf(tester, 'Base URL'), 'https://api.anthropic.com/v1');
        expect(find.text('Temperature'), findsNothing);
        expect(find.text('API key'), findsOneWidget);
      });

      testWidgets('keeps a custom base URL when switching type', (
        tester,
      ) async {
        await pump(tester);
        await tester.enterText(field('Base URL'), 'https://llm.example.com/v1');
        await tester.tap(find.text('OpenAI-compatible'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Google Gemini').last);
        await tester.pumpAndSettle();
        expect(textOf(tester, 'Base URL'), 'https://llm.example.com/v1');
      });

      testWidgets('saves a custom temperature and effort', (tester) async {
        await pump(tester, presetId: 'ollama');
        expect(find.byType(Slider), findsNothing);
        await tester.tap(find.text('Temperature'));
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsOneWidget);
        expect(find.text('0.3'), findsOneWidget);

        await tester.tap(find.text('Default'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('High (slowest)').last);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final config = savedConfig();
        expect(config.temperature, 0.3);
        expect(config.effort, 'high');
        expect(config.apiKey, isNull);
      });

      testWidgets('reveals the API key', (tester) async {
        await pump(tester, presetId: 'openai');
        bool obscured() => tester
            .widget<TextField>(
              find.descendant(
                of: field('API key'),
                matching: find.byType(TextField),
              ),
            )
            .obscureText;
        expect(obscured(), isTrue);
        await tester.tap(find.byTooltip('Show API key'));
        await tester.pump();
        expect(obscured(), isFalse);
        expect(find.byTooltip('Hide API key'), findsOneWidget);
      });

      testWidgets('opens the API key page', (tester) async {
        final opened = <Uri>[];
        final original = LinkLauncher.launcher;
        LinkLauncher.launcher = (uri) async {
          opened.add(uri);
          return true;
        };
        addTearDown(() => LinkLauncher.launcher = original);
        await pump(tester, presetId: 'openai');
        await tester.tap(find.text('Get an API key'));
        await tester.pump();
        expect(opened, [Uri.parse('https://platform.openai.com/api-keys')]);
      });

      testWidgets('warns about plain http to remote hosts', (tester) async {
        await pump(tester, presetId: 'custom');
        expect(find.textContaining('Not encrypted'), findsNothing);
        await tester.enterText(field('Base URL'), 'http://llm.example.com/v1');
        await tester.pump();
        expect(find.textContaining('Not encrypted'), findsOneWidget);
        await tester.enterText(field('Base URL'), 'http://192.168.1.5:8080/v1');
        await tester.pump();
        expect(find.textContaining('Not encrypted'), findsNothing);
      });
    });

    group('existing provider', () {
      testWidgets('prefills all fields', (tester) async {
        await pump(tester, providerId: 'p1');
        expect(find.text('Edit AI provider'), findsOneWidget);
        expect(textOf(tester, 'Name'), 'My GPT');
        expect(textOf(tester, 'Model'), 'gpt-5-mini');
        expect(textOf(tester, 'API key'), 'sk-secret');
        expect(find.text('Medium'), findsOneWidget);
        expect(find.text('0.7'), findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
      });

      testWidgets('saves with the same id and keeps other fields', (
        tester,
      ) async {
        await pump(tester, providerId: 'p1');
        await tester.enterText(field('Name'), 'Work GPT');
        await tester.enterText(field('Base URL'), 'https://proxy.example.com/');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final config = savedConfig();
        expect(config.id, 'p1');
        expect(config.name, 'Work GPT');
        expect(config.baseUrl, 'https://proxy.example.com');
        expect(config.enabled, isFalse);
        expect(config.headers, {'X-Test': '1'});
        expect(config.temperature, 0.7);
        expect(config.presetId, 'openai');
      });

      testWidgets('deletes after confirmation', (tester) async {
        await pump(tester, providerId: 'p1');
        await tester.tap(find.byTooltip('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete My GPT?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        verify(() => settings.removeProvider('p1')).called(1);
        verify(() => router.pop<Object?>()).called(1);
        expect(find.text('Provider deleted'), findsOneWidget);
      });

      testWidgets('cancel keeps the provider', (tester) async {
        await pump(tester, providerId: 'p1');
        await tester.tap(find.byTooltip('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.removeProvider(any()));
      });

      testWidgets('shows a message for unknown ids', (tester) async {
        await pump(tester, providerId: 'missing');
        expect(find.text('This provider no longer exists.'), findsOneWidget);
      });
    });

    group('test connection', () {
      testWidgets('shows the French output', (tester) async {
        final completer = Completer<String>();
        when(() => repository.testProvider(any()))
            .thenAnswer((_) => completer.future);
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Test connection'));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        completer.complete('Bonjour');
        await tester.pumpAndSettle();
        expect(
          find.text('Connected. “Hello” in French: Bonjour'),
          findsOneWidget,
        );
        final config =
            verify(() => repository.testProvider(captureAny())).captured.single
                as AiProviderConfig;
        expect(config.apiKey, 'sk-secret');
        expect(config.model, 'gpt-5-mini');
      });

      testWidgets('shows the provider error', (tester) async {
        when(
          () => repository.testProvider(any()),
        ).thenThrow(const LlmApiException('Invalid API key', statusCode: 401));
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();
        expect(
          find.text('Connection failed: 401: Invalid API key'),
          findsOneWidget,
        );
      });

      testWidgets('validates before testing', (tester) async {
        await pump(tester, presetId: 'custom');
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();
        verifyNever(() => repository.testProvider(any()));
      });
    });

    group('browse models', () {
      testWidgets('picks a model from a searchable list', (tester) async {
        when(() => repository.listModels(any())).thenAnswer(
          (_) async => const [
            LlmModel(id: 'gpt-5'),
            LlmModel(id: 'gpt-5-nano', displayName: 'GPT-5 nano'),
          ],
        );
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Browse models'));
        await tester.pumpAndSettle();
        Finder inSheet(String text) => find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(text),
        );
        expect(inSheet('gpt-5'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, 'Search models'),
          'nano',
        );
        await tester.pumpAndSettle();
        expect(inSheet('gpt-5'), findsNothing);
        await tester.tap(find.text('GPT-5 nano'));
        await tester.pumpAndSettle();
        expect(textOf(tester, 'Model'), 'gpt-5-nano');
      });

      testWidgets('shows an error when listing fails', (tester) async {
        when(() => repository.listModels(any()))
            .thenThrow(const LlmApiException('Unauthorized', statusCode: 401));
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Browse models'));
        await tester.pumpAndSettle();
        expect(
          find.text("Couldn't load models: 401: Unauthorized"),
          findsOneWidget,
        );
      });

      testWidgets('reports an empty model list', (tester) async {
        when(() => repository.listModels(any()))
            .thenAnswer((_) async => const []);
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Browse models'));
        await tester.pumpAndSettle();
        expect(find.text('No models found'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
      });
    });

    testWidgets('fits 320dp with large text', (tester) async {
      await pump(
        tester,
        presetId: 'openai',
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.text('Test connection'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
