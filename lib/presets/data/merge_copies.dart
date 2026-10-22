import 'package:mozhi/presets/models/tombstone.dart';

/// What [mergeCopies] returns: the merged `items`, in order, and the
/// `tombstones` (id → deleted at) that remain.
typedef MergedCopies<T> = ({List<T> items, Map<String, DateTime> tombstones});

/// Merges two copies of an ordered list of items with ids (this device's
/// [local] one and the [other], from a backup or sync) and their
/// tombstones, as backups merge presets and glossaries:
///
/// * per id, the newer copy wins ([modifiedAt]; [local] on a tie);
/// * a tombstone in either copy deletes the item when it is at least as
///   new as the item's winning copy; an item changed after its tombstone
///   (edited, or put back) stays, and its tombstone goes;
/// * items only in one copy are kept otherwise;
/// * the order is the [local] one, or the [other] one when [otherOrder]
///   (the copy reordered last): the items only in the other list go right
///   after the item before them there (first when nothing is before
///   them);
/// * of two tombstones of one id the later stays.
///
/// Items of a copy with an id given twice are kept once (the first).
MergedCopies<T> mergeCopies<T>({
  required List<T> local,
  required List<T> other,
  required String Function(T item) idOf,
  required DateTime Function(T item) modifiedAt,
  Map<String, DateTime> localTombstones = const {},
  Map<String, DateTime> otherTombstones = const {},
  bool otherOrder = false,
}) {
  final tombstones = {...localTombstones};
  for (final MapEntry(:key, :value) in otherTombstones.entries) {
    final known = tombstones[key];
    if (known == null || value.isAfter(known)) tombstones[key] = value;
  }

  final winners = <String, T>{};
  for (final item in local) {
    winners.putIfAbsent(idOf(item), () => item);
  }
  final fromOther = <String>{};
  for (final item in other) {
    final id = idOf(item);
    if (!fromOther.add(id)) continue;
    final mine = winners[id];
    if (mine == null || modifiedAt(item).isAfter(modifiedAt(mine))) {
      winners[id] = item;
    }
  }

  final (base, rest) = otherOrder ? (other, local) : (local, other);
  final order = <String>[];
  final placed = <String>{};
  for (final item in base) {
    final id = idOf(item);
    if (placed.add(id)) order.add(id);
  }
  var at = 0;
  for (final item in rest) {
    final id = idOf(item);
    final index = order.indexOf(id);
    if (index != -1) {
      at = index + 1;
    } else {
      order.insert(at++, id);
    }
  }

  final items = <T>[];
  for (final id in order) {
    final item = winners[id] as T;
    final deletedAt = tombstones[id];
    if (deletedAt != null && !modifiedAt(item).isAfter(deletedAt)) continue;
    tombstones.remove(id);
    items.add(item);
  }
  return (items: List.unmodifiable(items), tombstones: tombstones);
}

/// Whether the change time [a] is later than [b] (null: before every
/// change time, see [unknownChangeTime]).
bool isLaterChange(DateTime? a, DateTime? b) =>
    (a ?? unknownChangeTime).isAfter(b ?? unknownChangeTime);

/// Whether the ids that are in both [before] and [after] are in the same
/// order in each: ids added or removed don't count, moving one does.
bool sameRelativeOrder(List<String> before, List<String> after) {
  final common = before.toSet().intersection(after.toSet());
  final a = before.where(common.contains).toList();
  final b = after.where(common.contains).toList();
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
