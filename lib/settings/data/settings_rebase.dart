import 'dart:convert';

import 'package:mozhi/core/network/url_credentials.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// The change the app made from [base] to [mine], applied to [theirs]: the
/// stored settings, which a restore or a sync merge changed after the app
/// read [base] (see `SettingsRepository.save`).
///
/// Each setting the app changed (differs between [base] and [mine]) is
/// [mine]'s; every other one is [theirs]'. AI providers (with their keys
/// and headers) go by id and Mozhi instances (with their user names and
/// passwords) by address, each the same way: one the app added, changed
/// or removed is as the app left it, any other as [theirs] has it.
/// Their order is [theirs]', with what only the app added after it,
/// unless the app reordered them.
AppSettings rebaseSettings({
  required AppSettings base,
  required AppSettings mine,
  required AppSettings theirs,
}) {
  final b = base.toJson();
  final m = mine.toJson();
  final t = theirs.toJson();
  final json = <String, dynamic>{
    for (final key in {...t.keys, ...m.keys})
      key: !m.containsKey(key) || _same(m[key], b[key]) ? t[key] : m[key],
  };
  return AppSettings.fromJson(json).copyWith(
    providers: _byKey(
      base.providers,
      mine.providers,
      theirs.providers,
      keyOf: (provider) => provider.id,
      same: (a, b) => a == b,
    ),
    instances: _byKey(
      base.instances,
      mine.instances,
      theirs.instances,
      keyOf: (instance) => urlWithoutCredentials(instance.url),
      same: (a, b) => a.url == b.url && _same(a.toJson(), b.toJson()),
    ),
  );
}

/// [mine]'s items where they differ from [base]'s (added, changed or
/// removed by the app), [theirs]' otherwise, in [theirs]' order unless the
/// app reordered the items of [base] it kept.
List<T> _byKey<T>(
  List<T> base,
  List<T> mine,
  List<T> theirs, {
  required String Function(T item) keyOf,
  required bool Function(T a, T b) same,
}) {
  Map<String, T> index(List<T> items) {
    final result = <String, T>{};
    for (final item in items) {
      result.putIfAbsent(keyOf(item), () => item);
    }
    return result;
  }

  final before = index(base);
  final after = index(mine);
  final stored = index(theirs);
  T? pick(String key) {
    final was = before[key];
    final now = after[key];
    final changed = switch ((was, now)) {
      (null, null) => false,
      (final T a?, final T b?) => !same(a, b),
      _ => true,
    };
    return changed ? now : stored[key];
  }

  final kept = [
    for (final key in before.keys)
      if (after.containsKey(key)) key,
  ];
  final keptOrder = [
    for (final key in after.keys)
      if (before.containsKey(key)) key,
  ];
  final reordered = kept.join('\n') != keptOrder.join('\n');
  final keys = <String>[];
  final seen = <String>{};
  for (final key
      in reordered
          ? [...after.keys, ...stored.keys]
          : [...stored.keys, ...after.keys]) {
    if (seen.add(key)) keys.add(key);
  }
  return List.unmodifiable([for (final key in keys) ?pick(key)]);
}

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
