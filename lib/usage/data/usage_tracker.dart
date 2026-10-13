import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/token_estimate.dart';

/// Returns the current time; injectable for tests.
typedef UsageClock = DateTime Function();

/// Counts how much each bring-your-own-key AI provider is used, per calendar
/// month, so people can keep an eye on their bill.
///
/// Usage is stored as JSON under [storageKey] in [store] (only counters,
/// never text). Each month starts from zero automatically ("monthly reset");
/// months older than [keepMonths] are dropped. A provider can have a monthly
/// [UsageBudget] in characters: crossing its warning threshold (80 %) and
/// reaching it each emit one [UsageWarning] per month on [warnings].
///
/// Operations are serialised and written through. Unreadable stored JSON
/// loads as empty; storage errors propagate from the failing call (the
/// in-memory counters are still updated).
class UsageTracker {
  UsageTracker({KeyValueStore? store, UsageClock? clock, this.keepMonths = 13})
    : assert(keepMonths >= 2, 'keep at least this and last month'),
      store = store ?? PreferencesStore(),
      _clock = clock ?? DateTime.now;

  /// Key of the usage JSON in [store].
  static const storageKey = 'usage.v1';

  final KeyValueStore store;

  /// Number of months (including the current one) that are kept.
  final int keepMonths;

  final UsageClock _clock;

  final _changes = StreamController<UsageSnapshot>.broadcast();
  final _warnings = StreamController<UsageWarning>.broadcast();

  _UsageData _data = _UsageData();
  bool _loaded = false;
  Future<void> _lock = Future.value();

  /// The month "this month" currently refers to.
  UsageMonth get currentMonth => UsageMonth.of(_clock());

  /// Current in-memory usage (empty until loaded).
  UsageSnapshot get snapshot => _data.snapshot(currentMonth);

  /// Emits a new [snapshot] after every load and change.
  Stream<UsageSnapshot> get changes => _changes.stream;

  /// Emits when a provider reaches its budget's warning threshold or the
  /// budget itself, at most once per level, provider and month.
  Stream<UsageWarning> get warnings => _warnings.stream;

  /// (Re)reads usage from [store].
  Future<UsageSnapshot> load() => _synchronized(() async {
    _data = _UsageData.decode(await store.read(storageKey));
    _loaded = true;
    final snapshot = this.snapshot;
    _emit(snapshot);
    return snapshot;
  });

  /// Records one request to [providerId] that sent [inputChars] and
  /// received [outputChars] characters (Unicode code points).
  ///
  /// Tokens are estimated as `chars / 4` unless [inputTokens] /
  /// [outputTokens] are given (e.g. from the text via [recordText], or as
  /// reported by the provider). Returns the provider's usage this month.
  Future<UsageStats> record(
    String providerId,
    int inputChars,
    int outputChars, {
    int? inputTokens,
    int? outputTokens,
  }) {
    if (providerId.isEmpty) {
      throw ArgumentError.value(providerId, 'providerId', 'must not be empty');
    }
    for (final (name, value) in [
      ('inputChars', inputChars),
      ('outputChars', outputChars),
      ('inputTokens', inputTokens ?? 0),
      ('outputTokens', outputTokens ?? 0),
    ]) {
      if (value < 0) throw ArgumentError.value(value, name, 'is negative');
    }
    final added = UsageStats(
      requests: 1,
      inputChars: inputChars,
      outputChars: outputChars,
      inputTokens: inputTokens ?? estimateTokensForChars(inputChars),
      outputTokens: outputTokens ?? estimateTokensForChars(outputChars),
    );
    return _mutate((data, month) {
      final perProvider = data.months.putIfAbsent(month, () => {});
      final stats = (perProvider[providerId] ?? UsageStats.zero) + added;
      perProvider[providerId] = stats;
      final warning = _checkBudget(data, month, providerId, stats);
      return (stats, warning);
    });
  }

  /// Records one request from the actual texts, estimating tokens with the
  /// CJK-aware [estimateTokens].
  Future<UsageStats> recordText(
    String providerId, {
    required String input,
    required String output,
  }) {
    final inputEstimate = TokenEstimate.of(input);
    final outputEstimate = TokenEstimate.of(output);
    return record(
      providerId,
      inputEstimate.characters,
      outputEstimate.characters,
      inputTokens: inputEstimate.tokens,
      outputTokens: outputEstimate.tokens,
    );
  }

  /// Sets (or with null removes) the monthly budget of [providerId].
  ///
  /// Changing a budget re-arms this month's warnings for the provider; they
  /// are raised by the next [record] that is at or above a threshold.
  Future<void> setBudget(String providerId, UsageBudget? budget) =>
      _mutate((data, month) {
        if (budget == null) {
          data.budgets.remove(providerId);
        } else {
          data.budgets[providerId] = budget;
        }
        data.alerts[month]?.remove(providerId);
        return (null, null);
      });

  /// Deletes the usage counters of [providerId], or of every provider when
  /// null. Budgets are kept.
  Future<void> reset({String? providerId}) => _mutate((data, month) {
    if (providerId == null) {
      data.months.clear();
      data.alerts.clear();
    } else {
      for (final perProvider in [
        ...data.months.values,
        ...data.alerts.values,
      ]) {
        perProvider.remove(providerId);
      }
    }
    return (null, null);
  });

