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
const _pirate = Language.custom('Pirate speak');
const _instance = MozhiInstance(url: 'https://mozhi.example.org');

const _custom = AppSettings(
  themeMode: ThemeMode.dark,
  dynamicColor: false,
  pureBlack: true,
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
  instantTranslateAi: true,
  saveHistory: false,
  showTransliteration: false,
  recentLanguages: [_french, _pirate],
  pinnedLanguages: [_french],
  compareEngineIds: ['mozhi:google', 'ai:p1'],
  onboardingComplete: true,
);

void main() {
  group(AppSettings, () {
    test('has sensible defaults', () {
      const settings = AppSettings();

      expect(settings.themeMode, ThemeMode.system);
      expect(settings.dynamicColor, isTrue);
      expect(settings.pureBlack, isFalse);
      expect(settings.seedColor, 0xFF3F51B5);
      expect(settings.instances, MozhiInstance.publicInstances);
      expect(settings.providers, isEmpty);
      expect(settings.engineId, isNull);
      expect(settings.assistEngineId, isNull);
      expect(settings.source, Language.auto);
      expect(settings.target.code, 'en');
      expect(settings.options, const TranslationOptions());
      expect(settings.instantTranslate, isTrue);
      expect(settings.instantTranslateAi, isFalse);
      expect(settings.saveHistory, isTrue);
      expect(settings.showTransliteration, isTrue);
      expect(settings.recentLanguages, isEmpty);
      expect(settings.pinnedLanguages, isEmpty);
      expect(settings.compareEngineIds, isEmpty);
      expect(settings.onboardingComplete, isFalse);
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
        );

        expect(copy, equals(_custom));
      });

      test('can reset the nullable engine ids to null', () {
        final copy = _custom.copyWith(
          engineId: () => null,
          assistEngineId: () => null,
        );

        expect(copy.engineId, isNull);
        expect(copy.assistEngineId, isNull);
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
        });

        expect(settings, equals(const AppSettings()));
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
        });

        expect(settings.instances, [_instance]);
        expect(settings.providers.map((p) => p.id), ['p1']);
        expect(settings.recentLanguages, [_french]);
        expect(settings.pinnedLanguages, [_pirate]);
        expect(settings.compareEngineIds, ['mozhi:google', 'ai:p1']);
      });

      test('keeps an explicitly empty instance list', () {
        final settings = AppSettings.fromJson(const {'instances': <Object>[]});

        expect(settings.instances, isEmpty);
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
