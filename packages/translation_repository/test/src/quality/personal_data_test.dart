import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(PersonalData, () {
    List<(PersonalDataKind, String)> found(String text) => [
      for (final (kind, start, end) in PersonalData.matches(text))
        (kind, text.substring(start, end)),
    ];

    test('skips text without digits, @ or hexadecimal colons', () {
      expect(PersonalData.matches('Nothing personal here.'), isEmpty);
      expect(PersonalData.find('Nothing personal here.'), isEmpty);
    });

    test('finds e-mail addresses', () {
      expect(found('Write to jane.doe+x@mail.example.org today'), [
        (PersonalDataKind.email, 'jane.doe+x@mail.example.org'),
      ]);
    });

    group('e-mail addresses with letters of any script', () {
      test('whole, never from the middle of a word', () {
        expect(found('Schreib an info@müller.de'), [
          (PersonalDataKind.email, 'info@müller.de'),
        ]);
        expect(found('Mail jürgen@example.de today'), [
          (PersonalDataKind.email, 'jürgen@example.de'),
        ]);
        expect(found('Écrivez à françois.lefèvre@société.fr'), [
          (PersonalDataKind.email, 'françois.lefèvre@société.fr'),
        ]);
        // Decomposed accents too.
        expect(found('jo\u0308rg@example.de'), [
          (PersonalDataKind.email, 'jo\u0308rg@example.de'),
        ]);
      });

      test('internationalised domains', () {
        expect(found('Пишите на иван@пример.рф'), [
          (PersonalDataKind.email, 'иван@пример.рф'),
        ]);
        expect(found('γράψτε στο info@παράδειγμα.ελ'), [
          (PersonalDataKind.email, 'info@παράδειγμα.ελ'),
        ]);
        expect(found('or info@xn--mller-kva.de, a@b.xn--p1ai'), [
          (PersonalDataKind.email, 'info@xn--mller-kva.de'),
          (PersonalDataKind.email, 'a@b.xn--p1ai'),
        ]);
      });

      test('without the dot that ends a sentence', () {
        expect(found('Mail info@müller.de.'), [
          (PersonalDataKind.email, 'info@müller.de'),
        ]);
        expect(found('(jürgen@example.de), "a@b.de"!'), [
          (PersonalDataKind.email, 'jürgen@example.de'),
          (PersonalDataKind.email, 'a@b.de'),
        ]);
      });

      test('not with the text of scripts written without spaces', () {
        expect(found('请发邮件至info@example.com获取'), [
          (PersonalDataKind.email, 'info@example.com'),
        ]);
        expect(found('info@example.com으로 보내세요'), [
          (PersonalDataKind.email, 'info@example.com'),
        ]);
        expect(found('メールはtaro@example.jpまで'), [
          (PersonalDataKind.email, 'taro@example.jp'),
        ]);
      });

      test('not without a domain', () {
        expect(found('@müller and müller@ and a@b'), isEmpty);
      });
    });

    group('IPv6 addresses', () {
      test('full, compressed, with an IPv4 tail or a zone', () {
        for (final address in [
          '2001:0db8:85a3:0000:0000:8a2e:0370:7334',
          '2001:DB8:85A3:0:0:8A2E:370:7334',
          '2001:db8::1',
          '2001:db8::',
          'fe80::1ff:fe23:4567:890a',
          'fe80::1%eth0',
          '::ffff:192.0.2.1',
          '0:0:0:0:0:ffff:192.0.2.1',
          'a:b:c:d:e:f:1:2',
          'dead::beef',
        ]) {
          expect(
            found('Host $address is down.').where((m) => m.$2.contains(':')),
            [(PersonalDataKind.ipAddress, address)],
            reason: address,
          );
        }
      });

      test('in brackets, with a port, at the end of a sentence', () {
        expect(found('Open [2001:db8::42]:8080 now'), [
          (PersonalDataKind.ipAddress, '2001:db8::42'),
        ]);
        expect(found('It was 2001:db8::1.'), [
          (PersonalDataKind.ipAddress, '2001:db8::1'),
        ]);
      });

      test('not times, ratios, verses, timestamps, MACs or code', () {
        for (final text in [
          'At 10:30 sharp',
          'From 10:30:00 on',
          'Mix 1:2:3 parts',
          'At 12:34:56.789 it failed',
          'John 3:16 says',
          'On 2026-10-22T10:30:00Z',
          'Ratio 1:2:3:4:5:6:7:8',
          'MAC 00:1A:2B:3C:4D:5E',
          'Use std::vector or a[1::2] or A::B',
          'Loopback ::1 and ::',
          'Bad 2001:db8:::1, 1::2::3, 1:2:3:4:5:6:7:8:9',
          'Bad 12345::1 or 2001:db8::g1',
          'Too many 1:2:3:4:5:6:7::8 or ::ffff:300.0.2.1',
        ]) {
          expect(
            found(text).where((m) => m.$1 == PersonalDataKind.ipAddress),
            isEmpty,
            reason: text,
          );
        }
      });

      test('isValidIpv6', () {
        expect(PersonalData.isValidIpv6('2001:db8::1'), isTrue);
        expect(PersonalData.isValidIpv6('::ffff:192.0.2.1'), isTrue);
        expect(PersonalData.isValidIpv6('fe80::1234%en0'), isTrue);
        expect(PersonalData.isValidIpv6('1:2:3:4:5:6:7:8'), isFalse);
        expect(PersonalData.isValidIpv6('1:2:3:4:5:6:7:abcd'), isTrue);
        expect(PersonalData.isValidIpv6('::1'), isFalse);
        expect(PersonalData.isValidIpv6('1::2:3:4:5:6:7:8'), isFalse);
        expect(PersonalData.isValidIpv6('::ffff:1.2.3'), isFalse);
        expect(PersonalData.isValidIpv6(':1::abcd'), isFalse);
      });

      test('without digits are still looked for', () {
        expect(found('dead:beef:cafe:babe:dead:beef:cafe:babe'), [
          (
            PersonalDataKind.ipAddress,
            'dead:beef:cafe:babe:dead:beef:cafe:babe',
          ),
        ]);
      });
    });

    test('restoring puts the exact originals back', () {
      const text =
          'Schreib an info@müller.de oder jürgen@example.de, '
          'Server [2001:db8::1]:443 und ::ffff:192.0.2.1.';
      final masked = TextMasker.mask(text, PersonalData.find(text));
      expect(masked.text, 'Schreib an ⟨1⟩ oder ⟨2⟩, Server [⟨3⟩]:443 und ⟨4⟩.');
      expect(masked.personalCount, 4);
      final restored = masked.restore(
        'Write to ⟨1⟩ or ⟨2⟩, server [⟨3⟩]:443 and ⟨4⟩.',
      );
      expect(
        restored.text,
        'Write to info@müller.de or jürgen@example.de, '
        'server [2001:db8::1]:443 and ::ffff:192.0.2.1.',
      );
      expect(restored.isComplete, isTrue);
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
