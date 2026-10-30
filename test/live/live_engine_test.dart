import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/live/live_engine.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

const _cloud = TranslationEngine(
  id: 'ai:cloud',
  kind: EngineKind.ai,
  name: 'Cloud AI',
  providerId: 'cloud',
);

const _phone = TranslationEngine(
  id: 'ai:phone',
  kind: EngineKind.ai,
  name: 'On this device',
  providerId: 'phone',
  isLocal: true,
  onDevice: true,
);

const _server = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);

const _lan = TranslationEngine(
  id: 'mt:lan',
  kind: EngineKind.mt,
  name: 'LibreTranslate',
  providerId: 'lan',
  isLocal: true,
);

void main() {
  final offline = TranslationEngine.offline();

  group('resolveLiveEngine', () {
    test('is the offline engine by default', () {
      expect(
        resolveLiveEngine(const AppSettings(), [_server, offline, _cloud]),
        offline,
      );
    });

    test('is the chosen engine while it is offered', () {
      expect(
        resolveLiveEngine(const AppSettings(liveEngineId: 'ai:cloud'), [
          offline,
          _cloud,
        ]),
        _cloud,
      );
    });

    test('falls back to the offline engine, never to another one, when the '
        'chosen engine is gone', () {
      expect(
        resolveLiveEngine(const AppSettings(liveEngineId: 'ai:gone'), [
          _server,
          _cloud,
        ]).id,
        TranslationEngine.offlineId,
      );
    });

    test('is the offline engine even when it is not offered', () {
      expect(
        resolveLiveEngine(const AppSettings(), const [_server]).id,
        TranslationEngine.offlineId,
      );
    });
  });

  group('liveEngineLeavesDevice', () {
    test('is false for the offline engine and on-device AI', () {
      expect(liveEngineLeavesDevice(offline), isFalse);
      expect(liveEngineLeavesDevice(_phone), isFalse);
    });

    test('is true for servers and providers, local network ones too', () {
      expect(liveEngineLeavesDevice(_server), isTrue);
      expect(liveEngineLeavesDevice(_cloud), isTrue);
      expect(liveEngineLeavesDevice(_lan), isTrue);
    });
  });
}
