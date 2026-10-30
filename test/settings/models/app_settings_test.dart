import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

const _provider = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
  apiKey: 'sk-secret',
);

const _french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const _german = Language(code: 'de', name: 'German');
const _pirate = Language.custom('Pirate speak');
const _instance = MozhiInstance(url: 'https://mozhi.example.org');

const _custom = AppSettings(
  themeMode: ThemeMode.dark,
  dynamicColor: false,
  pureBlack: false,
  seedColor: 0xFF009688,
  instances: [_instance],
  providers: [_provider],
  engineId: 'ai:p1',
  assistEngineId: 'ai:p1',
  source: _french,
  target: _pirate,
  options: TranslationOptions(
    formality: Formality.more,
    context: 'note to my landlord',
    glossary: {'flat': 'Wohnung'},
  ),
  instantTranslate: false,
  instantTranslateAi: false,
  saveHistory: false,
  showTransliteration: false,
  recentLanguages: [_french, _pirate],
  pinnedLanguages: [_french],
  compareEngineIds: ['mozhi:google', 'ai:p1'],
  onboardingComplete: true,
  historyRetention: HistoryRetention.week,
  fastEngineId: 'mozhi:google',
  bestEngineId: 'ai:p1',
  qualityMode: QualityMode.best,
  recentPairs: [
    LanguagePair(source: Language.auto, target: _french),
    LanguagePair(source: _french, target: _pirate),
  ],
  extraTargets: [_german, _pirate],
  privacyMode: PrivacyMode.offlineOnly,
  networkPairs: ['de>en', 'auto>fr'],
  consentedProviders: ['p1'],
  incognito: true,
  secureScreen: true,
  httpProxy: '127.0.0.1:8118',
  appLocale: 'de',
  hapticFeedback: false,
  tabOrder: [
    AppTab.dictionary,
    AppTab.translate,
    AppTab.conversation,
    AppTab.proofread,
  ],
  rememberQuality: false,
  multilineInput: false,
  maskPersonalData: false,
  modelSource: ModelSource(
    kind: ModelSourceKind.custom,
    customUrl: 'https://mirror.example/models/',
    fallbackToDefault: true,
  ),
  liveEngineId: 'ai:p1',
  tapToLookUp: false,
  highlightSpokenWord: false,
  offlineAppShell: false,
);

