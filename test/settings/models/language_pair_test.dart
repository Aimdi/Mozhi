import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/settings/models/language_pair.dart';
import 'package:translation_repository/translation_repository.dart';

const _french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const _german = Language(code: 'de', name: 'German');

void main() {
  group(LanguagePair, () {
    test('supports value equality', () {
      expect(
        const LanguagePair(source: _french, target: _german),
        const LanguagePair(source: _french, target: _german),
      );
      expect(
        const LanguagePair(source: _french, target: _german),
        isNot(const LanguagePair(source: _german, target: _french)),
      );
    });

    test('compares languages by code, not by display name', () {
      expect(
        const LanguagePair(source: _french, target: _german),
        const LanguagePair(
          source: Language(code: 'fr', name: 'Französisch'),
          target: _german,
        ),
      );
    });

    test('round-trips through JSON', () {
      const pair = LanguagePair(
        source: Language.auto,
        target: Language.custom('Pirate speak'),
      );

      final restored = LanguagePair.fromJson(pair.toJson());

      expect(restored, pair);
      expect(restored.target.isCustom, isTrue);
    });

    test('writes both languages', () {
      const pair = LanguagePair(source: _french, target: _german);

      expect(pair.toJson(), {
        'source': {'code': 'fr', 'name': 'French', 'nativeName': 'Français'},
        'target': {'code': 'de', 'name': 'German'},
      });
    });

    test('accepts nested maps that are not Map<String, dynamic>', () {
      final pair = LanguagePair.fromJson(const {
        'source': <Object?, Object?>{'code': 'fr', 'name': 'French'},
        'target': <Object?, Object?>{'code': 'de', 'name': 'German'},
      });

      expect(pair, const LanguagePair(source: _french, target: _german));
    });

    test('throws for missing or invalid languages', () {
      expect(
        () => LanguagePair.fromJson(const {
          'source': {'code': 'fr'},
        }),
        throwsA(anything),
      );
      expect(
        () => LanguagePair.fromJson(const {'source': 'fr', 'target': 'de'}),
        throwsA(anything),
      );
    });

    test('has a readable toString', () {
      expect(
        const LanguagePair(source: _french, target: _german).toString(),
        'LanguagePair(fr → de)',
      );
    });
  });
}
