import 'package:equatable/equatable.dart';

/// A calendar month (local time) that usage is bucketed by.
class UsageMonth extends Equatable implements Comparable<UsageMonth> {
  const new(this.year, this.month)
    : assert(month >= 1 && month <= 12, 'month must be 1-12');

  /// The month that contains [time] (in the time zone of [time]).
  factory of(DateTime time) => UsageMonth(time.year, time.month);

  /// Month `index ~/ 12`, `index % 12 + 1`; inverse of [index].
  factory fromIndex(int index) =>
      UsageMonth(index ~/ 12, index % 12 + 1);

  /// Parses a [key] like `2026-10`; returns null when malformed.
  static UsageMonth? tryParse(String key) {
    final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(key);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (month < 1 || month > 12) return null;
    return UsageMonth(year, month);
  }

  final int year;

  /// 1 (January) to 12 (December).
  final int month;

  /// Storage key, e.g. `2026-10`.
  String get key => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}';

  /// Months since year 0; consecutive months have consecutive indices.
  int get index => year * 12 + month - 1;

  /// First moment of the month (local time).
  DateTime get start => DateTime(year, month);

  UsageMonth get previous => UsageMonth.fromIndex(index - 1);

  UsageMonth get next => UsageMonth.fromIndex(index + 1);

  /// The month [months] months later (earlier when negative).
  UsageMonth shift(int months) => UsageMonth.fromIndex(index + months);

  @override
  int compareTo(UsageMonth other) => index.compareTo(other.index);

  @override
  List<Object?> get props => [year, month];

  @override
  String toString() => 'UsageMonth($key)';
}
