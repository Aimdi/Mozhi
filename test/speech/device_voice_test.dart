import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/speech/device_voice.dart';

void main() {
  group(DeviceVoice, () {
    const amelie = DeviceVoice(
      name: 'Amélie',
      locale: 'fr-CA',
      identifier: 'com.apple.voice.Amelie',
      quality: 'enhanced',
    );

    group('fromEngine', () {
      test('reads the flutter_tts voice map', () {
        expect(
          DeviceVoice.fromEngine({
            'name': ' Amélie ',
            'locale': 'fr-CA',
            'identifier': 'com.apple.voice.Amelie',
            'quality': 'enhanced',
            'gender': 'female',
          }),
          amelie,
        );
      });

      test('reads Android network voices', () {
        final voice = DeviceVoice.fromEngine({
          'name': 'fr-fr-x-frc-network',
          'locale': 'fr-FR',
          'quality': 'very high',
          'latency': 'normal',
          'network_required': '1',
          'features': 'networkTimeoutMs\tnetworkRetriesCount',
        });

        expect(voice?.networkRequired, isTrue);
        expect(voice?.isHighQuality, isTrue);
        expect(voice?.identifier, isNull);
      });

      test('skips voices that are not installed', () {
        expect(
          DeviceVoice.fromEngine({
            'name': 'fr-fr-x-frd-local',
            'locale': 'fr-FR',
            'features': 'embeddedTts\tnotInstalled',
          }),
          isNull,
        );
      });

      test('skips entries without a name or locale', () {
        expect(DeviceVoice.fromEngine('Amélie'), isNull);
        expect(DeviceVoice.fromEngine({'name': 'Amélie'}), isNull);
        expect(DeviceVoice.fromEngine({'locale': 'fr-CA'}), isNull);
        expect(DeviceVoice.fromEngine({'name': ' ', 'locale': 'fr'}), isNull);
        expect(DeviceVoice.fromEngine({'name': 1, 'locale': 'fr'}), isNull);
      });
    });

    group('engine names', () {
      const frb = DeviceVoice(name: 'fr-fr-x-frb-local', locale: 'fr-FR');
      const frd = DeviceVoice(name: 'fr-fr-x-frd-local', locale: 'fr-FR');
      const frdOnline = DeviceVoice(
        name: 'fr-fr-x-frd-network',
        locale: 'fr-FR',
        networkRequired: true,
      );
      const canadian = DeviceVoice(name: 'fr-ca-x-caa-local', locale: 'fr-CA');

      test('recognises technical engine ids', () {
        for (final voice in [
          frd,
          frdOnline,
          const DeviceVoice(name: 'cmn-cn-x-ccc-local', locale: 'zh-CN'),
          const DeviceVoice(name: 'fr-FR-language', locale: 'fr-FR'),
          const DeviceVoice(name: 'en-US-SMTf00', locale: 'en_US'),
        ]) {
          expect(voice.hasEngineName, isTrue, reason: voice.name);
        }
      });

      test('leaves names meant for people alone', () {
        for (final voice in [
          amelie,
          const DeviceVoice(name: 'Google français', locale: 'fr-FR'),
          const DeviceVoice(
            name: 'Microsoft Hortense - French (France)',
            locale: 'fr-FR',
          ),
          const DeviceVoice(name: 'fr-FR Voice 1', locale: 'fr-FR'),
        ]) {
          expect(voice.hasEngineName, isFalse, reason: voice.name);
          expect(voice.engineVariant, isNull);
          expect(voice.numberAmong([voice]), isNull);
        }
      });

      test('extracts the variant', () {
        expect(frd.engineVariant, 'frd');
        expect(
          const DeviceVoice(
            name: 'cmn-cn-x-ccc-network',
            locale: 'zh-CN',
          ).engineVariant,
          'ccc',
        );
        expect(
          const DeviceVoice(
            name: 'en-US-SMTf00',
            locale: 'en-US',
          ).engineVariant,
          'smtf00',
        );
        expect(
          const DeviceVoice(
            name: 'fr-FR-language',
            locale: 'fr-FR',
          ).engineVariant,
          'language',
        );
      });

      test('numbers voices per locale by name', () {
        final listed = [frdOnline, amelie, canadian, frd, frb];

        expect(frb.numberAmong(listed), 1);
        expect(frd.numberAmong(listed), 2);
        expect(frdOnline.numberAmong(listed), 3);
        expect(canadian.numberAmong(listed), 1);
      });

      test('has no number when it is not listed', () {
        expect(frd.numberAmong([frb]), isNull);
        expect(frd.numberAmong(const []), isNull);
      });
    });

    group('JSON', () {
      test('round-trips', () {
        const network = DeviceVoice(
          name: 'fr-fr-x-frc-network',
          locale: 'fr-FR',
          networkRequired: true,
        );

        expect(DeviceVoice.tryParse(amelie.toJson()), amelie);
        expect(DeviceVoice.tryParse(network.toJson()), network);
      });

      test('omits empty fields', () {
        expect(const DeviceVoice(name: 'Thomas', locale: 'fr-FR').toJson(), {
          'name': 'Thomas',
          'locale': 'fr-FR',
        });
      });

      test('rejects invalid values', () {
        expect(DeviceVoice.tryParse(null), isNull);
        expect(DeviceVoice.tryParse({'name': 'Thomas'}), isNull);
        expect(DeviceVoice.tryParse({'locale': 'fr'}), isNull);
        expect(
          DeviceVoice.tryParse({
            'name': 'Thomas',
            'locale': 'fr-FR',
            'quality': 3,
            'networkRequired': 'yes',
          }),
          const DeviceVoice(name: 'Thomas', locale: 'fr-FR'),
        );
      });
    });

    test('toEngine passes name, locale and identifier', () {
      expect(amelie.toEngine(), {
        'name': 'Amélie',
        'locale': 'fr-CA',
        'identifier': 'com.apple.voice.Amelie',
      });
      expect(const DeviceVoice(name: 'Thomas', locale: 'fr-FR').toEngine(), {
        'name': 'Thomas',
        'locale': 'fr-FR',
      });
    });

    test('isHighQuality knows the engine labels', () {
      for (final quality in ['very high', 'High', 'enhanced', 'premium']) {
        expect(
          DeviceVoice(name: 'v', locale: 'en', quality: quality).isHighQuality,
          isTrue,
          reason: quality,
        );
      }
      for (final quality in [null, 'normal', 'default', 'low']) {
        expect(
          DeviceVoice(name: 'v', locale: 'en', quality: quality).isHighQuality,
          isFalse,
          reason: quality,
        );
      }
    });

    test('speaks languages with the same primary subtag', () {
      const voice = DeviceVoice(name: 'Ana', locale: 'pt_BR');

      expect(voice.speaks('pt'), isTrue);
      expect(voice.speaks('pt-PT'), isTrue);
      expect(voice.speaks('PT-br'), isTrue);
      expect(voice.speaks('es'), isFalse);
      expect(voice.normalizedLocale, 'pt-br');
    });

    test('id ignores the quality labels', () {
      expect(const DeviceVoice(name: 'Amélie', locale: 'fr_CA').id, amelie.id);
      expect(
        const DeviceVoice(name: 'Thomas', locale: 'fr-CA').id,
        isNot(amelie.id),
      );
    });

    test('sortFor puts exact locale matches first, then sorts', () {
      const thomas = DeviceVoice(name: 'Thomas', locale: 'fr-FR');
      const aurelie = DeviceVoice(name: 'aurélie', locale: 'fr-FR');
      const swiss = DeviceVoice(name: 'Zoé', locale: 'fr-CH');
      const duplicate = DeviceVoice(
        name: 'Thomas',
        locale: 'fr_FR',
        quality: 'high',
      );

      expect(
        DeviceVoice.sortFor('fr-FR', [
          swiss,
          thomas,
          amelie,
          aurelie,
          duplicate,
        ]),
        [aurelie, thomas, amelie, swiss],
      );
      expect(DeviceVoice.sortFor('fr', [swiss, amelie]), [amelie, swiss]);
    });
  });
}