  /// Forgets [providerId] entirely (usage and budget), e.g. after the
  /// provider was deleted.
  Future<void> removeProvider(String providerId) => _mutate((data, month) {
    data.budgets.remove(providerId);
    for (final perProvider in [...data.months.values, ...data.alerts.values]) {
      perProvider.remove(providerId);
    }
    return (null, null);
  });

  /// Closes [changes] and [warnings].
  Future<void> dispose() async {
    await _changes.close();
    await _warnings.close();
  }

  UsageWarning? _checkBudget(
    _UsageData data,
    UsageMonth month,
    String providerId,
    UsageStats stats,
  ) {
    final budget = data.budgets[providerId];
    if (budget == null) return null;
    final level = budget.levelFor(stats.totalChars);
    final alerts = data.alerts.putIfAbsent(month, () => {});
    final previous = alerts[providerId] ?? UsageBudgetLevel.ok;
    if (level.index <= previous.index) return null;
    alerts[providerId] = level;
    return UsageWarning(
      providerId: providerId,
      month: month,
      level: level,
      usedChars: stats.totalChars,
      budget: budget,
    );
  }

  Future<T> _mutate<T>(
    (T, UsageWarning?) Function(_UsageData data, UsageMonth month) change,
  ) => _synchronized(() async {
    if (!_loaded) {
      _data = _UsageData.decode(await store.read(storageKey));
      _loaded = true;
    }
    final month = currentMonth;
    final (result, warning) = change(_data, month);
    _data.prune(month, keepMonths);
    _emit(snapshot);
    if (warning != null && !_warnings.isClosed) _warnings.add(warning);
    await store.write(storageKey, jsonEncode(_data.toJson()));
    return result;
  });

  void _emit(UsageSnapshot snapshot) {
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// Mutable storage model behind [UsageTracker].
class _UsageData {
  _UsageData();

  /// Decodes stored JSON leniently: anything unreadable is skipped.
  factory _UsageData.decode(String? raw) {
    final data = _UsageData();
    if (raw == null) return data;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return data;
    }
    if (json is! Map) return data;
    final months = json['months'];
    if (months is Map) {
      for (final MapEntry(:key, :value) in months.entries) {
        final month = key is String ? UsageMonth.tryParse(key) : null;
        if (month == null || value is! Map) continue;
        final perProvider = <String, UsageStats>{
          for (final MapEntry(:key, :value) in value.entries)
            if (key is String && key.isNotEmpty && value is Map)
              key: UsageStats.fromJson(Map<String, dynamic>.from(value)),
        };
        if (perProvider.isNotEmpty) data.months[month] = perProvider;
      }
    }
    final budgets = json['budgets'];
    if (budgets is Map) {
      for (final MapEntry(:key, :value) in budgets.entries) {
        final budget = UsageBudget.tryFromJson(value);
        if (key is String && budget != null) data.budgets[key] = budget;
      }
    }
    final alerts = json['alerts'];
    if (alerts is Map) {
      for (final MapEntry(:key, :value) in alerts.entries) {
        final month = key is String ? UsageMonth.tryParse(key) : null;
        if (month == null || value is! Map) continue;
        final levels = <String, UsageBudgetLevel>{
          for (final MapEntry(:key, :value) in value.entries)
            if (key is String &&
                UsageBudgetLevel.values.asNameMap()[value] != null)
              key: UsageBudgetLevel.values.asNameMap()[value]!,
        };
        if (levels.isNotEmpty) data.alerts[month] = levels;
      }
    }
    return data;
  }

  final months = <UsageMonth, Map<String, UsageStats>>{};
  final budgets = <String, UsageBudget>{};

  /// Highest warning level already emitted per month and provider.
  final alerts = <UsageMonth, Map<String, UsageBudgetLevel>>{};

  /// Drops months before the [keep] months ending with [current].
  void prune(UsageMonth current, int keep) {
    final oldest = current.shift(1 - keep);
    months.removeWhere((month, value) => month < oldest || value.isEmpty);
    alerts.removeWhere((month, value) => month < current || value.isEmpty);
  }

  UsageSnapshot snapshot(UsageMonth current) => UsageSnapshot(
    currentMonth: current,
    months: Map.unmodifiable({
      for (final MapEntry(:key, :value) in months.entries)
        key: Map<String, UsageStats>.unmodifiable(value),
    }),
    budgets: Map.unmodifiable(budgets),
  );

  Map<String, dynamic> toJson() {
    final sortedMonths = months.keys.toList()..sort();
    return {
      'version': 1,
      'months': {
        for (final month in sortedMonths)
          month.key: {
            for (final MapEntry(:key, :value) in months[month]!.entries)
              key: value.toJson(),
          },
      },
      'budgets': {
        for (final MapEntry(:key, :value) in budgets.entries)
          key: value.toJson(),
      },
      'alerts': {
        for (final MapEntry(:key, :value) in alerts.entries)
          key.key: {
            for (final MapEntry(:key, :value) in value.entries) key: value.name,
          },
      },
    };
  }
}

/// Compares months chronologically.
extension on UsageMonth {
  bool operator <(UsageMonth other) => compareTo(other) < 0;
}
