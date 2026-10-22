import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/privacy_channel.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

class _MockSpeechService extends Mock implements SpeechService;

class _MockSpeechInputService extends Mock implements SpeechInputService;

const _local = AiProviderConfig(
  id: 'p2',
  name: 'Local Qwen',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'qwen3',
  enabled: false,
);

/// The heading of the section titled [title] (the first text of the
/// section).
Finder sectionTitled(String title) => find
    .descendant(of: find.byType(SettingsSection), matching: find.text(title))
    .first;

/// The [SettingsSection] titled [title].
Finder sectionOf(String title) => find.ancestor(
  of: sectionTitled(title),
  matching: find.byType(SettingsSection),
);

void main() {
  setUpAll(registerFallbacks);

  group('SettingsPage', () {
    late MockSettingsCubit settings;
    late MockHistoryCubit history;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(
          instances: [
            MozhiInstance(url: 'https://mozhi.example.com'),
            MozhiInstance(url: 'https://other.example.org'),
          ],
          providers: [_claude, _local],
        ),
      );
      history = createHistoryCubit();
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      AppSettings? state,
      SettingsCategory? category,
      String? highlight,
      Size size = const Size(800, 5000),
      double textScale = 1,
    }) async {
      if (state != null) when(() => settings.state).thenReturn(state);
      tester.setScreenSize(size);
      await tester.pumpView(
        category == null
            ? const SettingsPage()
            : SettingsCategoryPage(category: category, highlight: highlight),
        settings: settings,
        history: history,
        router: router,
        textScale: textScale,
      );
    }

    void verifyPush(String location) =>
        verify(() => router.push<Object?>(location, extra: any(named: 'extra')))
            .called(1);

    testWidgets('is a page with a back arrow to the tabs', (tester) async {
      await pump(tester);
      // Opened on its own (the only page): the arrow goes to Translate.
      await tester.tap(find.byKey(const Key('top_level_back')));
      verify(() => router.go('/translate')).called(1);
    });

    testWidgets('lists the categories with what they hold', (tester) async {
      await pump(tester);
      expect(find.text('Settings'), findsOneWidget);
      for (final (title, summary) in [
        ('General', 'App language, tab order, typing'),
        ('Privacy & data', 'Privacy mode, history, network, delete data'),
        (
          'Translation engines',
          'Offline languages, Mozhi instances, services, instant translate',
        ),
        ('AI', 'AI providers, insights, presets, glossaries, usage'),
        ('Appearance', 'Theme, dark look, accent color, romanization'),
        ('About', 'Version, source code, licenses and privacy'),
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
        expect(find.text(summary), findsOneWidget, reason: summary);
      }
      // No rows of the categories on the root.
      expect(find.text('Incognito'), findsNothing);
      // Read aloud & voice only with a speech service or voice input.
      expect(find.text('Read aloud & voice'), findsNothing);
    });

    testWidgets('orders the categories from general to about', (tester) async {
      await pump(tester);
      final tops = [
        for (final category in [
          SettingsCategory.general,
          SettingsCategory.privacy,
          SettingsCategory.engines,
          SettingsCategory.ai,
          SettingsCategory.appearance,
          SettingsCategory.about,
        ])
          tester.getTopLeft(find.byKey(SettingsView.categoryKey(category))).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
    });

    testWidgets('opens each category as a page of its own', (tester) async {
      await pump(tester);
      for (final category in [
        SettingsCategory.general,
        SettingsCategory.privacy,
        SettingsCategory.engines,
        SettingsCategory.ai,
        SettingsCategory.appearance,
      ]) {
        await tester.tap(find.byKey(SettingsView.categoryKey(category)));
        verifyPush('/settings/${category.path}');
      }
      await tester.tap(
        find.byKey(SettingsView.categoryKey(SettingsCategory.about)),
      );
      verifyPush('/settings/about');
    });

    testWidgets('marks the AI settings as advanced', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      final tile = find.byKey(SettingsView.categoryKey(SettingsCategory.ai));
      expect(
        find.descendant(of: tile, matching: find.text('Advanced')),
        findsOneWidget,
      );
      // Read with the title.
      expect(tester.getSemantics(tile).label, startsWith('AI\nAdvanced'));
      // And on its page, next to the title.
      await pump(tester, category: SettingsCategory.ai);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Advanced'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a category page is titled after its category', (tester) async {
      await pump(tester, category: SettingsCategory.privacy);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Privacy & data'),
        ),
        findsOneWidget,
      );
      // Its back arrow is the app bar's own (Settings is below it).
      expect(find.byKey(const Key('top_level_back')), findsNothing);
      // The AI page no longer repeats "AI providers" as a heading.
      await pump(tester, category: SettingsCategory.ai);
      expect(find.text('AI providers'), findsOneWidget);
    });

    testWidgets('summarises instances and providers', (tester) async {
      await pump(tester, category: SettingsCategory.engines);
      expect(find.text('mozhi.example.com · 2 instances'), findsOneWidget);
      await pump(tester, category: SettingsCategory.ai);
      expect(find.text('1 of 2 enabled'), findsOneWidget);
    });

    testWidgets('shows hints when nothing is configured', (tester) async {
      await pump(
        tester,
        state: const AppSettings(instances: []),
        category: SettingsCategory.engines,
      );
      expect(
        find.text('No instances. Add one to use Mozhi engines.'),
        findsOneWidget,
      );
      await pump(tester, category: SettingsCategory.ai);
      expect(
        find.text('Use your own API key or a local model'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Add an AI provider for alternatives, insights and explanations',
        ),
        findsOneWidget,
      );
    });

    testWidgets('navigates to sub pages', (tester) async {
      await pump(tester, category: SettingsCategory.engines);
      await tester.tap(find.text('Mozhi instances'));
      verifyPush('/settings/instances');
      await tester.tap(find.text('Translation services'));
      verifyPush('/settings/providers');
      await pump(tester, category: SettingsCategory.ai);
      await tester.tap(find.byKey(const Key('settings_ai_providers')));
      verifyPush('/settings/providers');
    });

    group('round-2 pages', () {
      Future<void> expectPush(
        WidgetTester tester,
        String title,
        String location,
      ) async {
        await tester.ensureVisible(find.text(title));
        await tester.tap(find.text(title));
        verifyPush(location);
      }

      testWidgets('opens offline languages, usage, presets and glossaries', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.engines);
        await expectPush(
          tester,
          'Languages on this device',
          '/settings/offline',
        );
        await pump(tester, category: SettingsCategory.ai);
        await expectPush(tester, 'Usage & costs', '/settings/usage');
        await expectPush(tester, 'Presets', '/settings/presets');
        await expectPush(tester, 'Glossaries', '/settings/glossaries');
        await pump(tester, category: SettingsCategory.about);
        await expectPush(tester, 'Run setup again', '/onboarding');
      });

      testWidgets('groups the entries into categories and sections', (
        tester,
      ) async {
        Finder inSection(String section, String title) =>
            find.descendant(of: sectionOf(section), matching: find.text(title));
        for (final (category, groups) in [
          (
            SettingsCategory.general,
            [
              (
                null,
                [
                  'App language',
                  'Tab order',
                  'Haptic feedback',
                  'Multiline input',
                ],
              ),
            ],
          ),
          (
            SettingsCategory.privacy,
            [
              ('Privacy', ['Privacy mode', 'Incognito']),
              (
                'History',
                [
                  'Save history',
                  'Delete history automatically',
                  'Export history',
                  'Import history',
                  'Clear recent language pairs',
                ],
              ),
              ('Network', ['HTTP proxy', 'Network activity']),
              ('Data', ['Clear history', 'Delete all local data']),
            ],
          ),
          (
            SettingsCategory.engines,
            [
              ('Offline languages', ['Languages on this device']),
              ('Online engines', ['Mozhi instances', 'Translation services']),
              (
                'Translating',
                [
                  'Quality modes',
                  'Remember quality selection',
                  'Instant translate',
                ],
              ),
            ],
          ),
          (
            SettingsCategory.ai,
            [
              (
                null,
                [
                  'AI providers',
                  'AI assistant for insights',
                  'Presets',
                  'Glossaries',
                  'Usage & costs',
                ],
              ),
            ],
          ),
          (
            SettingsCategory.appearance,
            [
              (null, ['Theme', 'Dark theme', 'Show romanization']),
            ],
          ),
          (
            SettingsCategory.about,
            [
              (
                'About',
                ['Source code', 'Open-source licenses', 'Run setup again'],
              ),
            ],
          ),
        ]) {
          await pump(tester, category: category);
          for (final (section, rows) in groups) {
            for (final row in rows) {
              expect(
                section == null
                    ? find.descendant(
                        of: find.byType(SettingsSection),
                        matching: find.text(row),
                      )
                    : inSection(section, row),
                findsOne,
                reason: '${category.name} > $section: $row',
              );
            }
          }
        }
      });

      testWidgets('ends Privacy & data with the destructive actions', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.privacy);
        final data = find.byKey(const Key('settings_data_section'));
        final error = Theme.of(tester.element(data)).colorScheme.error;
        for (final key in [
          'settings_clear_history',
          'settings_delete_all_data',
        ]) {
          final row = find.byKey(Key(key));
          expect(
            tester.getTopLeft(row).dy,
            greaterThan(tester.getTopLeft(find.text('Network activity')).dy),
          );
          expect(find.descendant(of: data, matching: row), findsOne);
        }
        expect(
          tester.widget<Text>(find.text('Delete all local data')).style?.color,
          error,
        );
      });

      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        testWidgets('shows offline languages on ${platform.name}', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          await pump(tester, category: SettingsCategory.engines);
          expect(find.text('Languages on this device'), findsOneWidget);
          expect(find.text('Not available here'), findsNothing);
          expect(SettingsView.offlineSupported, isTrue);
          debugDefaultTargetPlatformOverride = null;
        });
      }

      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        testWidgets('says offline languages are unavailable on '
            '${platform.name}', (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          await pump(tester, category: SettingsCategory.engines);
          expect(find.text('Languages on this device'), findsNothing);
          expect(find.text('Not available here'), findsOneWidget);
          expect(
            find.text('On-device translation needs the Android app.'),
            findsOneWidget,
          );
          expect(SettingsView.offlineSupported, isFalse);
          debugDefaultTargetPlatformOverride = null;
        });
      }
    });

    group('general', () {
      testWidgets('starts with the system language', (tester) async {
        await pump(tester, category: SettingsCategory.general);
        expect(
          find.descendant(
            of: find.byKey(const Key('settings_app_language')),
            matching: find.text('System default'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows the chosen app language in itself', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(appLocale: 'ja'),
        );
        final name = find.descendant(
          of: find.byKey(const Key('settings_app_language')),
          matching: find.text('日本語'),
        );
        expect(name, findsOneWidget);
        // Drawn with Japanese glyphs.
        expect(tester.widget<Text>(name).locale, const Locale('ja'));
        final label = tester
            .getSemantics(find.byKey(const Key('settings_app_language')))
            .getSemanticsData()
            .attributedLabel;
        expect(label.string, contains('日本語'));
        expect(
          label.attributes.whereType<LocaleStringAttribute>().single.locale,
          const Locale('ja'),
        );
        handle.dispose();
      });

      testWidgets('an unknown stored language shows the system default', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(appLocale: 'sv'),
        );
        expect(find.text('System default'), findsOneWidget);
      });

      testWidgets('picks an app language from every translation', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.general);
        await tester.tap(find.text('App language'));
        await tester.pumpAndSettle();

        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(of: dialog, matching: find.text('System default')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: dialog,
            matching: find.text(
              'The language of the menus and buttons. What you translate is '
              'not affected.',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(RadioListTile<String>),
          ),
          findsNWidgets(AppLocalizations.supportedLocales.length + 1),
        );
        for (final name in ['English', 'Español', 'العربية', '简体中文']) {
          expect(
            find.descendant(of: dialog, matching: find.text(name)),
            findsOneWidget,
            reason: name,
          );
        }

        await tester.tap(find.text('Deutsch'));
        await tester.pump();
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();
        verify(() => settings.setAppLocale('de')).called(1);
      });

      testWidgets('goes back to the system language', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(appLocale: 'de'),
        );
        await tester.tap(find.text('App language'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('System default'));
        await tester.pump();
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();
        verify(() => settings.setAppLocale(null)).called(1);
      });

      testWidgets('keeps the app language when cancelled or unchanged', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(appLocale: 'de'),
        );
        await tester.tap(find.text('App language'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('App language'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ChoiceDialog.saveKey));
        await tester.pumpAndSettle();
        verifyNever(() => settings.setAppLocale(any()));
      });

      testWidgets('opens the tab order and names the first tab', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(
            tabOrder: [
              AppTab.dictionary,
              AppTab.translate,
              AppTab.proofread,
              AppTab.conversation,
            ],
          ),
        );
        expect(find.text('Opens on Dictionary'), findsOneWidget);
        await tester.tap(find.text('Tab order'));
        verify(
          () => router.push<Object?>(
            '/settings/tabs',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('haptic feedback (on by default)', (tester) async {
        await pump(tester, category: SettingsCategory.general);
        expect(find.textContaining('Vibrate lightly'), findsOneWidget);
        await tester.tap(find.text('Haptic feedback'));
        verify(() => settings.setHapticFeedback(enabled: false)).called(1);
      });

      testWidgets('multiline input (on by default) explains Enter', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.general);
        expect(
          find.text(
            'When on, Enter adds a new line instead of starting a '
            'translation.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Multiline input'));
        verify(() => settings.setMultilineInput(enabled: false)).called(1);
      });

      testWidgets('turns multiline input back on', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.general,
          state: const AppSettings(multilineInput: false),
        );
        await tester.tap(find.text('Multiline input'));
        verify(() => settings.setMultilineInput(enabled: true)).called(1);
      });
    });

    group('translation toggles', () {
      testWidgets('remember quality selection (on by default)', (tester) async {
        await pump(tester, category: SettingsCategory.engines);
        await tester.ensureVisible(find.text('Remember quality selection'));
        expect(
          find.textContaining('When off, the app starts in Fast'),
          findsOneWidget,
        );
        await tester.tap(find.text('Remember quality selection'));
        verify(() => settings.setRememberQuality(enabled: false)).called(1);
      });

      group('instant translate', () {
        Future<AppSettings Function(AppSettings)> choose(
          WidgetTester tester,
          String choice, {
          AppSettings state = const AppSettings(),
        }) async {
          await pump(tester, state: state, category: SettingsCategory.engines);
          await tester.tap(find.text('Instant translate'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice).last);
          await tester.pump();
          await tester.tap(find.byKey(ChoiceDialog.saveKey));
          await tester.pumpAndSettle();
          return verify(() => settings.update(captureAny())).captured.single
              as AppSettings Function(AppSettings);
        }

        testWidgets('is one row naming the choice (both on by default)', (
          tester,
        ) async {
          await pump(tester, category: SettingsCategory.engines);
          expect(find.text('Instant translate'), findsOneWidget);
          expect(find.text('Instant translate with AI'), findsNothing);
          expect(find.text('Online engines and AI'), findsOneWidget);
        });

        testWidgets('offers off, online engines, and online engines and AI', (
          tester,
        ) async {
          await pump(tester, category: SettingsCategory.engines);
          await tester.tap(find.text('Instant translate'));
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog);
          for (final title in [
            'Off',
            'Online engines',
            'Online engines and AI',
          ]) {
            expect(
              find.descendant(of: dialog, matching: find.text(title)),
              findsOneWidget,
              reason: title,
            );
          }
          expect(find.text('AI providers only'), findsNothing);
          expect(find.textContaining('Uses more tokens'), findsOneWidget);
        });

        testWidgets('off turns both switches off', (tester) async {
          final change = await choose(tester, 'Off');
          final next = change(const AppSettings());
          expect(next.instantTranslate, isFalse);
          expect(next.instantTranslateAi, isFalse);
        });

        testWidgets('online engines leaves AI waiting', (tester) async {
          final change = await choose(tester, 'Online engines');
          final next = change(const AppSettings());
          expect(next.instantTranslate, isTrue);
          expect(next.instantTranslateAi, isFalse);
        });

        testWidgets('online engines and AI turns both on', (tester) async {
          final change = await choose(
            tester,
            'Online engines and AI',
            state: const AppSettings(
              instantTranslate: false,
              instantTranslateAi: false,
            ),
          );
          final next = change(const AppSettings(instantTranslate: false));
          expect(next.instantTranslate, isTrue);
          expect(next.instantTranslateAi, isTrue);
        });

        testWidgets('keeps an AI-only setting, offered while it is set', (
          tester,
        ) async {
          const aiOnly = AppSettings(instantTranslate: false);
          await pump(tester, state: aiOnly, category: SettingsCategory.engines);
          expect(find.text('AI providers only'), findsOneWidget);
          await tester.tap(find.text('Instant translate'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ChoiceDialog.saveKey));
          await tester.pumpAndSettle();
          verifyNever(() => settings.update(any()));
        });
      });

      testWidgets('save history', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Save history'));
        verify(() => settings.setSaveHistory(enabled: false)).called(1);
      });

      testWidgets('show romanization', (tester) async {
        await pump(tester, category: SettingsCategory.appearance);
        expect(
          find.text(
            'Latin-script text under non-Latin text, when no cloud AI '
            'request is needed',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Show romanization'));
        verify(() => settings.setShowTransliteration(enabled: false)).called(1);
      });
    });

    group('AI assistant picker', () {
      testWidgets('selects an enabled provider', (tester) async {
        await pump(tester, category: SettingsCategory.ai);
        expect(find.text('Automatic'), findsOneWidget);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        // Disabled providers are not offered.
        expect(find.text('Local Qwen'), findsNothing);
        await tester.tap(find.text('Claude'));
        await tester.pumpAndSettle();
        // Choosing only moves the selection; Save confirms it.
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setAssistEngine(any()));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setAssistEngine('ai:p1')).called(1);
      });

      testWidgets('selects automatic', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.ai,
          state: const AppSettings(
            providers: [_claude],
            assistEngineId: 'ai:p1',
          ),
        );
        expect(find.text('Claude'), findsOneWidget);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Automatic'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verify(() => settings.setAssistEngine(null)).called(1);
      });

      testWidgets('arrow keys move the choice without closing the dialog', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.ai);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setAssistEngine(any()));

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setAssistEngine('ai:p1')).called(1);
      });

      testWidgets('cancel keeps the selection', (tester) async {
        await pump(tester, category: SettingsCategory.ai);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.setAssistEngine(any()));
      });

      testWidgets('opens providers when none exist', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.ai,
          state: const AppSettings(),
        );
        await tester.tap(find.text('AI assistant for insights'));
        verify(
          () => router.push<Object?>(
            '/settings/providers',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });
    });

    group('appearance', () {
      testWidgets('changes theme mode', (tester) async {
        await pump(tester, category: SettingsCategory.appearance);
        await tester.tap(find.text('Dark'));
        verify(() => settings.setThemeMode(ThemeMode.dark)).called(1);
      });

      testWidgets('toggles dynamic color', (tester) async {
        await pump(tester, category: SettingsCategory.appearance);
        await tester.tap(find.text('Dynamic color'));
        verify(() => settings.setDynamicColor(enabled: false)).called(1);
      });

      testWidgets('hides accent colors with dynamic color', (tester) async {
        await pump(tester, category: SettingsCategory.appearance);
        expect(find.text('Accent color'), findsNothing);
      });

      testWidgets('picks an accent color without dynamic color', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          state: const AppSettings(dynamicColor: false),
        );
        expect(find.text('Accent color'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Teal'));
        verify(() => settings.setSeedColor(0xFF00897B)).called(1);
      });

      testWidgets('accent colors always shown on iOS', (tester) async {
        when(() => settings.state).thenReturn(const AppSettings());
        tester.setScreenSize(const Size(800, 5000));
        await tester.pumpView(
          const SettingsCategoryPage(category: SettingsCategory.appearance),
          settings: settings,
          history: history,
          router: router,
          theme: ThemeData(platform: TargetPlatform.iOS),
        );
        expect(find.text('Dynamic color'), findsNothing);
        expect(find.text('Accent color'), findsOneWidget);
      });

      testWidgets('marks the selected theme with a check', (tester) async {
        await pump(tester, category: SettingsCategory.appearance);
        expect(
          find.descendant(
            of: find.byType(SegmentedButton<ThemeMode>),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Theme'), findsOneWidget);
      });

      testWidgets('uses radio rows for the theme with large text', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          textScale: 2,
          size: const Size(800, 10000),
        );
        expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
        expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
        await tester.ensureVisible(find.text('Dark'));
        await tester.tap(find.text('Dark'));
        verify(() => settings.setThemeMode(ThemeMode.dark)).called(1);
      });

      testWidgets('accent swatches keep their tap action for screen readers', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          category: SettingsCategory.appearance,
          state: const AppSettings(dynamicColor: false),
        );
        final node = tester.getSemantics(find.bySemanticsLabel('Teal'));
        expect(
          node,
          isSemantics(
            label: 'Teal',
            isButton: true,
            hasTapAction: true,
            isInMutuallyExclusiveGroup: true,
            hasSelectedState: true,
            isSelected: false,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Blue')),
          isSemantics(isSelected: true),
        );
        expect(node.id, isNonZero);
        tester.semantics.tap(find.semantics.byLabel('Teal'));
        verify(() => settings.setSeedColor(0xFF00897B)).called(1);
        handle.dispose();
      });

      testWidgets('swatches do not animate with reduced motion', (
        tester,
      ) async {
        when(() => settings.state)
            .thenReturn(const AppSettings(dynamicColor: false));
        tester.setScreenSize(const Size(800, 4000));
        await tester.pumpView(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const SettingsCategoryPage(
                category: SettingsCategory.appearance,
              ),
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        final containers = tester.widgetList<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        expect(containers, isNotEmpty);
        expect(containers.map((c) => c.duration), everyElement(Duration.zero));
      });

      testWidgets('offers X accents with blue first', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          state: const AppSettings(dynamicColor: false),
        );
        for (final name in [
          'Blue',
          'Yellow',
          'Pink',
          'Purple',
          'Orange',
          'Green',
        ]) {
          expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
        }
        expect(
          tester.getTopLeft(find.bySemanticsLabel('Blue')).dx,
          lessThan(tester.getTopLeft(find.bySemanticsLabel('Yellow')).dx),
        );
      });

      testWidgets('picks Lights out (the default) or Dim for the dark '
          'theme', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, category: SettingsCategory.appearance);
        expect(find.text('Dark theme'), findsOneWidget);
        expect(find.bySemanticsLabel('Dark theme'), findsOneWidget);
        expect(
          tester
              .widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>))
              .groupValue,
          isTrue,
        );
        await tester.tap(find.text('Dim'));
        verify(() => settings.setPureBlack(enabled: false)).called(1);
        // Picking the current look again is a no-op.
        await tester.tap(find.text('Lights out'));
        verifyNever(
          () => settings.setPureBlack(enabled: any(named: 'enabled')),
        );
        handle.dispose();
      });

      testWidgets('switches back to Lights out', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          state: const AppSettings(pureBlack: false),
        );
        await tester.tap(find.text('Lights out'));
        verify(() => settings.setPureBlack(enabled: true)).called(1);
      });

      testWidgets('the dark look is disabled in light mode', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          state: const AppSettings(themeMode: ThemeMode.light),
        );
        final tiles = tester.widgetList<RadioListTile<bool>>(
          find.byType(RadioListTile<bool>),
        );
        expect(tiles.map((t) => t.enabled), everyElement(isFalse));
        await tester.tap(find.text('Lights out'), warnIfMissed: false);
        verifyNever(
          () => settings.setPureBlack(enabled: any(named: 'enabled')),
        );
      });

      testWidgets('renders in the app theme (light and Lights out)', (
        tester,
      ) async {
        for (final theme in [
          buildAppTheme(
            appColorScheme(
              brightness: Brightness.light,
              seedColor: const Color(0xFF1D9BF0),
            ),
          ),
          buildAppTheme(
            appColorScheme(
              brightness: Brightness.dark,
              seedColor: const Color(0xFF1D9BF0),
              pureBlack: true,
            ),
          ),
        ]) {
          when(() => settings.state).thenReturn(const AppSettings());
          tester.setScreenSize(const Size(800, 4000));
          await tester.pumpView(
            const SettingsCategoryPage(category: SettingsCategory.engines),
            settings: settings,
            history: history,
            router: router,
            theme: theme,
          );
          await tester.pumpAndSettle();
          // Plain rows: no tinted icon squares, bold section headings.
          final heading = tester.widget<Text>(find.text('Online engines'));
          expect(heading.style?.fontWeight, FontWeight.w800);
          expect(find.byType(Card), findsNothing);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.dns_outlined)).color,
            theme.extension<AppPalette>()!.secondaryText,
          );
          expect(find.byType(Hairline), findsWidgets);
        }
      });
    });

    group('data', () {
      setUp(() {
        when(history.exportJson).thenAnswer((_) async => '[{"id":"1"}]');
      });

      testWidgets('exports history to the clipboard', (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
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
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();
        verify(history.exportJson).called(1);
        expect(copied, '[{"id":"1"}]');
        expect(find.text('History copied as JSON'), findsOneWidget);
      });

      testWidgets('warns that the export is not encrypted', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        expect(find.byType(ExportUnencryptedWarning), findsOneWidget);
        expect(
          find.text(
            "The exported JSON isn't encrypted: anyone who can open it can "
            'read your history. Keep it somewhere safe.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('marks the copy sensitive and leaves the confirmation to '
          'Android 13+', (tester) async {
        final previous = ClipboardService.instance;
        addTearDown(() => ClipboardService.instance = previous);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          privacyChannel(),
          (call) async {
            copied.add(call.arguments as String);
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            privacyChannel(),
            null,
          ),
        );
        ClipboardService.instance = ClipboardService(isAndroid: true);
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();

        expect(copied, ['[{"id":"1"}]']);
        expect(find.text('History copied as JSON'), findsNothing);
      });

      testWidgets('the import field keeps keyboards from learning while '
          'incognito', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          state: const AppSettings(incognito: true),
        );
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byType(ImportHistoryDialog),
            matching: find.byType(TextField),
          ),
        );
        expect(field.enableIMEPersonalizedLearning, isFalse);
      });

      testWidgets('shares exported history', (tester) async {
        final shared = <String>[];
        final original = HistoryShare.share;
        HistoryShare.share = (json) async => shared.add(json);
        addTearDown(() => HistoryShare.share = original);
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Share as file'));
        await tester.pumpAndSettle();
        expect(shared, ['[{"id":"1"}]']);
      });

      testWidgets('reports export failures', (tester) async {
        when(history.exportJson).thenThrow(Exception('disk'));
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();
        expect(find.text("Couldn't export history"), findsOneWidget);
      });

      testWidgets('imports pasted JSON', (tester) async {
        when(() => history.importJson(any())).thenAnswer(
          (_) async => const HistoryImport(entries: [], added: 0, expired: 0),
        );
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        // Labelled, not only hinted, so it stays named once filled.
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .decoration
              ?.labelText,
          'History JSON',
        );
        await tester.enterText(find.byType(TextField), '[]');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        verify(() => history.importJson('[]')).called(1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('History imported'), findsOneWidget);
      });

      testWidgets('says how many old translations were skipped', (
        tester,
      ) async {
        when(() => history.importJson(any())).thenAnswer(
          (_) async => const HistoryImport(entries: [], added: 1, expired: 340),
        );
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '[]');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text(
            'History imported. 340 translations were skipped because they '
            'are older than your auto-delete period.',
          ),
          findsOneWidget,
        );
        expect(find.text('History imported'), findsNothing);
      });

      testWidgets('cancelling the import shows nothing', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        verifyNever(() => history.importJson(any()));
      });

      testWidgets('pastes from the clipboard', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? <String, dynamic>{'text': '[{"id":"2"}]'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Paste from clipboard'));
        await tester.pumpAndSettle();
        expect(find.text('[{"id":"2"}]'), findsOneWidget);
      });

      testWidgets('shows an error for invalid JSON', (tester) async {
        when(() => history.importJson(any()))
            .thenThrow(const FormatException('bad'));
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        // Empty input is rejected without calling the cubit.
        verifyNever(() => history.importJson(any()));
        expect(find.text("This isn't valid Mozhi history JSON."), findsOne);

        await tester.enterText(find.byType(TextField), 'nope');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        verify(() => history.importJson('nope')).called(1);
        expect(find.text("This isn't valid Mozhi history JSON."), findsOne);
        expect(find.byType(AlertDialog), findsOneWidget);
      });

      testWidgets('clears history keeping favorites by default', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        expect(find.text('Clear history?'), findsOneWidget);
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        verify(() => history.clear(keepFavorites: true)).called(1);
        expect(find.text('History cleared'), findsOneWidget);
      });

      testWidgets('clears everything when unchecked', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep favorites'));
        await tester.pump();
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        verify(() => history.clear()).called(1);
      });

      testWidgets('cancel does not clear', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(
          () => history.clear(keepFavorites: any(named: 'keepFavorites')),
        );
      });
    });

    group('read aloud', () {
      late _MockSpeechService speech;

      setUp(() {
        speech = _MockSpeechService();
        when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
        when(() => speech.current).thenReturn(null);
        when(() => speech.deviceVoiceSupported).thenReturn(true);
        when(() => speech.preferDeviceVoice).thenReturn(false);
        when(speech.loadPreferDeviceVoice).thenAnswer((_) async => false);
        when(speech.loadSettings)
            .thenAnswer((_) async => const SpeechSettings());
        when(speech.stop).thenAnswer((_) async {});
      });

      testWidgets('is hidden without a speech service', (tester) async {
        await pump(tester, category: SettingsCategory.speech);

        expect(find.byType(SpeechSettingsSection), findsNothing);
      });

      testWidgets('is a category with a speech service', (tester) async {
        tester.setScreenSize(const Size(800, 2000));
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: const SettingsPage(),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        final tile = find.byKey(
          SettingsView.categoryKey(SettingsCategory.speech),
        );
        expect(find.text('Read aloud & voice'), findsOneWidget);
        expect(find.text('Speech rate, voices, voice input'), findsOneWidget);
        // After the appearance, before About.
        expect(
          tester.getTopLeft(tile).dy,
          greaterThan(
            tester
                .getTopLeft(
                  find.byKey(
                    SettingsView.categoryKey(SettingsCategory.appearance),
                  ),
                )
                .dy,
          ),
        );
        await tester.tap(tile);
        verifyPush('/settings/speech');
      });

      testWidgets('offers voices for the languages in use', (tester) async {
        when(() => settings.state).thenReturn(
          const AppSettings(
            source: Language(code: 'de', name: 'German'),
            target: Language(code: 'fr', name: 'French'),
            recentLanguages: [
              Language(code: 'fr', name: 'French'),
              Language(code: 'es', name: 'Spanish'),
            ],
          ),
        );
        tester.setScreenSize(const Size(800, 5000));
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: const SettingsCategoryPage(
              category: SettingsCategory.speech,
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        await tester.pump();

        expect(find.text('Read aloud'), findsOneWidget);
        expect(find.text('Speech rate'), findsOneWidget);
        expect(
          [
            for (final text in tester.widgetList<Text>(
              find.textContaining(RegExp(r'^\w+ voice$')),
            ))
              text.data,
          ],
          ['French voice', 'German voice', 'Spanish voice'],
        );
      });

      testWidgets('leaves no empty semantics node over the settings list', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        const size = Size(412, 915);
        tester.setScreenSize(size);
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: const SettingsCategoryPage(
              category: SettingsCategory.speech,
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        await tester.pump();
        // Bring the rate slider in.
        await tester.scrollUntilVisible(
          find.byType(Slider),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(Slider), findsOneWidget);

        // The rate slider's overlay used to add a screen-sized leaf without
        // a label or actions above the list (on the web it blocked clicks).
        final covering = find.semantics.byPredicate((node) {
          final data = node.getSemanticsData();
          return !node.isMergedIntoParent &&
              !node.hasChildren &&
              data.label.isEmpty &&
              data.actions == 0 &&
              node.rect.width >= size.width &&
              node.rect.height >= size.height / 2;
        });
        expect(covering, findsNothing);
        handle.dispose();
      });
    });

    group('quality modes', () {
      testWidgets('opens the quality modes page', (tester) async {
        await pump(tester, category: SettingsCategory.engines);
        await tester.ensureVisible(find.text('Quality modes'));
        await tester.tap(find.text('Quality modes'));
        verify(
          () => router.push<Object?>(
            '/settings/quality',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('lives in the Translating section', (tester) async {
        await pump(tester, category: SettingsCategory.engines);
        expect(
          find.descendant(
            of: sectionOf('Translating'),
            matching: find.text('Quality modes'),
          ),
          findsOne,
        );
      });
    });

    group('history retention', () {
      Future<void> openPicker(WidgetTester tester) async {
        await tester.ensureVisible(find.text('Delete history automatically'));
        await tester.tap(find.text('Delete history automatically'));
        await tester.pumpAndSettle();
      }

      testWidgets('lives in the history section and shows the retention', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          state: const AppSettings(historyRetention: HistoryRetention.week),
        );
        expect(
          find.descendant(
            of: sectionOf('History'),
            matching: find.text('Delete history automatically'),
          ),
          findsOne,
        );
        expect(find.text('After 7 days'), findsOneWidget);
      });

      testWidgets('shows "Never" by default', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        expect(find.text('Never'), findsOneWidget);
      });

      testWidgets('picks a retention', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await openPicker(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            'Translations older than this are deleted from this device. '
            'Favorites are always kept.',
          ),
          findsOneWidget,
        );
        expect(find.text('After 1 day'), findsOneWidget);
        expect(find.text('After 7 days'), findsOneWidget);
        await tester.tap(find.text('After 30 days'));
        await tester.pumpAndSettle();
        // Choosing only moves the selection; Save confirms it.
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setHistoryRetention(any()));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setHistoryRetention(HistoryRetention.month))
            .called(1);
      });

      testWidgets('picking the current retention changes nothing', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          state: const AppSettings(historyRetention: HistoryRetention.day),
        );
        await openPicker(tester);
        await tester.tap(find.text('After 1 day').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(() => settings.setHistoryRetention(any()));
      });

      testWidgets('arrow keys move the choice without closing the dialog', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.privacy);
        await openPicker(tester);
        // Tab reaches the selected radio of the group.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setHistoryRetention(any()));

        // Tab to Save past Cancel and confirm.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(tester.element(find.text('Save'))).hasPrimaryFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setHistoryRetention(HistoryRetention.week))
            .called(1);
      });

      testWidgets('cancel keeps the retention', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        await openPicker(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.setHistoryRetention(any()));
      });

      group('when existing translations would be deleted', () {
        HistoryEntry entry(String id, Duration age, {bool favorite = false}) =>
            HistoryEntry(
              id: id,
              text: 'text $id',
              translation: 'translation $id',
              source: const Language(code: 'es', name: 'Spanish'),
              target: const Language(code: 'en', name: 'English'),
              engineId: 'mozhi:google',
              engineName: 'Google',
              createdAt: DateTime.now().subtract(age),
              isFavorite: favorite,
            );

        setUp(() {
          when(() => history.state).thenReturn(
            HistoryState(
              status: HistoryStatus.ready,
              entries: [
                entry('new', const Duration(hours: 1)),
                entry('old', const Duration(days: 3)),
                entry('older', const Duration(days: 40)),
                entry('starred', const Duration(days: 40), favorite: true),
              ],
            ),
          );
        });

        Future<void> pick(WidgetTester tester, String label) async {
          await openPicker(tester);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
        }

        testWidgets('asks before deleting them', (tester) async {
          await pump(tester, category: SettingsCategory.privacy);
          await pick(tester, 'After 1 day');

          verifyNever(() => settings.setHistoryRetention(any()));
          expect(find.text('Delete older translations now?'), findsOneWidget);
          expect(
            find.text(
              '2 translations are older than 1 day and will be deleted from '
              'this device right away. Favorites are kept.',
            ),
            findsOneWidget,
          );

          await tester.tap(
            find.byKey(const Key('settings_history_retention_confirm')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verify(() => settings.setHistoryRetention(HistoryRetention.day))
              .called(1);
        });

        testWidgets('counts only what the new retention deletes', (
          tester,
        ) async {
          await pump(tester, category: SettingsCategory.privacy);
          await pick(tester, 'After 30 days');

          expect(
            find.text(
              '1 translation is older than 30 days and will be deleted from '
              'this device right away. Favorites are kept.',
            ),
            findsOneWidget,
          );
        });

        testWidgets('keeps the retention when cancelled', (tester) async {
          await pump(tester, category: SettingsCategory.privacy);
          await pick(tester, 'After 7 days');
          expect(find.text('Delete older translations now?'), findsOneWidget);

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verifyNever(() => settings.setHistoryRetention(any()));
        });

        testWidgets('keeps the retention when dismissed', (tester) async {
          await pump(tester, category: SettingsCategory.privacy);
          await pick(tester, 'After 7 days');

          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verifyNever(() => settings.setHistoryRetention(any()));
        });

        testWidgets('does not ask when nothing would be deleted', (
          tester,
        ) async {
          await pump(
            tester,
            category: SettingsCategory.privacy,
            state: const AppSettings(historyRetention: HistoryRetention.week),
          );
          await pick(tester, 'Never');

          expect(find.byType(AlertDialog), findsNothing);
          verify(() => settings.setHistoryRetention(HistoryRetention.forever))
              .called(1);
        });
      });
    });

    group('recent language pairs', () {
      const pairs = [
        LanguagePair(
          source: Language.auto,
          target: Language(code: 'en', name: 'English'),
        ),
        LanguagePair(
          source: Language(code: 'fr', name: 'French'),
          target: Language(code: 'de', name: 'German'),
        ),
      ];

      testWidgets('is disabled without recent pairs', (tester) async {
        await pump(tester, category: SettingsCategory.privacy);
        expect(find.text('No recent language pairs'), findsOneWidget);
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pump();
        verifyNever(settings.clearRecentPairs);
      });

      testWidgets('clears the recent pairs and can undo it', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          state: const AppSettings(recentPairs: pairs),
        );
        expect(find.text('2 recent language pairs'), findsOneWidget);
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pumpAndSettle();
        verify(settings.clearRecentPairs).called(1);
        expect(find.text('Recent language pairs cleared'), findsOneWidget);

        // Dismissable without a pointer and without undoing.
        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.showCloseIcon, isTrue);

        await tester.tap(find.text('Undo'));
        await tester.pump();
        final change =
            verify(() => settings.update(captureAny())).captured.single
                as AppSettings Function(AppSettings);
        expect(change(const AppSettings()).recentPairs, pairs);
        // Pairs recorded in the meantime stay first.
        const newer = LanguagePair(
          source: Language(code: 'es', name: 'Spanish'),
          target: Language(code: 'en', name: 'English'),
        );
        expect(
          change(AppSettings(recentPairs: [newer, pairs.first])).recentPairs,
          [newer, ...pairs],
        );
      });

      testWidgets('the cleared notice closes without undoing', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          state: const AppSettings(recentPairs: pairs),
        );
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pumpAndSettle();
        // It waits for the user instead of timing out.
        await tester.pump(const Duration(minutes: 1));
        expect(find.text('Recent language pairs cleared'), findsOneWidget);

        final close = find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        );
        expect(close, findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('Recent language pairs cleared'), findsNothing);
        verifyNever(() => settings.update(any()));
      });
    });

    group('layout', () {
      testWidgets('shows the categories beside the selected one on wide '
          'screens', (tester) async {
        await pump(tester, size: const Size(1400, 1600));
        expect(find.byKey(SettingsView.columnsKey), findsOneWidget);
        // General is shown first, under its heading.
        final general = find.byKey(
          SettingsView.categoryKey(SettingsCategory.general),
        );
        expect(tester.widget<ListTile>(general).selected, isTrue);
        expect(find.text('Multiline input'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Multiline input')).dx,
          greaterThan(tester.getTopRight(general).dx),
        );

        // Picking a category changes the detail, not the location.
        await tester.tap(
          find.byKey(SettingsView.categoryKey(SettingsCategory.privacy)),
        );
        await tester.pumpAndSettle();
        verifyNever(
          () => router.push<Object?>(any(), extra: any(named: 'extra')),
        );
        expect(find.text('Incognito'), findsOneWidget);
        expect(find.text('Multiline input'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(Semantics),
            matching: find.text('Privacy & data'),
          ),
          findsNWidgets(2),
        );
        // The app bar still says Settings.
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Settings'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('a category page on a wide screen keeps the list beside '
          'it', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.appearance,
          size: const Size(1400, 1600),
        );
        expect(find.byKey(SettingsView.columnsKey), findsOneWidget);
        expect(
          tester
              .widget<ListTile>(
                find.byKey(
                  SettingsView.categoryKey(SettingsCategory.appearance),
                ),
              )
              .selected,
          isTrue,
        );
        expect(find.text('Dark theme'), findsOneWidget);
      });

      testWidgets('fits 320dp with large text', (tester) async {
        for (final category in [null, ...SettingsCategory.values]) {
          await pump(
            tester,
            state: const AppSettings(dynamicColor: false, providers: [_claude]),
            category: category,
            size: const Size(320, 640),
            textScale: 2,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$category');
        }
      });

      testWidgets('keyboard focus finishes the list first', (tester) async {
        await pump(tester, size: const Size(1400, 1600));
        final middle = tester
            .getTopRight(
              find.byKey(SettingsView.categoryKey(SettingsCategory.general)),
            )
            .dx;
        final columns = <int>[];
        FocusNode? first;
        for (var i = 0; i < 40; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final node = FocusManager.instance.primaryFocus!;
          if (node == first) break;
          first ??= node;
          columns.add(node.rect.center.dx < middle ? 0 : 1);
        }
        expect(columns, contains(0));
        expect(columns, contains(1));
        final switchIndex = columns.indexOf(1);
        expect(
          columns.sublist(switchIndex),
          everyElement(1),
          reason: 'focus went back to the list: $columns',
        );
      });

      testWidgets('renders in dark mode', (tester) async {
        when(() => settings.state).thenReturn(const AppSettings());
        tester.setScreenSize(const Size(800, 4000));
        await tester.pumpView(
          const SettingsPage(),
          settings: settings,
          history: history,
          router: router,
          theme: ThemeData(brightness: Brightness.dark),
        );
        expect(find.byType(SettingsView), findsOneWidget);
      });
    });

    group('search', () {
      Future<void> search(WidgetTester tester, String query) async {
        await tester.enterText(find.byKey(SettingsSearchField.fieldKey), query);
        await tester.pumpAndSettle();
      }

      testWidgets('filters every row by title and subtitle', (tester) async {
        await pump(tester);
        await search(tester, 'incog');
        expect(find.byKey(const Key('settings_result_incognito')), findsOne);
        // The categories make way for the results.
        expect(
          find.byKey(SettingsView.categoryKey(SettingsCategory.general)),
          findsNothing,
        );
        expect(find.text('1 setting found'), findsOneWidget);

        // A subtitle match shows the subtitle.
        await search(tester, 'vibrate');
        expect(
          find.byKey(const Key('settings_result_haptic_feedback')),
          findsOne,
        );
        expect(
          find.textContaining('Vibrate lightly', findRichText: true),
          findsOneWidget,
        );

        // Choices are found too, and every word must match.
        await search(tester, 'lights out');
        expect(find.byKey(const Key('settings_result_dark_look')), findsOne);
        await search(tester, 'offline first');
        expect(find.byKey(const Key('settings_result_privacy_mode')), findsOne);
      });

      testWidgets('says when nothing matches', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        await search(tester, 'zzz nothing');
        expect(find.text('No settings match “zzz nothing”.'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('No settings match “zzz nothing”.')),
          isSemantics(isLiveRegion: true),
        );
        handle.dispose();
      });

      testWidgets('clearing the search brings the categories back', (
        tester,
      ) async {
        await pump(tester);
        await search(tester, 'proxy');
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(SettingsView.categoryKey(SettingsCategory.general)),
          findsOne,
        );
      });

      testWidgets('highlights the match in the title', (tester) async {
        await pump(tester);
        await search(tester, 'proxy');
        final title = tester.widget<RichText>(
          find.descendant(
            of: find.byKey(const Key('settings_result_http_proxy')),
            matching: find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText() == 'HTTP proxy',
            ),
          ),
        );
        final spans = <TextSpan>[];
        title.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) spans.add(span);
          return true;
        });
        final match = spans.singleWhere((span) => span.text == 'proxy');
        expect(match.style?.fontWeight, FontWeight.w700);
        expect(match.style?.backgroundColor, isNotNull);
      });

      testWidgets('a result opens its category at the row', (tester) async {
        await pump(tester);
        await search(tester, 'proxy');
        await tester.tap(find.byKey(const Key('settings_result_http_proxy')));
        verifyPush('/settings/privacy?row=http_proxy');
        await search(tester, 'licenses');
        await tester.tap(find.byKey(const Key('settings_result_licenses')));
        verifyPush('/settings/about?row=licenses');
      });

      testWidgets('Enter opens the first result', (tester) async {
        await pump(tester);
        await search(tester, 'incognito');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        verifyPush('/settings/privacy?row=incognito');
        // Nothing to open without results.
        await search(tester, 'zzz');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        verifyNever(
          () => router.push<Object?>(any(), extra: any(named: 'extra')),
        );
      });

      testWidgets('on wide screens a result shows the row beside the list', (
        tester,
      ) async {
        await pump(tester, size: const Size(1400, 900));
        await search(tester, 'delete all');
        await tester.tap(
          find.byKey(const Key('settings_result_delete_all_data')),
        );
        await tester.pump();
        // The scroll animation starts on the next frame.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 400));
        verifyNever(
          () => router.push<Object?>(any(), extra: any(named: 'extra')),
        );
        // Scrolled into view and highlighted.
        final row = find.byKey(const Key('settings_delete_all_data'));
        expect(tester.getRect(row).bottom, lessThanOrEqualTo(900));
        final highlight = tester.widget<AnimatedContainer>(
          find.byKey(SettingsAnchor.highlightKey('delete_all_data')),
        );
        expect(
          (highlight.foregroundDecoration! as BoxDecoration).color?.a,
          greaterThan(0),
        );
        expect(
          tester
              .widget<ListTile>(
                find.byKey(const Key('settings_result_delete_all_data')),
              )
              .selected,
          isTrue,
        );
        // The highlight fades.
        await tester.pumpAndSettle(const Duration(seconds: 1));
        await tester.pump(SettingsAnchor.highlightDuration);
        await tester.pumpAndSettle();
        final faded = tester.widget<AnimatedContainer>(
          find.byKey(SettingsAnchor.highlightKey('delete_all_data')),
        );
        expect((faded.foregroundDecoration! as BoxDecoration).color?.a, 0);
        // The same result again jumps again.
        await tester.tap(
          find.byKey(const Key('settings_result_delete_all_data')),
        );
        await tester.pump();
        final again = tester.widget<AnimatedContainer>(
          find.byKey(SettingsAnchor.highlightKey('delete_all_data')),
        );
        expect(
          (again.foregroundDecoration! as BoxDecoration).color?.a,
          greaterThan(0),
        );
        await tester.pumpAndSettle(const Duration(seconds: 2));
      });

      testWidgets('a new row or category of the open page jumps again', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          highlight: 'incognito',
          size: const Size(1400, 900),
        );
        await pump(
          tester,
          category: SettingsCategory.engines,
          highlight: 'instant_translate',
          size: const Size(1400, 900),
        );
        await tester.pump();
        expect(
          tester
              .widget<ListTile>(
                find.byKey(SettingsView.categoryKey(SettingsCategory.engines)),
              )
              .selected,
          isTrue,
        );
        final highlight = tester.widget<AnimatedContainer>(
          find.byKey(SettingsAnchor.highlightKey('instant_translate')),
        );
        expect(
          (highlight.foregroundDecoration! as BoxDecoration).color?.a,
          greaterThan(0),
        );
        await tester.pump(SettingsAnchor.highlightDuration);
        await tester.pumpAndSettle();
      });

      testWidgets('the AI heading beside the list says advanced', (
        tester,
      ) async {
        await pump(
          tester,
          category: SettingsCategory.ai,
          size: const Size(1400, 900),
        );
        expect(find.text('Advanced'), findsNWidgets(2));
      });

      testWidgets('the index follows the platform and the services', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final voice = _MockSpeechInputService();
        when(() => voice.isPlatformSupported).thenReturn(true);
        late List<SettingsSearchEntry> entries;
        await tester.pumpView(
          RepositoryProvider<SpeechInputService>.value(
            value: voice,
            child: Builder(
              builder: (context) {
                entries = settingsSearchIndex(context, const AppSettings());
                return const SizedBox.shrink();
              },
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        final anchors = {for (final e in entries) e.anchor: e};
        expect(anchors['offline_languages']?.title, 'Offline languages');
        expect(anchors['voice_input']?.category, SettingsCategory.speech);
        expect(anchors, isNot(contains('read_aloud')));
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('a link with a row scrolls to it on a phone', (tester) async {
        await pump(
          tester,
          category: SettingsCategory.privacy,
          highlight: 'delete_all_data',
          size: const Size(412, 700),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const Key('settings_delete_all_data'));
        expect(tester.getRect(row).bottom, lessThanOrEqualTo(700));
        await tester.pump(SettingsAnchor.highlightDuration);
        await tester.pumpAndSettle();
      });

      testWidgets('every result names a row of its category', (tester) async {
        final speech = _MockSpeechService();
        when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
        when(() => speech.current).thenReturn(null);
        when(() => speech.deviceVoiceSupported).thenReturn(false);
        when(() => speech.preferDeviceVoice).thenReturn(false);
        when(speech.loadPreferDeviceVoice).thenAnswer((_) async => false);
        when(speech.loadSettings)
            .thenAnswer((_) async => const SpeechSettings());
        when(speech.stop).thenAnswer((_) async {});
        when(() => settings.state).thenReturn(
          const AppSettings(dynamicColor: false, providers: [_claude]),
        );
        tester.setScreenSize(const Size(800, 3000));
        late List<SettingsSearchEntry> entries;
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: Builder(
              builder: (context) {
                entries = settingsSearchIndex(context, settings.state);
                return const SizedBox.shrink();
              },
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        expect(entries.length, greaterThan(30));
        expect(
          entries.map((e) => '${e.category.name}/${e.anchor}').toSet(),
          hasLength(entries.length),
        );
        for (final category in SettingsCategory.values) {
          await tester.pumpView(
            RepositoryProvider<SpeechService>.value(
              value: speech,
              child: SettingsCategoryPage(category: category),
            ),
            settings: settings,
            history: history,
            router: router,
          );
          await tester.pump();
          for (final entry in entries.where((e) => e.category == category)) {
            expect(
              find.byKey(SettingsAnchor.highlightKey(entry.anchor)),
              findsOneWidget,
              reason: '${category.name}: ${entry.anchor}',
            );
            // The About page names the app instead of "About Mozhi".
            if (entry.anchor == 'version') continue;
            expect(
              find.textContaining(entry.title, findRichText: true),
              findsWidgets,
              reason: '${category.name}: ${entry.title}',
            );
          }
        }
      });
    });

    group('online engines', () {
      const deepl = AiProviderConfig(
        id: 'd1',
        name: 'DeepL',
        provider: LlmProvider.openAiCompatible,
        baseUrl: '',
        model: '',
        service: MtService.deepl,
      );

      testWidgets('counts machine translation services apart from AI', (
        tester,
      ) async {
        await pump(
          tester,
          state: const AppSettings(providers: [_claude, _local, deepl]),
          category: SettingsCategory.engines,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('settings_mt_services')),
            matching: find.text('1 of 1 enabled'),
          ),
          findsOneWidget,
        );
        await pump(tester, category: SettingsCategory.ai);
        expect(
          find.descendant(
            of: find.byKey(const Key('settings_ai_providers')),
            matching: find.text('1 of 2 enabled'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('explains the services when none is set up', (tester) async {
        await pump(
          tester,
          state: const AppSettings(),
          category: SettingsCategory.engines,
        );
        expect(
          find.text('DeepL or LibreTranslate with your own key or server'),
          findsOneWidget,
        );
      });

      testWidgets('the AI assistant offers AI providers only', (tester) async {
        await pump(
          tester,
          state: const AppSettings(providers: [_claude, deepl]),
          category: SettingsCategory.ai,
        );
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('DeepL'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Claude'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('with only machine translation services the assistant '
          'asks for an AI provider', (tester) async {
        await pump(
          tester,
          state: const AppSettings(providers: [deepl]),
          category: SettingsCategory.ai,
        );
        expect(
          find.text(
            'Add an AI provider for alternatives, insights and explanations',
          ),
          findsOneWidget,
        );
      });
    });

    group('about', () {
      late Future<bool> Function(Uri uri) launcher;
      final opened = <Uri>[];

      setUp(() {
        opened.clear();
        launcher = LinkLauncher.launcher;
        LinkLauncher.launcher = (uri) async {
          opened.add(uri);
          return true;
        };
        PackageInfo.setMockInitialValues(
          appName: 'Mozhi',
          packageName: 'io.github.aimdi.mozhi',
          version: '2.1.0',
          buildNumber: '42',
          buildSignature: '',
        );
      });

      tearDown(() => LinkLauncher.launcher = launcher);

      testWidgets('shows the version', (tester) async {
        await pump(tester, category: SettingsCategory.about);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('settings_version')),
            matching: find.text('Version 2.1.0 (42)'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows a version without a build number', (tester) async {
        PackageInfo.setMockInitialValues(
          appName: 'Mozhi',
          packageName: 'io.github.aimdi.mozhi',
          version: '2.1.0',
          buildNumber: '',
          buildSignature: '',
        );
        await pump(tester, category: SettingsCategory.about);
        await tester.pumpAndSettle();
        expect(find.text('Version 2.1.0'), findsOneWidget);
      });

      testWidgets('opens the source code', (tester) async {
        await pump(tester, category: SettingsCategory.about);
        await tester.tap(find.text('Source code'));
        await tester.pumpAndSettle();
        expect(opened, [AboutView.sourceCodeUrl]);
      });

      testWidgets('opens the licenses with the offline models notice', (
        tester,
      ) async {
        await pump(tester, category: SettingsCategory.about);
        expect(
          find.text(
            'Including the MPL-2.0 license of the offline translation '
            'models',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Open-source licenses'));
        await tester.pumpAndSettle();
        expect(find.byType(LicensePage), findsOneWidget);
      });

      testWidgets('describes the setup steps', (tester) async {
        await pump(tester, category: SettingsCategory.about);
        expect(
          find.text('Privacy, languages and an online service, step by step'),
          findsOneWidget,
        );
      });
    });

    group('accessibility', () {
      testWidgets('fits a 360dp phone at 200% text and meets the tap target '
          'guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        for (final category in [null, ...SettingsCategory.values]) {
          // Tall enough to show every row: rows cut by the edge of a
          // scrolled list would report clipped targets.
          await pump(
            tester,
            state: const AppSettings(
              dynamicColor: false,
              providers: [_claude],
              recentPairs: [
                LanguagePair(
                  source: Language.auto,
                  target: Language(code: 'en', name: 'English'),
                ),
              ],
              networkPairs: ['en>fr'],
              consentedProviders: ['p1'],
            ),
            category: category,
            size: const Size(360, 6000),
            textScale: 2,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$category');
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        }
        expect(find.text('Run setup again'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('meets the text contrast guideline', (tester) async {
        for (final category in [null, SettingsCategory.privacy]) {
          await pump(tester, category: category, size: const Size(800, 2000));
          await tester.pumpAndSettle();
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        }
        await pump(tester, size: const Size(800, 2000));
        await tester.enterText(find.byKey(SettingsSearchField.fieldKey), 'his');
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });

      testWidgets('the search field is a search box that respects '
          'incognito', (tester) async {
        await pump(tester, state: const AppSettings(incognito: true));
        final field = tester.widget<TextField>(
          find.byKey(SettingsSearchField.fieldKey),
        );
        expect(field.enableIMEPersonalizedLearning, isFalse);
        expect(
          find.ancestor(
            of: find.byKey(SettingsSearchField.fieldKey),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Semantics &&
                  w.properties.inputType == SemanticsInputType.search,
            ),
          ),
          findsOneWidget,
        );
      });
    });
  });
}
