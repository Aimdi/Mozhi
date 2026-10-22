import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(PersonalData, () {
    List<(PersonalDataKind, String)> found(String text) => [
      for (final (kind, start, end) in PersonalData.matches(text))
        (kind, text.substring(start, end)),
    ];

    test('skips text without digits or @', () {
      expect(PersonalData.matches('Nothing personal here.'), isEmpty);
      expect(PersonalData.find('Nothing personal here.'), isEmpty);
    });

    test('finds e-mail addresses', () {
      expect(found('Write to jane.doe+x@mail.example.org today'), [
        (PersonalDataKind.email, 'jane.doe+x@mail.example.org'),
      ]);
    });

    group('phone numbers', () {
      test('international, with a trunk 0, an area code or NANP', () {
        for (final phone in [
          '+49 30 1234567',
          '+1 (555) 123-4567',
          '0049 30 12345678',
          '030 1234567',
          '0151-12345678',
          '030/1234567',
          '(030) 123 4567',
          '555-123-4567',
          '555.123.4567',
        ]) {
          expect(found('Call $phone now'), [
            (PersonalDataKind.phone, phone),
          ], reason: phone);
        }
      });

      test('drops a sentence parenthesis around the number', () {
        expect(found('(0301234567)'), [(PersonalDataKind.phone, '0301234567')]);
      });

      test('not dates, years, amounts, versions or short numbers', () {
        for (final text in [
          'On 22.10.2026 at noon',
          'From 2010-2020',
          'It costs 1.234.567 euros',
          'Room 1234 and 5678',
          'Order 12345',
          'Code 0123',
          'In 2026-10-22',
          'Ref 0301--234567',
          'ID123456789',
        ]) {
          expect(
            found(text).where((m) => m.$1 == PersonalDataKind.phone),
            isEmpty,
            reason: text,
          );
        }
      });

      test('not with unbalanced parentheses or too many digits', () {
        expect(
          found('+49 (30 1234567').where((m) => m.$1 == PersonalDataKind.phone),
          isEmpty,
        );
        expect(
          found('+49 3012 3456 7890 1234')
              .where((m) => m.$1 == PersonalDataKind.phone),
          isEmpty,
        );
      });
    });

    group('IBANs', () {
      test('finds valid IBANs, grouped or not', () {
        expect(found('Pay to DE89 3704 0044 0532 0130 00, thanks'), [
          (PersonalDataKind.iban, 'DE89 3704 0044 0532 0130 00'),
        ]);
        expect(found('GB82WEST12345698765432'), [
          (PersonalDataKind.iban, 'GB82WEST12345698765432'),
        ]);
      });

      test('checks the checksum and the length', () {
        expect(PersonalData.isValidIban('DE89 3704 0044 0532 0130 00'), isTrue);
        expect(PersonalData.isValidIban('de89370400440532013000'), isTrue);
        expect(
          PersonalData.isValidIban('DE88 3704 0044 0532 0130 00'),
          isFalse,
        );
        expect(PersonalData.isValidIban('DE89 3704'), isFalse);
        expect(PersonalData.isValidIban('1234567890123456'), isFalse);
        expect(found('DE88 3704 0044 0532 0130 00'), isEmpty);
      });
    });

    group('payment cards', () {
      test('finds Luhn-valid numbers of 13 to 19 digits', () {
        expect(found('Card 4111 1111 1111 1111 exp 12/29'), [
          (PersonalDataKind.paymentCard, '4111 1111 1111 1111'),
        ]);
        expect(found('5500-0000-0000-0004'), [
          (PersonalDataKind.paymentCard, '5500-0000-0000-0004'),
        ]);
      });

      test('rejects invalid check digits and repeated digits', () {
        expect(PersonalData.isValidCardNumber('4111 1111 1111 1112'), isFalse);
        expect(PersonalData.isValidCardNumber('0000 0000 0000 0000'), isFalse);
        expect(PersonalData.isValidCardNumber('4111'), isFalse);
        expect(found('4111 1111 1111 1112'), isEmpty);
      });

      test('Luhn', () {
        expect(PersonalData.isLuhnValid('79927398713'), isTrue);
        expect(PersonalData.isLuhnValid('79927398710'), isFalse);
        expect(PersonalData.isLuhnValid(''), isFalse);
        expect(PersonalData.isLuhnValid('12a4'), isFalse);
      });
    });

    test('finds IPv4 addresses', () {
      expect(found('Server 192.168.1.20 is down'), [
        (PersonalDataKind.ipAddress, '192.168.1.20'),
      ]);
      expect(found('Not 300.1.1.1'), isEmpty);
    });

    test('finds everything in text order, as personal spans', () {
      const text = 'a@b.de, +49 30 1234567, 10.0.0.1';
      expect(found(text).map((m) => m.$1), [
        PersonalDataKind.email,
        PersonalDataKind.phone,
        PersonalDataKind.ipAddress,
      ]);
      expect(PersonalData.find(text).every((span) => span.isPersonal), isTrue);
    });
  });
}
