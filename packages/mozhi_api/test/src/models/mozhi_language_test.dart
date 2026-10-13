import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group(MozhiLanguage, () {
    group('fromJson', () {
      test('reads the Go field names', () {
        expect(
          MozhiLanguage.fromJson(const {'Name': 'Tamil', 'Id': 'ta'}),
          const MozhiLanguage(id: 'ta', name: 'Tamil'),
        );
      });

      test('accepts lowercase keys', () {
        expect(
          MozhiLanguage.fromJson(const {'name': 'Tamil', 'id': 'ta'}),
          const MozhiLanguage(id: 'ta', name: 'Tamil'),
        );
      });

      test('maps missing and mistyped fields to empty strings', () {
        expect(
          MozhiLanguage.fromJson(const {'Id': 42}),
          const MozhiLanguage(id: '', name: ''),
        );
      });
    });

    test('toJson uses the Go field names', () {
      expect(const MozhiLanguage(id: 'ta', name: 'Tamil').toJson(), {
        'Id': 'ta',
        'Name': 'Tamil',
      });
    });

    test('has value equality', () {
      const tamil = MozhiLanguage(id: 'ta', name: 'Tamil');

      expect(tamil, const MozhiLanguage(id: 'ta', name: 'Tamil'));
      expect(
        tamil.hashCode,
        const MozhiLanguage(id: 'ta', name: 'Tamil').hashCode,
      );
      expect(tamil, isNot(const MozhiLanguage(id: 'ta', name: 'தமிழ்')));
      expect(tamil, isNot(const MozhiLanguage(id: 'te', name: 'Tamil')));
    });

    test('toString shows id and name', () {
      expect(
        const MozhiLanguage(id: 'ta', name: 'Tamil').toString(),
        'MozhiLanguage(ta, Tamil)',
      );
    });
  });
}
