import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:mozhi/presets/models/tombstone.dart';

/// What [mergeCopies] returns: the merged `items`, in order, and the
/// `tombstones` (id → deleted at) that remain.
typedef MergedCopies<T> = ({List<T> items, Map<String, DateTime> tombstones});

/// Merges two copies of an ordered list of items with ids (this device's
/// [local] one and the [other], from a backup or sync) and their
/// tombstones, as backups merge presets and glossaries:
///
/// * per id, the newer copy wins ([modifiedAt]). Two copies changed at
///   the same time (also: neither has a change time, presets and
///   glossaries saved before they had one) that differ ([contentOf])
///   are decided by [tieBreak], the same on every device, and the winner
///   is passed through [resolved] (which gives one without a change time
///   [resolvedChangeTime], so that it also wins on devices with older
///   versions, which keep their own copy on a tie). Without [contentOf],
///   [local] wins a tie;
/// * a tombstone in either copy deletes the item when it is at least as
///   new as the item's winning copy; an item changed after its tombstone
///   (edited, or put back) stays, and its tombstone goes;
/// * items only in one copy are kept otherwise;
/// * the order is the [local] one, or the [other] one when [otherOrder]
///   (the copy reordered last); the items only in the other list go right
///   after the item before them there, or before the item after them when
///   no item is before them, or at the end;
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
  String Function(T item)? contentOf,
  T Function(T item)? resolved,
}) {
  final tombstones = {...localTombstones};
  for (final MapEntry(:key, :value) in otherTombstones.entries) {
    final known = tombstones[key];
    if (known == null || value.isAfter(known)) tombstones[key] = value;
  }

  List<T> unique(List<T> items) {
    final ids = <String>{};
    return [
      for (final item in items)
        if (ids.add(idOf(item))) item,
    ];
  }

  final mine = unique(local);
  final theirs = unique(other);
  final winners = {for (final item in mine) idOf(item): item};
  for (final item in theirs) {
    final id = idOf(item);
    final kept = winners[id];
    if (kept == null || modifiedAt(item).isAfter(modifiedAt(kept))) {
      winners[id] = item;
    } else if (contentOf != null &&
        modifiedAt(item).isAtSameMomentAs(modifiedAt(kept))) {
      final mine = contentOf(kept);
      final other = contentOf(item);
      if (mine != other) {
        final winner = tieBreak(mine, other) ? item : kept;
        winners[id] = resolved?.call(winner) ?? winner;
      }
    }
  }

  final (base, rest) = otherOrder ? (theirs, mine) : (mine, theirs);
  final order = [for (final item in base) idOf(item)];
  // Where the next new item goes: after the last item of both seen.
  int? at;
  // New items before the first item of both: they go before it.
  final leading = <String>[];
  for (final item in rest) {
    final id = idOf(item);
    final index = order.indexOf(id);
    if (index != -1) {
      order.insertAll(index, leading);
      at = index + leading.length + 1;
      leading.clear();
    } else if (at == null) {
      leading.add(id);
    } else {
      order.insert(at++, id);
    }
  }
  order.addAll(leading);

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

/// The change time given to the copy that won a tie between two copies
/// without one ([mergeCopies], [pickChange]): just after
/// [unknownChangeTime], so it wins over copies without a change time
/// (also on devices with older versions) and loses to every real change
/// and deletion.
final DateTime resolvedChangeTime = unknownChangeTime.add(
  const Duration(milliseconds: 1),
);

/// Whether, of two different copies of something whose change times tie,
/// the [other] one wins: the one whose content ([mine], [other], e.g.
/// [canonicalJson]) has the smaller SHA-256. Every device decides the
/// same way, whichever copy it holds.
bool tieBreak(String mine, String other) =>
    _digest(other).compareTo(_digest(mine)) < 0;

/// What a merge keeps of one value (an order, a default) that two copies
/// changed at [localAt] and [otherAt] (null: not since there were change
/// times), when the copies hold [localKey] and [otherKey]: whether the
/// other copy's value wins, and the change time the result keeps.
///
/// The later change wins. On a tie, copies that differ are decided by
/// [tieBreak]; when neither had a change time the result gets
/// [resolvedChangeTime], so that devices that already differ agree
/// (older versions included) instead of each keeping its own. Equal
/// copies keep this device's.
({bool otherWins, DateTime? changedAt}) pickChange({
  required DateTime? localAt,
  required DateTime? otherAt,
  required String localKey,
  required String otherKey,
}) {
  final latest = laterOf(localAt, otherAt);
  if (isLaterChange(otherAt, localAt)) {
    return (otherWins: true, changedAt: latest);
  }
  if (isLaterChange(localAt, otherAt) || localKey == otherKey) {
    return (otherWins: false, changedAt: latest);
  }
  return (
    otherWins: tieBreak(localKey, otherKey),
    changedAt: latest ?? resolvedChangeTime,
  );
}

/// [value] (JSON-encodable) as JSON with the keys of every object sorted:
/// the same data gives the same text however its maps were built.
String canonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final key in map.keys.map((key) => '$key').toList()..sort())
      key: _canonical(map[key]),
  },
  final List<Object?> list => [for (final item in list) _canonical(item)],
  _ => value,
};

String _digest(String text) => [
  for (final byte in const DartSha256().hashSync(utf8.encode(text)).bytes)
    byte.toRadixString(16).padLeft(2, '0'),
].join();
