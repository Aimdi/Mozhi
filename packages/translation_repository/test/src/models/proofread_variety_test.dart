import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('ProofreadVariety', () {
    test('covers the common varieties with unique codes', () {
      expect(ProofreadVariety.values.map((v) => v.code), [
        'en-GB',
        'en-US',
        'en-AU',
        'en-CA',
        'pt-BR',
        'pt-PT',
        'es-ES',
        'es-419',
        'fr-FR',
        'fr-CA',
        'de-DE',
        'de-CH',
        'de-AT',
      ]);
      for (final variety in ProofreadVariety.values) {
        expect(variety.englishName, isNotEmpty, reason: variety.code);
        expect(variety.conventions, isNotEmpty, reason: variety.code);
        expect(
          variety.conventions,
          isNot(startsWith(variety.englishName)),
          reason: 'the prompt names the variety before its conventions',
        );
      }
    });

    test('languageCode is the base language', () {
      expect(ProofreadVariety.enGb.languageCode, 'en');
      expect(ProofreadVariety.es419.languageCode, 'es');
      expect(ProofreadVariety.deCh.languageCode, 'de');
    });

    group('fromCode', () {
      test('matches codes ignoring case and separators', () {
        expect(ProofreadVariety.fromCode('en-GB'), ProofreadVariety.enGb);
        expect(ProofreadVariety.fromCode('pt_br'), ProofreadVariety.ptBr);
        expect(ProofreadVariety.fromCode(' ES-419 '), ProofreadVariety.es419);
      });

      test('returns null for unknown, base or missing codes', () {
        expect(ProofreadVariety.fromCode('en'), isNull);
        expect(ProofreadVariety.fromCode('en-NZ'), isNull);
        expect(ProofreadVariety.fromCode(''), isNull);
        expect(ProofreadVariety.fromCode(null), isNull);
      });
    });

    group('forLanguage', () {
      test('lists the varieties of a language in order', () {
        expect(ProofreadVariety.forLanguage('en'), [
          ProofreadVariety.enGb,
          ProofreadVariety.enUs,
          ProofreadVariety.enAu,
          ProofreadVariety.enCa,
        ]);
        expect(ProofreadVariety.forLanguage('pt-BR'), [
          ProofreadVariety.ptBr,
          ProofreadVariety.ptPt,
        ]);
        expect(ProofreadVariety.forLanguage('DE_ch'), [
          ProofreadVariety.deDe,
          ProofreadVariety.deCh,
          ProofreadVariety.deAt,
        ]);
        expect(ProofreadVariety.forLanguage('es'), hasLength(2));
        expect(ProofreadVariety.forLanguage('fr'), hasLength(2));
      });

      test('is empty for other or missing languages', () {
        expect(ProofreadVariety.forLanguage('ja'), isEmpty);
        expect(ProofreadVariety.forLanguage(' '), isEmpty);
        expect(ProofreadVariety.forLanguage(null), isEmpty);
      });
    });
  });
}
