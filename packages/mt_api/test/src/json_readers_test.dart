import 'package:mt_api/src/json_readers.dart';
import 'package:test/test.dart';

void main() {
  test('readers fall back to defaults', () {
    expect(readString(1), '');
    expect(readOptionalString(''), isNull);
    expect(readOptionalString('x'), 'x');
    expect(readInt('1'), 0);
    expect(readInt(2.9), 2);
    expect(readDouble(null), 0);
    expect(readDouble(3), 3.0);
    expect(readBool('true'), isFalse);
    expect(readBool(true), isTrue);
    expect(readStringList(['a', 1]), ['a']);
    expect(readStringList('a'), isEmpty);
    expect(
      readDateTime('2024-01-02T03:04:05Z'),
      DateTime.utc(2024, 1, 2, 3, 4, 5),
    );
    expect(readDateTime(5), isNull);
  });

  test('listEquals', () {
    final list = [1, 2];
    expect(listEquals(list, list), isTrue);
    expect(listEquals([1, 2], [1, 2]), isTrue);
    expect(listEquals([1, 2], [1]), isFalse);
    expect(listEquals([1, 2], [1, 3]), isFalse);
    expect(listEquals(<int>[], <int>[]), isTrue);
  });
}
