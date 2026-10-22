import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/data/merge_copies.dart';

typedef _Item = ({String id, int at, String value});

final _base = DateTime.utc(2026, 10, 20);

DateTime _time(int minutes) => _base.add(Duration(minutes: minutes));

_Item _item(String id, {int at = 0, String? value}) =>
    (id: id, at: at, value: value ?? id);

MergedCopies<_Item> _merge(
  List<_Item> local,
  List<_Item> other, {
  Map<String, int> localTombstones = const {},
  Map<String, int> otherTombstones = const {},
  bool otherOrder = false,
}) => mergeCopies(
  local: local,
  other: other,
  idOf: (item) => item.id,
  modifiedAt: (item) => _time(item.at),
  localTombstones: {
    for (final MapEntry(:key, :value) in localTombstones.entries)
      key: _time(value),
  },
  otherTombstones: {
    for (final MapEntry(:key, :value) in otherTombstones.entries)
      key: _time(value),
  },
  otherOrder: otherOrder,
);

List<String> _ids(MergedCopies<_Item> merged) => [
  for (final item in merged.items) item.id,
];

void main() {
  group('mergeCopies', () {
    test('keeps the items only in either copy, in local order', () {
      final merged = _merge(
        [_item('a'), _item('b')],
        [_item('x'), _item('a'), _item('y'), _item('b'), _item('z')],
      );

      // Each item of the other copy goes after the item before it there.
      expect(_ids(merged), ['x', 'a', 'y', 'b', 'z']);
      expect(merged.tombstones, isEmpty);
    });

    test('puts new items before the next one, or last', () {
      expect(_ids(_merge([_item('a'), _item('b')], [_item('x'), _item('y')])), [
        'a',
        'b',
        'x',
        'y',
      ]);
      expect(
        _ids(
          _merge(
            [_item('a'), _item('b')],
            [_item('x'), _item('y'), _item('b'), _item('z')],
          ),
        ),
        ['a', 'x', 'y', 'b', 'z'],
      );
    });

    test('takes the order of the other copy when told', () {
      final merged = _merge(
        [_item('a'), _item('mine'), _item('b')],
        [_item('b'), _item('a')],
        otherOrder: true,
      );

      expect(_ids(merged), ['b', 'a', 'mine']);
    });

    test('keeps the newer copy of an item, this one on a tie', () {
      final merged = _merge(
        [
          _item('newer there', value: 'mine'),
          _item('newer here', at: 5, value: 'mine'),
          _item('tie', at: 3, value: 'mine'),
        ],
        [
          _item('newer there', at: 1, value: 'theirs'),
          _item('newer here', at: 4, value: 'theirs'),
          _item('tie', at: 3, value: 'theirs'),
        ],
      );

      expect(
        [for (final item in merged.items) item.value],
        ['theirs', 'mine', 'mine'],
      );
    });

    test('a tombstone in either copy deletes items not changed since', () {
      final merged = _merge(
        [_item('deleted there'), _item('same time', at: 2), _item('kept')],
        [_item('deleted here', at: 1)],
        localTombstones: {'deleted here': 1},
        otherTombstones: {'deleted there': 1, 'same time': 2},
      );

      expect(_ids(merged), ['kept']);
      expect(
        merged.tombstones.keys,
        unorderedEquals(['deleted here', 'deleted there', 'same time']),
      );
    });

    test('an item changed after its tombstone stays and drops it', () {
      final merged = _merge(
        [_item('a', at: 5)],
        const [],
        otherTombstones: {'a': 4},
      );

      expect(_ids(merged), ['a']);
      expect(merged.tombstones, isEmpty);
    });

    test('a newer copy from the other side beats a tombstone here', () {
      final merged = _merge(
        const [],
        [_item('a', at: 5)],
        localTombstones: {'a': 4},
      );

      expect(_ids(merged), ['a']);
      expect(merged.tombstones, isEmpty);
    });

    test('keeps the later of two tombstones of an item', () {
      expect(
        _merge(
          const [],
          const [],
          localTombstones: {'a': 1, 'b': 5},
          otherTombstones: {'a': 3, 'b': 2},
        ).tombstones,
        {'a': _time(3), 'b': _time(5)},
      );
    });

    test('keeps an id given twice in a copy once (the first)', () {
      final merged = _merge(
        [_item('a', value: 'first'), _item('a', value: 'second')],
        [_item('b', value: 'first'), _item('b', value: 'second')],
      );

      expect([for (final item in merged.items) item.value], ['first', 'first']);
      expect(_ids(merged), ['a', 'b']);
    });

    test('returns an unmodifiable list', () {
      expect(
        () => _merge([_item('a')], const []).items.add(_item('b')),
        throwsUnsupportedError,
      );
    });
  });

  group('isLaterChange', () {
    test('compares change times, null being the oldest', () {
      expect(isLaterChange(_time(1), _time(0)), isTrue);
      expect(isLaterChange(_time(0), _time(0)), isFalse);
      expect(isLaterChange(_time(0), _time(1)), isFalse);
      expect(isLaterChange(_time(0), null), isTrue);
      expect(isLaterChange(null, _time(0)), isFalse);
      expect(isLaterChange(null, null), isFalse);
    });
  });

  group('sameRelativeOrder', () {
    test('ignores added and removed ids', () {
      expect(sameRelativeOrder(['a', 'b', 'c'], ['x', 'a', 'c']), isTrue);
      expect(sameRelativeOrder(const [], ['a']), isTrue);
    });

    test('notices a move', () {
      expect(sameRelativeOrder(['a', 'b', 'c'], ['b', 'a', 'c']), isFalse);
    });

    test('notices a different number of repeated ids', () {
      expect(sameRelativeOrder(['a', 'a'], ['a']), isFalse);
    });
  });
}