void main() {
  group(AppSettings, () {
    test('has sensible defaults', () {
      const settings = AppSettings();

      expect(settings.themeMode, ThemeMode.system);
      expect(settings.dynamicColor, isTrue);
      // Lights out (true black) is the default dark look.
      expect(settings.pureBlack, isTrue);
      expect(settings.seedColor, 0xFF1D9BF0);
      expect(settings.instances, MozhiInstance.publicInstances);
      expect(settings.providers, isEmpty);
      expect(settings.engineId, isNull);
      expect(settings.assistEngineId, isNull);
      expect(settings.source, Language.auto);
      expect(settings.target.code, 'en');
      expect(settings.options, const TranslationOptions());
      expect(settings.instantTranslate, isTrue);
      // Automatic for every online engine, like Kagi.
      expect(settings.instantTranslateAi, isTrue);
      expect(settings.saveHistory, isTrue);
      expect(settings.showTransliteration, isTrue);
      expect(settings.recentLanguages, isEmpty);
      expect(settings.pinnedLanguages, isEmpty);
      expect(settings.compareEngineIds, isEmpty);
      expect(settings.onboardingComplete, isFalse);
      expect(settings.historyRetention, HistoryRetention.forever);
      expect(settings.fastEngineId, isNull);
      expect(settings.bestEngineId, isNull);
      expect(settings.qualityMode, QualityMode.off);
      expect(settings.recentPairs, isEmpty);
      expect(settings.extraTargets, isEmpty);
      expect(settings.privacyMode, PrivacyMode.offlineFirst);
      expect(settings.networkPairs, isEmpty);
      expect(settings.consentedProviders, isEmpty);
      expect(settings.incognito, isFalse);
      expect(settings.secureScreen, isFalse);
      expect(settings.httpProxy, isNull);
      // System default, like the app before the setting existed.
      expect(settings.appLocale, isNull);
      expect(settings.hapticFeedback, isTrue);
      expect(settings.tabOrder, AppTab.values);
      expect(settings.tabOrder.first, AppTab.translate);
      // On: the quality mode was always remembered before.
      expect(settings.rememberQuality, isTrue);
      // Enter adds a new line, as before.
      expect(settings.multilineInput, isTrue);
      // Personal data is kept on the device unless the user says otherwise.
      expect(settings.maskPersonalData, isTrue);
      // The original publishers, outside a browser.
      expect(settings.modelSource, ModelSource.platformDefault);
      // The live features stay on the device unless the user picks more.
      expect(settings.liveEngineId, isNull);
      expect(settings.tapToLookUp, isTrue);
      expect(settings.highlightSpokenWord, isTrue);
      expect(settings.offlineAppShell, isTrue);
    });

    test('supports value equality', () {
      expect(const AppSettings(), equals(const AppSettings()));
      expect(_custom, isNot(equals(const AppSettings())));
    });

    test('compares instance labels, not just urls', () {
      const labelled = AppSettings(
        instances: [
          MozhiInstance(url: 'https://mozhi.example.org', label: 'A'),
        ],
      );

      expect(
        labelled,
        isNot(equals(const AppSettings(instances: [_instance]))),
      );
    });

    group(AppTab, () {
      test('reads a tab by its id', () {
        for (final tab in AppTab.values) {
          expect(AppTab.fromId(tab.name), tab);
        }
        expect(AppTab.fromId('history'), isNull);
        expect(AppTab.fromId(0), isNull);
        expect(AppTab.fromId(null), isNull);
      });

      test('keeps the branch order of the router', () {
        expect(AppTab.values.map((tab) => tab.name), [
          'translate',
          'dictionary',
          'proofread',
          'conversation',
        ]);
      });
    });

    group('normalizeTabOrder', () {
      test('keeps a complete order', () {
        const order = [
          AppTab.conversation,
          AppTab.proofread,
          AppTab.dictionary,
          AppTab.translate,
        ];
        expect(AppSettings.normalizeTabOrder(order), order);
      });

      test('drops duplicates and adds the missing tabs in default order', () {
        expect(
          AppSettings.normalizeTabOrder(const [
            AppTab.proofread,
            AppTab.proofread,
            AppTab.conversation,
          ]),
          [
            AppTab.proofread,
            AppTab.conversation,
            AppTab.translate,
            AppTab.dictionary,
          ],
        );
        expect(AppSettings.normalizeTabOrder(const []), AppTab.values);
      });

      test('is unmodifiable', () {
        expect(
          () =>
              AppSettings.normalizeTabOrder(AppTab.values)
                  .add(AppTab.translate),
          throwsUnsupportedError,
        );
      });
    });

    group('atLaunch', () {
      test('keeps the quality mode when it is remembered', () {
        const settings = AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:p1',
          qualityMode: QualityMode.best,
        );

        expect(settings.atLaunch(), same(settings));
      });

      test('starts in Fast when it is set up and not remembered', () {
        const settings = AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:p1',
          qualityMode: QualityMode.best,
          rememberQuality: false,
        );

        expect(settings.launchQualityMode, QualityMode.fast);
        expect(
          settings.atLaunch(),
          settings.copyWith(qualityMode: QualityMode.fast),
        );
        // Also after the usual engine was used.
        expect(
          settings
              .copyWith(qualityMode: QualityMode.off)
              .atLaunch()
              .qualityMode,
          QualityMode.fast,
        );
      });

      test('starts with the usual engine without a Fast engine', () {
        const settings = AppSettings(
          bestEngineId: 'ai:p1',
          qualityMode: QualityMode.best,
          rememberQuality: false,
        );

        expect(settings.launchQualityMode, QualityMode.off);
        expect(settings.atLaunch().qualityMode, QualityMode.off);
        expect(settings.atLaunch().bestEngineId, 'ai:p1');
      });

      test('changes nothing when already in the launch mode', () {
        const settings = AppSettings(rememberQuality: false);

        expect(settings.atLaunch(), same(settings));
      });
    });

    group('normalizeExtraTargets', () {
      test('keeps valid languages in order', () {
        expect(
          AppSettings.normalizeExtraTargets(const [_pirate, _german, _french]),
          [_pirate, _german, _french],
        );
      });

      test('drops auto, empty codes and duplicates', () {
        expect(
          AppSettings.normalizeExtraTargets(const [
            Language.auto,
            _german,
            Language(code: '', name: 'Nothing'),
            Language(code: 'de', name: 'Deutsch'),
            _french,
          ]),
          [_german, _french],
        );
      });

      test('keeps at most maxExtraTargets', () {
        final languages = [
          for (var i = 0; i < 6; i++) Language(code: 'l$i', name: 'L$i'),
        ];
        expect(
          AppSettings.normalizeExtraTargets(languages),
          languages.take(AppSettings.maxExtraTargets),
        );
        expect(AppSettings.maxExtraTargets, 4);
      });
    });

    group(HistoryRetention, () {
      test('maps to the maximum age of history entries', () {
        expect(HistoryRetention.forever.maxAge, isNull);
        expect(HistoryRetention.day.maxAge, const Duration(days: 1));
        expect(HistoryRetention.week.maxAge, const Duration(days: 7));
        expect(HistoryRetention.month.maxAge, const Duration(days: 30));
      });
    });

    group('copyWith', () {
      test('returns an equal object when nothing is passed', () {
        expect(_custom.copyWith(), equals(_custom));
      });

      test('replaces every given field', () {
        final copy = const AppSettings().copyWith(
          themeMode: _custom.themeMode,
          dynamicColor: _custom.dynamicColor,
          pureBlack: _custom.pureBlack,
          seedColor: _custom.seedColor,
          instances: _custom.instances,
          providers: _custom.providers,
          engineId: () => _custom.engineId,
          assistEngineId: () => _custom.assistEngineId,
          source: _custom.source,
          target: _custom.target,
          options: _custom.options,
          instantTranslate: _custom.instantTranslate,
          instantTranslateAi: _custom.instantTranslateAi,
          saveHistory: _custom.saveHistory,
          showTransliteration: _custom.showTransliteration,
          recentLanguages: _custom.recentLanguages,
          pinnedLanguages: _custom.pinnedLanguages,
          compareEngineIds: _custom.compareEngineIds,
          onboardingComplete: _custom.onboardingComplete,
          historyRetention: _custom.historyRetention,
          fastEngineId: () => _custom.fastEngineId,
          bestEngineId: () => _custom.bestEngineId,
          qualityMode: _custom.qualityMode,
          recentPairs: _custom.recentPairs,
          extraTargets: _custom.extraTargets,
          privacyMode: _custom.privacyMode,
          networkPairs: _custom.networkPairs,
          consentedProviders: _custom.consentedProviders,
          incognito: _custom.incognito,
          secureScreen: _custom.secureScreen,
          httpProxy: () => _custom.httpProxy,
          appLocale: () => _custom.appLocale,
          hapticFeedback: _custom.hapticFeedback,
          tabOrder: _custom.tabOrder,
          rememberQuality: _custom.rememberQuality,
          multilineInput: _custom.multilineInput,
          maskPersonalData: _custom.maskPersonalData,
          modelSource: _custom.modelSource,
          liveEngineId: () => _custom.liveEngineId,
          tapToLookUp: _custom.tapToLookUp,
          highlightSpokenWord: _custom.highlightSpokenWord,
          offlineAppShell: _custom.offlineAppShell,
        );

        expect(copy, equals(_custom));
      });

      test('can reset the nullable engine ids to null', () {
        final copy = _custom.copyWith(
          engineId: () => null,
          assistEngineId: () => null,
          fastEngineId: () => null,
          bestEngineId: () => null,
          liveEngineId: () => null,
        );

        expect(copy.liveEngineId, isNull);
        expect(copy.engineId, isNull);
        expect(copy.assistEngineId, isNull);
        expect(copy.fastEngineId, isNull);
        expect(copy.bestEngineId, isNull);
        expect(_custom.copyWith(httpProxy: () => null).httpProxy, isNull);
        expect(_custom.copyWith(appLocale: () => null).appLocale, isNull);
      });

      test('keeps the quality engine ids when not given', () {
        final copy = _custom.copyWith(engineId: () => null);

        expect(copy.fastEngineId, 'mozhi:google');
        expect(copy.bestEngineId, 'ai:p1');
      });
    });

    group('toJson', () {
      test('is versioned and stores the theme mode by name', () {
        final json = _custom.toJson();

        expect(json['version'], AppSettings.schemaVersion);
        expect(json['themeMode'], 'dark');
      });

      test('never contains API keys', () {
        final json = _custom.toJson();
        final providers = json['providers'] as List<dynamic>;

        expect(providers.single, isNot(contains('apiKey')));
        expect(jsonEncode(json), isNot(contains('sk-secret')));
      });

      test('never contains custom headers or instance credentials', () {
        final json = _custom
            .copyWith(
              providers: [
                _provider.copyWith(headers: {'Authorization': 'Bearer hdr'}),
              ],
              instances: const [
                MozhiInstance(
                  url: 'https://me:pw@mozhi.example.org',
                  label: 'L',
                ),
              ],
            )
            .toJson();

        final encoded = jsonEncode(json);
        expect(encoded, isNot(contains('hdr')));
        expect(encoded, isNot(contains('me:pw')));
        expect(json['instances'], [
          {'url': 'https://mozhi.example.org', 'label': 'L', 'isCustom': true},
        ]);
      });

      test('does not persist one-off instructions', () {
        final settings = _custom.copyWith(
          options: const TranslationOptions(instructions: 'Make it shorter'),
        );

        final options = settings.toJson()['options'] as Map<String, dynamic>;

        expect(options, isNot(contains('instructions')));
      });

      test('omits unset engine ids as null', () {
        final json = const AppSettings().toJson();

        expect(json['engineId'], isNull);
        expect(json['assistEngineId'], isNull);
        expect(json['fastEngineId'], isNull);
        expect(json['bestEngineId'], isNull);
      });

      test('stores the retention and quality mode by name', () {
        final json = _custom.toJson();

        expect(json['historyRetention'], 'week');
        expect(json['qualityMode'], 'best');
        expect(json['fastEngineId'], 'mozhi:google');
        expect(json['bestEngineId'], 'ai:p1');
      });

      test('stores the general settings', () {
        final json = _custom.toJson();

        expect(json['appLocale'], 'de');
        expect(json['hapticFeedback'], false);
        expect(json['tabOrder'], [
          'dictionary',
          'translate',
          'conversation',
          'proofread',
        ]);
        expect(json['rememberQuality'], false);
        expect(json['multilineInput'], false);
        final defaults = const AppSettings().toJson();
        expect(defaults['appLocale'], isNull);
        expect(defaults['tabOrder'], [
          'translate',
          'dictionary',
          'proofread',
          'conversation',
        ]);
      });

      test('stores the extra targets in order', () {
        final json = _custom.toJson();

        expect(json['extraTargets'], [_german.toJson(), _pirate.toJson()]);
      });

      test('stores the recent pairs in order', () {
        final json = _custom.toJson();

        expect(json['recentPairs'], [
          {'source': Language.auto.toJson(), 'target': _french.toJson()},
          {'source': _french.toJson(), 'target': _pirate.toJson()},
        ]);
      });
    });

    group('fromJson', () {
      test('round-trips through JSON (without API keys)', () {
        final json =
            jsonDecode(jsonEncode(_custom.toJson())) as Map<String, dynamic>;

        final restored = AppSettings.fromJson(json);

        expect(
          restored,
          equals(
            _custom.copyWith(
              providers: [_provider.copyWith(clearApiKey: true)],
            ),
          ),
        );
      });

      test('falls back to defaults for an empty object', () {
        expect(AppSettings.fromJson(const {}), equals(const AppSettings()));
      });

      test('keeps a stored dark look; Lights out when none is stored', () {
        expect(
          AppSettings.fromJson(const {'pureBlack': false}).pureBlack,
          isFalse,
        );
        expect(
          AppSettings.fromJson(const {'pureBlack': true}).pureBlack,
          isTrue,
        );
        expect(AppSettings.fromJson(const {}).pureBlack, isTrue);
        expect(
          const AppSettings(pureBlack: false).toJson()['pureBlack'],
          false,
        );
      });

      test('falls back to defaults for fields of the wrong type', () {
        final settings = AppSettings.fromJson(const {
          'themeMode': 'sepia',
          'dynamicColor': 'yes',
          'pureBlack': 1,
          'seedColor': 'blue',
          'instances': 'none',
          'providers': {'id': 'p1'},
          'engineId': 42,
          'assistEngineId': '',
          'source': 'fr',
          'target': ['en'],
          'options': 'formal',
          'instantTranslate': null,
          'instantTranslateAi': 'true',
          'saveHistory': 0,
          'showTransliteration': 'no',
          'recentLanguages': 'fr',
          'pinnedLanguages': false,
          'compareEngineIds': 'all',
          'onboardingComplete': 'done',
          'historyRetention': 'year',
          'fastEngineId': 7,
          'bestEngineId': '',
          'qualityMode': true,
          'recentPairs': {'source': 'fr'},
          'extraTargets': 'fr',
          'privacyMode': 'paranoid',
          'networkPairs': 'de>en',
          'consentedProviders': {'p1': true},
          'incognito': 'yes',
          'secureScreen': 1,
          'httpProxy': '',
          'appLocale': 7,
          'hapticFeedback': 'off',
          'tabOrder': 'translate',
          'rememberQuality': 0,
          'multilineInput': 'no',
          'maskPersonalData': 'off',
          'modelSource': 'mirror',
          'liveEngineId': 3,
          'tapToLookUp': 'yes',
          'highlightSpokenWord': 1,
          'offlineAppShell': 'on',
        });

        expect(settings, equals(const AppSettings()));
      });

      test('loads settings stored before retention, quality modes, '
          'recent pairs and extra targets existed', () {
        final json = _custom.toJson()
          ..remove('historyRetention')
          ..remove('fastEngineId')
          ..remove('bestEngineId')
          ..remove('qualityMode')
          ..remove('recentPairs')
          ..remove('extraTargets');

        final settings = AppSettings.fromJson(json);

        expect(settings.historyRetention, HistoryRetention.forever);
        expect(settings.fastEngineId, isNull);
        expect(settings.bestEngineId, isNull);
        expect(settings.qualityMode, QualityMode.off);
        expect(settings.recentPairs, isEmpty);
        expect(settings.extraTargets, isEmpty);
        expect(settings.engineId, 'ai:p1');
      });

      test('loads settings stored before the live features existed', () {
        final json = _custom.toJson()
          ..remove('liveEngineId')
          ..remove('tapToLookUp')
          ..remove('highlightSpokenWord')
          ..remove('offlineAppShell');

        final settings = AppSettings.fromJson(json);

        expect(settings.liveEngineId, isNull);
        expect(settings.tapToLookUp, isTrue);
        expect(settings.highlightSpokenWord, isTrue);
        expect(settings.offlineAppShell, isTrue);
        final stored = AppSettings.fromJson(_custom.toJson());
        expect(stored.liveEngineId, 'ai:p1');
        expect(stored.tapToLookUp, isFalse);
        expect(stored.highlightSpokenWord, isFalse);
        expect(stored.offlineAppShell, isFalse);
      });

      test('loads settings stored before the model source existed', () {
        final json = _custom.toJson()..remove('modelSource');
        expect(
          AppSettings.fromJson(json).modelSource,
          ModelSource.platformDefault,
        );
        expect(
          AppSettings.fromJson(_custom.toJson()).modelSource,
          _custom.modelSource,
        );
      });

      test('loads settings stored before the general settings existed', () {
        final json = _custom.toJson()
          ..remove('appLocale')
          ..remove('hapticFeedback')
          ..remove('tabOrder')
          ..remove('rememberQuality')
          ..remove('multilineInput');

        final settings = AppSettings.fromJson(json);

        expect(settings.appLocale, isNull);
        expect(settings.hapticFeedback, isTrue);
        expect(settings.tabOrder, AppTab.values);
        expect(settings.rememberQuality, isTrue);
        expect(settings.multilineInput, isTrue);
        // Everything else as stored.
        expect(
          settings,
          _custom.copyWith(
            providers: [_provider.copyWith(clearApiKey: true)],
            appLocale: () => null,
            hapticFeedback: true,
            tabOrder: AppTab.values,
            rememberQuality: true,
            multilineInput: true,
          ),
        );
      });

      test('reads a tab order, completing it and skipping unknown ids', () {
        final settings = AppSettings.fromJson(const {
          'tabOrder': [
            'proofread',
            'history',
            3,
            null,
            'proofread',
            'dictionary',
          ],
        });

        expect(settings.tabOrder, [
          AppTab.proofread,
          AppTab.dictionary,
          AppTab.translate,
          AppTab.conversation,
        ]);
        expect(
          () => settings.tabOrder.add(AppTab.translate),
          throwsUnsupportedError,
        );
        expect(
          AppSettings.fromJson(const {'tabOrder': <Object>[]}).tabOrder,
          AppTab.values,
        );
      });

      test('keeps an app language the app may not know (yet)', () {
        expect(AppSettings.fromJson(const {'appLocale': 'sv'}).appLocale, 'sv');
        expect(AppSettings.fromJson(const {'appLocale': ''}).appLocale, isNull);
      });

      test('reads the privacy fields, skipping invalid and duplicate '
          'list elements', () {
        final settings = AppSettings.fromJson(const {
          'privacyMode': 'online',
          'networkPairs': ['de>en', 3, '', 'de>en', 'fr>es'],
          'consentedProviders': ['p1', null, 'p1'],
          'incognito': true,
          'secureScreen': false,
          'httpProxy': 'proxy.lan:3128',
        });

        expect(settings.privacyMode, PrivacyMode.online);
        expect(settings.networkPairs, ['de>en', 'fr>es']);
        expect(settings.consentedProviders, ['p1']);
        expect(settings.incognito, isTrue);
        expect(settings.secureScreen, isFalse);
        expect(settings.httpProxy, 'proxy.lan:3128');
        expect(() => settings.networkPairs.add('x'), throwsUnsupportedError);
      });

      test('reads every retention and quality mode by name', () {
        for (final retention in HistoryRetention.values) {
          final settings = AppSettings.fromJson({
            'historyRetention': retention.name,
          });
          expect(settings.historyRetention, retention);
        }
        for (final mode in QualityMode.values) {
          final settings = AppSettings.fromJson({'qualityMode': mode.name});
          expect(settings.qualityMode, mode);
        }
      });

      test('skips invalid list elements', () {
        final settings = AppSettings.fromJson({
          'instances': [
            _instance.toJson(),
            const {'label': 'no url'},
            'https://bad.example',
          ],
          'providers': [
            const {'name': 'missing id'},
            _provider.toJson(),
          ],
          'recentLanguages': [
            const {'code': 'fr'},
            _french.toJson(),
            null,
          ],
          'pinnedLanguages': [_pirate.toJson(), 7],
          'compareEngineIds': const ['mozhi:google', 3, null, 'ai:p1'],
          'recentPairs': [
            {'source': _french.toJson()},
            const {'source': 'fr', 'target': 'de'},
            const LanguagePair(source: _french, target: _pirate).toJson(),
            'fr-de',
          ],
        });

        expect(settings.instances, [_instance]);
        expect(settings.providers.map((p) => p.id), ['p1']);
        expect(settings.recentLanguages, [_french]);
        expect(settings.pinnedLanguages, [_pirate]);
        expect(settings.compareEngineIds, ['mozhi:google', 'ai:p1']);
        expect(settings.recentPairs, [
          const LanguagePair(source: _french, target: _pirate),
        ]);
      });

      test('reads at most four extra targets, without auto, invalid '
          'elements and duplicates', () {
        const languages = [
          Language(code: 'es', name: 'Spanish'),
          Language(code: 'it', name: 'Italian'),
          Language(code: 'ja', name: 'Japanese'),
        ];
        final settings = AppSettings.fromJson({
          'extraTargets': [
            Language.auto.toJson(),
            _german.toJson(),
            const {'code': 'fr'},
            const {'code': ' ', 'name': 'Blank'},
            'es',
            null,
            _german.toJson(),
            _pirate.toJson(),
            for (final language in languages) language.toJson(),
          ],
        });

        expect(settings.extraTargets, [_german, _pirate, ...languages.take(2)]);
        expect(
          () => settings.extraTargets.add(_german),
          throwsUnsupportedError,
        );
      });

      test('keeps an explicitly empty instance list', () {
        final settings = AppSettings.fromJson(const {'instances': <Object>[]});

        expect(settings.instances, isEmpty);
      });

      group('migrates the built-in instance list', () {
        // As written by versions up to October 2026.
        final oldDefaults = [
          for (final url in MozhiInstance.previousDefaultOrders.first)
            {'url': url, 'label': url, 'isCustom': false},
        ];
        final newOrder = [
          for (final instance in MozhiInstance.publicInstances) instance.url,
        ];
        List<String> urlsOf(AppSettings settings) => [
          for (final instance in settings.instances) instance.url,
        ];

        test('an old default order becomes the new one', () {
          final settings = AppSettings.fromJson({'instances': oldDefaults});

          expect(urlsOf(settings), newOrder);
          expect(settings.instances, MozhiInstance.publicInstances);
          // And stays so after a save.
          expect(
            urlsOf(
              AppSettings.fromJson(
                jsonDecode(jsonEncode(settings)) as Map<String, dynamic>,
              ),
            ),
            newOrder,
          );
        });

        test('keeps the user own order without the retired servers', () {
          final reordered = [...oldDefaults.reversed];
          final settings = AppSettings.fromJson({'instances': reordered});

          expect(urlsOf(settings), [
            for (final url
                in MozhiInstance.previousDefaultOrders.first.reversed)
              if (!MozhiInstance.retiredUrls.contains(url)) url,
          ]);
        });

        test('keeps custom instances', () {
          final settings = AppSettings.fromJson({
            'instances': [
              _instance.toJson(),
              ...oldDefaults,
              const {'url': 'https://mozhi.bloat.cat'},
            ],
          });

          expect(urlsOf(settings), [
            _instance.url,
            ...newOrder,
            'https://mozhi.bloat.cat',
          ]);
          expect(settings.instances.first.isCustom, isTrue);
          expect(settings.instances.last.isCustom, isTrue);
        });

        test('a list of retired servers only becomes empty', () {
          final settings = AppSettings.fromJson(const {
            'instances': [
              {'url': 'https://translate.nerdvpn.de', 'isCustom': false},
            ],
          });

          expect(settings.instances, isEmpty);
        });
      });

      test('accepts a floating point seed colour', () {
        final settings = AppSettings.fromJson(const {
          'seedColor': 4278228616.0,
        });

        expect(settings.seedColor, 4278228616);
      });

      test('accepts nested maps that are not Map<String, dynamic>', () {
        final settings = AppSettings.fromJson(const <String, dynamic>{
          'source': <Object?, Object?>{'code': 'de', 'name': 'German'},
        });

        expect(settings.source, const Language(code: 'de', name: 'German'));
      });

      test('reads every theme mode by name', () {
        for (final mode in ThemeMode.values) {
          final settings = AppSettings.fromJson({'themeMode': mode.name});
          expect(settings.themeMode, mode);
        }
      });
    });
  });
}
