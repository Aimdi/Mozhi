import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

/// Hy-MT2 on the device: translation only.
const hyMt = TranslationEngine(
  id: 'ai:device-hy-mt2',
  kind: EngineKind.ai,
  name: 'Hy-MT2 (on this device)',
  providerId: 'device-hy-mt2',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.hunyuanMt,
);

/// The on-device assistant model.
const deviceGemma = TranslationEngine(
  id: 'ai:device-gemma',
  kind: EngineKind.ai,
  name: 'Gemma 4 (on this device)',
  providerId: 'device-gemma',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.general,
);

const offline = TranslationEngine(
  id: TranslationEngine.offlineId,
  kind: EngineKind.offline,
  name: 'Offline',
  isLocal: true,
);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() => mocks = TranslateMocks());

  /// The assist engine after loading [engines] with [settings].
  Future<TranslationEngine?> assistFor(
    List<TranslationEngine> engines, {
    AppSettings settings = const AppSettings(),
  }) async {
    mocks.stubSettings(settings);
    when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => engines);
    final cubit = mocks.build();
    addTearDown(cubit.close);
    await cubit.loadEngines();
    return cubit.state.assistEngine;
  }

  group('assist engine', () {
    test('an AI main engine with extras is its own assist engine', () async {
      expect(
        await assistFor([
          claude,
          deviceGemma,
        ], settings: const AppSettings(engineId: 'ai:claude')),
        claude,
      );
    });

    test('Hy-MT2 on the device gets the on-device assistant', () async {
      expect(
        await assistFor(
          [claude, hyMt, deviceGemma],
          settings: const AppSettings(
            engineId: 'ai:device-hy-mt2',
            privacyMode: PrivacyMode.online,
          ),
        ),
        deviceGemma,
      );
    });

    test('the offline engine gets the on-device assistant before the first '
        'AI provider', () async {
      expect(
        await assistFor(
          [offline, claude, local, deviceGemma],
          settings: const AppSettings(
            engineId: TranslationEngine.offlineId,
            privacyMode: PrivacyMode.online,
          ),
        ),
        deviceGemma,
      );
    });

    test('unless the privacy mode is not online, a network main engine gets '
        'the first AI provider', () async {
      expect(
        await assistFor([
          google,
          claude,
          deviceGemma,
        ], settings: const AppSettings(privacyMode: PrivacyMode.online)),
        claude,
      );
      expect(
        await assistFor([
          google,
          claude,
          deviceGemma,
          // Offline-first by default.
        ]),
        deviceGemma,
      );
    });

    test('the configured assist engine wins, except a network one in '
        'Offline only', () async {
      expect(
        await assistFor(
          [offline, claude, deviceGemma],
          settings: const AppSettings(
            engineId: TranslationEngine.offlineId,
            assistEngineId: 'ai:claude',
          ),
        ),
        claude,
      );
      expect(
        await assistFor(
          [offline, claude, deviceGemma],
          settings: const AppSettings(
            engineId: TranslationEngine.offlineId,
            assistEngineId: 'ai:claude',
            privacyMode: PrivacyMode.offlineOnly,
          ),
        ),
        deviceGemma,
      );
      expect(
        await assistFor(
          [offline, claude, deviceGemma],
          settings: const AppSettings(
            engineId: TranslationEngine.offlineId,
            assistEngineId: 'ai:device-gemma',
            privacyMode: PrivacyMode.offlineOnly,
          ),
        ),
        deviceGemma,
      );
    });

    test('engines without extras are only the last resort', () async {
      // The configured one cannot do extras: the first that can.
      expect(
        await assistFor(
          [google, gemma, claude],
          settings: const AppSettings(
            assistEngineId: 'ai:gemma',
            privacyMode: PrivacyMode.online,
          ),
        ),
        claude,
      );
      // None can: as before, the configured, the main or the first one.
      expect(
        await assistFor([
          google,
          hyMt,
          gemma,
        ], settings: const AppSettings(assistEngineId: 'ai:gemma')),
        gemma,
      );
      expect(
        await assistFor([
          hyMt,
          gemma,
        ], settings: const AppSettings(engineId: 'ai:device-hy-mt2')),
        hyMt,
      );
      expect(await assistFor([google, gemma]), gemma);
      expect(await assistFor([google, deepl]), isNull);
    });

    test('asks the repository where the text goes', () async {
      // A local server the repository knows is on the device (not in
      // practice: but the repository decides, not the engine).
      when(() => mocks.repository.destinationOf(any()))
          .thenReturn(const SelfHostedDestination('localhost'));
      when(() => mocks.repository.destinationOf(local.id))
          .thenReturn(const OnDeviceDestination());
      expect(
        await assistFor([
          offline,
          claude,
          deviceGemma,
          local,
        ], settings: const AppSettings(engineId: TranslationEngine.offlineId)),
        local,
      );
    });
  });
}
