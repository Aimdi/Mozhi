import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/usage/usage.dart';
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

const _deepl = AiProviderConfig(
  id: 'mt1',
  name: 'Work DeepL',
  provider: LlmProvider.openAiCompatible,
  baseUrl: '',
  model: '',
  apiKey: 'dl-key:fx',
  presetId: 'deepl',
  service: MtService.deepl,
);

const _libre = AiProviderConfig(
  id: 'mt2',
  name: 'Home Libre',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'http://192.168.1.20:5000',
  model: '',
  service: MtService.libreTranslate,
);

const _gemma = AiProviderConfig(
  id: 'g1',
  name: 'Gemma',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'gemma3',
  presetId: 'ollama',
  promptProfile: PromptProfile.translateGemma,
);

void main() {
  setUpAll(registerFallbacks);

  group('ProviderEditorPage', () {
    late MockSettingsCubit settings;
    late MockTranslationRepository repository;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(providers: [_existing, _deepl, _libre, _gemma]),
      );
      repository = MockTranslationRepository();
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      String? providerId,
      String? presetId,
      Size size = const Size(800, 2000),
      double textScale = 1,
      UsageTracker? usageTracker,
    }) async {
      tester.setScreenSize(size);
      final page = ProviderEditorPage(
        providerId: providerId,
        presetId: presetId,
      );
      await tester.pumpView(
        usageTracker == null
            ? page
            : RepositoryProvider<UsageTracker>.value(
                value: usageTracker,
                child: page,
              ),
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

      testWidgets('focuses the first invalid field and announces it', (
        tester,
      ) async {
        bool focused(String label) => tester
            .widget<EditableText>(
              find.descendant(
                of: field(label),
                matching: find.byType(EditableText),
              ),
            )
            .focusNode
            .hasFocus;
        await pump(tester, presetId: 'anthropic');
        await tester.enterText(field('Model'), '');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        // The name is fine; the API key is the first missing field.
        expect(focused('API key'), isTrue);
        expect(
          tester.takeAnnouncements(),
          contains(isAccessibilityAnnouncement('Fix the highlighted fields')),
        );

        await tester.enterText(field('Name'), '');
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();
        expect(focused('Name'), isTrue);
      });

      testWidgets('suggested model chips show a checkmark', (tester) async {
        await pump(tester, presetId: 'anthropic');
        final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
        expect(chips, isNotEmpty);
        expect(chips.map((c) => c.showCheckmark), everyElement(isTrue));
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

      testWidgets('the temperature slider adds no empty full-screen node', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, providerId: 'p1');
        await tester.ensureVisible(find.byType(Slider));
        await tester.pumpAndSettle();
        final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
        // A Slider's value indicator overlay used to add a screen-sized
        // leaf without a label or actions above the page.
        final covering = find.semantics.byPredicate((node) {
          final data = node.getSemanticsData();
          return !node.isMergedIntoParent &&
              !node.hasChildren &&
              data.label.isEmpty &&
              data.actions == 0 &&
              node.rect.width >= screen.width &&
              node.rect.height >= screen.height / 2;
        });
        expect(covering, findsNothing);
        // The slider is still one adjustable node named by its label.
        final slider = tester.getSemantics(find.byType(Slider));
        expect(
          slider,
          isSemantics(
            value: '0.7',
            isSlider: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        );
        expect(slider.label, startsWith('Temperature'));
        handle.dispose();
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
        // Prominent: an error-container banner with a title.
        final banner = find.byKey(const Key('provider_insecure_warning'));
        expect(banner, findsOneWidget);
        expect(
          find.descendant(
            of: banner,
            matching: find.text('Connection not encrypted'),
          ),
          findsOneWidget,
        );
        final colors = Theme.of(tester.element(banner)).colorScheme;
        expect(tester.widget<Card>(banner).color, colors.errorContainer);
        await tester.enterText(field('Base URL'), 'http://192.168.1.5:8080/v1');
        await tester.pump();
        expect(find.textContaining('Not encrypted'), findsNothing);
      });

      group('plain http to a remote host', () {
        Future<void> fill(WidgetTester tester, {String key = ''}) async {
          await pump(tester, presetId: 'custom');
          await tester.enterText(
            field('Base URL'),
            'http://llm.example.com/v1',
          );
          await tester.enterText(field('Model'), 'm');
          await tester.enterText(field('API key (optional)'), key);
          await tester.pump();
        }

        testWidgets('needs confirmation before saving', (tester) async {
          await fill(tester);
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Send without encryption?'), findsOneWidget);
          expect(
            find.text(
              'llm.example.com uses plain HTTP. Anyone on the network '
              'between you and this server can read your text.',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          verifyNever(() => settings.saveProvider(any()));

          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Send without encryption'));
          await tester.pumpAndSettle();
          expect(savedConfig().baseUrl, 'http://llm.example.com/v1');
        });

        testWidgets('mentions the API key when one is set', (tester) async {
          await fill(tester, key: 'sk-1');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('your text and your API key'), findsOne);
        });

        testWidgets('asks once per URL, also before testing', (tester) async {
          when(() => repository.testProvider(any()))
              .thenAnswer((_) async => 'Bonjour');
          await fill(tester, key: 'sk-1');
          await tester.tap(find.text('Test connection'));
          await tester.pumpAndSettle();
          expect(find.text('Send without encryption?'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          verifyNever(() => repository.testProvider(any()));

          await tester.tap(find.text('Test connection'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Send without encryption'));
          await tester.pumpAndSettle();
          verify(() => repository.testProvider(any())).called(1);

          // Already confirmed for this URL: saving does not ask again.
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Send without encryption?'), findsNothing);
          verify(() => settings.saveProvider(any())).called(1);
        });

        testWidgets('local hosts and https need no confirmation', (
          tester,
        ) async {
          await pump(tester, presetId: 'ollama');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Send without encryption?'), findsNothing);
          verify(() => settings.saveProvider(any())).called(1);
        });
      });

      group('secrets in the base URL', () {
        testWidgets('rejects user name and password', (tester) async {
          await pump(tester, presetId: 'openai');
          await tester.enterText(
            field('Base URL'),
            'https://me:secret@api.openai.com/v1',
          );
          await tester.enterText(field('API key'), 'sk-1');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Remove the user name and password'),
            findsOneWidget,
          );
          verifyNever(() => settings.saveProvider(any()));
        });

        testWidgets('rejects query strings such as ?key=', (tester) async {
          when(() => repository.testProvider(any()))
              .thenAnswer((_) async => 'Bonjour');
          await pump(tester, presetId: 'gemini');
          await tester.enterText(
            field('Base URL'),
            'https://generativelanguage.googleapis.com/v1beta?key=AIza',
          );
          await tester.enterText(field('API key'), 'AIza');
          await tester.tap(find.text('Test connection'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Remove the part after “?”'), findsOne);
          verifyNever(() => repository.testProvider(any()));
        });
      });

      group('preset headers', () {
        Map<String, String> openRouterHeaders() =>
            AiProviderPreset.byId('openrouter')!.headers;

        testWidgets('are kept on the preset host', (tester) async {
          await pump(tester, presetId: 'openrouter');
          expect(openRouterHeaders(), isNotEmpty);
          await tester.enterText(field('API key'), 'sk-or');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(savedConfig().headers, openRouterHeaders());
        });

        testWidgets('are dropped with a note for another host', (tester) async {
          await pump(tester, presetId: 'openrouter');
          expect(find.textContaining("This server isn't"), findsNothing);
          await tester.enterText(
            field('Base URL'),
            'https://llm.example.com/v1',
          );
          await tester.pump();
          expect(
            find.text(
              "This server isn't OpenRouter, so the headers added for "
              'OpenRouter (${openRouterHeaders().keys.join(', ')}) '
              "won't be sent.",
            ),
            findsOneWidget,
          );
          await tester.enterText(field('API key'), 'sk-or');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(savedConfig().headers, isEmpty);
        });

        testWidgets('of a saved provider are dropped when the host changes', (
          tester,
        ) async {
          final saved = AiProviderConfig(
            id: 'or',
            name: 'OpenRouter',
            provider: LlmProvider.openAiCompatible,
            baseUrl: 'https://openrouter.ai/api/v1',
            model: 'openrouter/auto',
            apiKey: 'sk-or',
            presetId: 'openrouter',
            headers: {...openRouterHeaders(), 'X-Own': 'kept'},
          );
          when(() => settings.state)
              .thenReturn(AppSettings(providers: [saved]));
          await pump(tester, providerId: 'or');
          await tester.enterText(field('Base URL'), 'https://proxy.example/v1');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(savedConfig().headers, {'X-Own': 'kept'});
        });
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
        final search = tester.widget<TextField>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(TextField),
          ),
        );
        expect(search.decoration?.labelText, 'Search models');
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

      testWidgets('says when no model matches the search', (tester) async {
        when(() => repository.listModels(any()))
            .thenAnswer((_) async => const [LlmModel(id: 'gpt-5')]);
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Browse models'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Search models'),
          'zzz',
        );
        await tester.pumpAndSettle();
        final empty = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('No models found'),
        );
        expect(empty, findsOneWidget);
        expect(tester.getSemantics(empty), isSemantics(isLiveRegion: true));
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
        expect(
          tester.getSemantics(
            find.text("Couldn't load models: 401: Unauthorized"),
          ),
          isSemantics(isLiveRegion: true),
        );
      });

      testWidgets('labels the loading indicator', (tester) async {
        final models = Completer<List<LlmModel>>();
        when(() => repository.listModels(any()))
            .thenAnswer((_) => models.future);
        final handle = tester.ensureSemantics();
        await pump(tester, providerId: 'p1');
        await tester.tap(find.text('Browse models'));
        await tester.pump();
        expect(find.semantics.byLabel(RegExp('Loading models…')), findsOne);
        models.complete(const []);
        await tester.pumpAndSettle();
        handle.dispose();
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

    group('machine translation', () {
      void expectNoModelFields() {
        for (final label in [
          'Provider type',
          'Model',
          'Browse models',
          'Suggested models',
          'Reasoning effort',
          'Temperature',
          'Supports images',
          'Prompt style',
        ]) {
          expect(find.text(label), findsNothing, reason: label);
        }
        expect(find.byType(Slider), findsNothing);
        expect(find.byKey(const Key('provider_prompt_profile')), findsNothing);
      }

      group('DeepL', () {
        testWidgets('shows only name, key and optional URL', (tester) async {
          await pump(tester, presetId: 'deepl');
          expect(find.text('Add translation service'), findsOneWidget);
          expect(textOf(tester, 'Name'), 'DeepL API');
          expect(textOf(tester, 'API key'), '');
          expect(textOf(tester, 'Server URL (optional)'), '');
          expect(
            find.text('Leave empty to use the official DeepL API'),
            findsOneWidget,
          );
          expect(find.text('Machine translation'), findsOneWidget);
          expect(find.text('Get an API key'), findsOneWidget);
          expectNoModelFields();
          // The key comes before the optional URL.
          expect(
            tester.getTopLeft(field('API key')).dy,
            lessThan(tester.getTopLeft(field('Server URL (optional)')).dy),
          );
        });

        testWidgets('requires the key but not the URL', (tester) async {
          bool focused(String label) => tester
              .widget<EditableText>(
                find.descendant(
                  of: field(label),
                  matching: find.byType(EditableText),
                ),
              )
              .focusNode
              .hasFocus;
          await pump(tester, presetId: 'deepl');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Required'), findsOneWidget);
          expect(focused('API key'), isTrue);
          verifyNever(() => settings.saveProvider(any()));
        });

        testWidgets('saves a new service with an empty URL', (tester) async {
          await pump(tester, presetId: 'deepl');
          await tester.enterText(field('API key'), ' abc:fx ');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          final config = savedConfig();
          expect(config.service, MtService.deepl);
          expect(config.isMtService, isTrue);
          expect(config.name, 'DeepL API');
          expect(config.baseUrl, '');
          expect(config.apiKey, 'abc:fx');
          expect(config.presetId, 'deepl');
          expect(config.model, '');
          expect(config.effort, isNull);
          expect(config.temperature, isNull);
          expect(config.supportsVision, isFalse);
          expect(find.text('Provider saved'), findsOneWidget);
        });

        testWidgets('rejects secrets in a proxy URL', (tester) async {
          await pump(tester, presetId: 'deepl');
          await tester.enterText(field('API key'), 'abc');
          await tester.enterText(
            field('Server URL (optional)'),
            'https://deepl.example.com/v2?auth_key=abc',
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Remove the part after “?”'), findsOne);
          await tester.enterText(field('Server URL (optional)'), 'nonsense');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(
            find.text('Enter a valid http:// or https:// URL'),
            findsOneWidget,
          );
          verifyNever(() => settings.saveProvider(any()));
        });

        testWidgets('edits an existing service and keeps its service', (
          tester,
        ) async {
          await pump(tester, providerId: 'mt1');
          expect(find.text('Edit translation service'), findsOneWidget);
          expect(textOf(tester, 'Name'), 'Work DeepL');
          expect(textOf(tester, 'API key'), 'dl-key:fx');
          expectNoModelFields();
          await tester.enterText(field('Name'), 'DeepL Pro');
          await tester.enterText(
            field('Server URL (optional)'),
            'https://deepl-proxy.example.com/',
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          final config = savedConfig();
          expect(config.id, 'mt1');
          expect(config.name, 'DeepL Pro');
          expect(config.service, MtService.deepl);
          expect(config.baseUrl, 'https://deepl-proxy.example.com');
          expect(config.apiKey, 'dl-key:fx');
          expect(config.presetId, 'deepl');
        });

        testWidgets('tests the connection through the repository', (
          tester,
        ) async {
          when(() => repository.testProvider(any()))
              .thenAnswer((_) async => 'Bonjour le monde !');
          await pump(tester, providerId: 'mt1');
          await tester.tap(find.text('Test connection'));
          await tester.pumpAndSettle();
          expect(
            find.text('Connected. “Hello” in French: Bonjour le monde !'),
            findsOneWidget,
          );
          final config =
              verify(() => repository.testProvider(captureAny()))
                      .captured
                      .single
                  as AiProviderConfig;
          expect(config.service, MtService.deepl);
          expect(config.apiKey, 'dl-key:fx');
          expect(config.baseUrl, '');
        });

        testWidgets('asks before using a plain http proxy', (tester) async {
          await pump(tester, providerId: 'mt1');
          await tester.enterText(
            field('Server URL (optional)'),
            'http://deepl.example.com',
          );
          await tester.pump();
          expect(
            find.byKey(const Key('provider_insecure_warning')),
            findsOneWidget,
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('your text and your API key'), findsOne);
          await tester.tap(find.text('Send without encryption'));
          await tester.pumpAndSettle();
          expect(savedConfig().service, MtService.deepl);
        });
      });

      group('LibreTranslate', () {
        testWidgets('prefills the public server; key optional', (tester) async {
          await pump(tester, presetId: 'libretranslate');
          expect(find.text('Add translation service'), findsOneWidget);
          expect(textOf(tester, 'Server URL'), 'https://libretranslate.com');
          expect(find.text('API key (optional)'), findsOneWidget);
          expect(
            find.text(
              'Only needed if the server requires one (libretranslate.com '
              'does). Stored securely on this device.',
            ),
            findsOneWidget,
          );
          expectNoModelFields();
        });

        testWidgets('requires a valid server URL', (tester) async {
          await pump(tester, presetId: 'libretranslate');
          await tester.enterText(field('Server URL'), '');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Required'), findsOneWidget);
          await tester.enterText(field('Server URL'), 'ftp://example.com');
          await tester.tap(find.text('Test connection'));
          await tester.pumpAndSettle();
          expect(
            find.text('Enter a valid http:// or https:// URL'),
            findsOneWidget,
          );
          verifyNever(() => settings.saveProvider(any()));
          verifyNever(() => repository.testProvider(any()));
        });

        testWidgets('saves a new service without a key', (tester) async {
          await pump(tester, presetId: 'libretranslate');
          await tester.enterText(field('Server URL'), 'http://localhost:5000/');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          final config = savedConfig();
          expect(config.service, MtService.libreTranslate);
          expect(config.baseUrl, 'http://localhost:5000');
          expect(config.apiKey, isNull);
          expect(config.presetId, 'libretranslate');
        });

        testWidgets('edits a service saved without a preset', (tester) async {
          await pump(tester, providerId: 'mt2');
          expect(find.text('Edit translation service'), findsOneWidget);
          expect(textOf(tester, 'Server URL'), 'http://192.168.1.20:5000');
          expect(find.text('API key (optional)'), findsOneWidget);
          expect(find.text('Get an API key'), findsNothing);
          expectNoModelFields();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          final config = savedConfig();
          expect(config.id, 'mt2');
          expect(config.service, MtService.libreTranslate);
          expect(config.presetId, isNull);
        });
      });

      testWidgets('fits 320dp with large text', (tester) async {
        await pump(
          tester,
          presetId: 'libretranslate',
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

    group('prompt style', () {
      Finder dropdown() => find.byKey(const Key('provider_prompt_profile'));

      PromptProfile? selected(WidgetTester tester) => tester
          .widget<DropdownButton<PromptProfile>>(
            find.byType(DropdownButton<PromptProfile>),
          )
          .value;

      testWidgets('Automatic shows the style for the current model', (
        tester,
      ) async {
        await pump(tester, presetId: 'ollama');
        expect(find.text('Prompt style'), findsOneWidget);
        expect(
          find.text(
            'Dedicated translation models need their own prompt format.',
          ),
          findsOneWidget,
        );
        expect(selected(tester), PromptProfile.auto);
        expect(find.text('Automatic (General chat model)'), findsOneWidget);
        expect(find.textContaining('only translates'), findsNothing);

        await tester.enterText(field('Model'), 'translategemma:4b');
        await tester.pump();
        expect(find.text('Automatic (TranslateGemma)'), findsOneWidget);
        expect(find.text('Automatic (General chat model)'), findsNothing);
        expect(find.textContaining('only translates'), findsOneWidget);

        await tester.enterText(field('Model'), 'hunyuan-mt-7b');
        await tester.pump();
        expect(find.text('Automatic (Hunyuan-MT)'), findsOneWidget);
        expect(selected(tester), PromptProfile.auto);
      });

      testWidgets('a new provider saves Automatic by default', (tester) async {
        await pump(tester, presetId: 'ollama');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final config = savedConfig();
        expect(config.promptProfile, PromptProfile.auto);
        expect(config.service, MtService.llm);
      });

      testWidgets('the chosen style is saved', (tester) async {
        await pump(tester, presetId: 'ollama');
        await tester.tap(dropdown());
        await tester.pumpAndSettle();
        expect(find.text('General chat model'), findsWidgets);
        expect(find.text('TranslateGemma'), findsWidgets);
        await tester.tap(find.text('Hunyuan-MT').last);
        await tester.pumpAndSettle();
        expect(selected(tester), PromptProfile.hunyuanMt);
        expect(find.textContaining('only translates'), findsOneWidget);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(savedConfig().promptProfile, PromptProfile.hunyuanMt);
      });

      testWidgets('an existing provider keeps its style', (tester) async {
        await pump(tester, providerId: 'g1');
        expect(selected(tester), PromptProfile.translateGemma);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final config = savedConfig();
        expect(config.promptProfile, PromptProfile.translateGemma);
        expect(config.service, MtService.llm);
      });

      testWidgets('switching back to Automatic is saved', (tester) async {
        await pump(tester, providerId: 'g1');
        await tester.tap(dropdown());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Automatic (General chat model)').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(savedConfig().promptProfile, PromptProfile.auto);
      });

      testWidgets('is sent with the connection test', (tester) async {
        when(() => repository.testProvider(any()))
            .thenAnswer((_) async => 'Bonjour');
        await pump(tester, providerId: 'g1');
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();
        final config =
            verify(() => repository.testProvider(captureAny())).captured.single
                as AiProviderConfig;
        expect(config.promptProfile, PromptProfile.translateGemma);
      });
    });

    group('usage', () {
      late UsageTracker tracker;

      setUp(() => tracker = UsageTracker(store: MemoryStore()));
      tearDown(() => tracker.dispose());

      testWidgets('shows the usage of an existing provider', (tester) async {
        await tracker.record('p1', 1000, 234);
        await pump(tester, providerId: 'p1', usageTracker: tracker);
        await tester.pumpAndSettle();
        expect(find.byType(UsageCard), findsOneWidget);
        expect(
          tester.widget<UsageCard>(find.byType(UsageCard)).providerId,
          'p1',
        );
        expect(find.text('1,000 sent · 234 received'), findsOneWidget);
        await tester.tap(find.text('All providers'));
        await tester.pumpAndSettle();
        verify(
          () => router.push<Object?>(
            '/settings/usage',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('is hidden for new providers', (tester) async {
        await pump(tester, presetId: 'openai', usageTracker: tracker);
        await tester.pumpAndSettle();
        expect(find.byType(UsageCard), findsNothing);
      });

      testWidgets('is hidden without a usage tracker', (tester) async {
        await pump(tester, providerId: 'p1');
        await tester.pumpAndSettle();
        expect(find.byType(UsageCard), findsNothing);
      });

      testWidgets('deleting the provider removes its usage', (tester) async {
        await tracker.record('p1', 1000, 234);
        await tracker.record('other', 10, 5);
        await tracker.setBudget('p1', const UsageBudget(monthlyChars: 5000));
        await pump(tester, providerId: 'p1', usageTracker: tracker);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        verify(() => settings.removeProvider('p1')).called(1);
        final snapshot = tracker.snapshot;
        expect(snapshot.statsFor('p1').requests, 0);
        expect(snapshot.budgetFor('p1'), isNull);
        expect(snapshot.statsFor('other').requests, 1);
      });
    });

    testWidgets('the temperature slider changes the saved value', (
      tester,
    ) async {
      await pump(tester, providerId: 'p1');
      await tester.drag(find.byType(Slider), const Offset(200, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedConfig().temperature, greaterThan(0.7));
    });

    testWidgets('temperature value grows with large text', (tester) async {
      await pump(
        tester,
        providerId: 'p1',
        size: const Size(320, 2400),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      // One line, wider than the old fixed 40 dp box.
      final size = tester.getSize(find.text('0.7'));
      expect(size.width, greaterThan(40));
      expect(size.height, lessThan(2 * 2 * 14 * 1.5));
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
