import 'package:equatable/equatable.dart';
import 'package:mozhi/usage/models/models.dart';

enum UsageStatus { initial, loading, ready, failure }

class UsageState extends Equatable {
  const UsageState({
    required this.snapshot,
    this.status = UsageStatus.initial,
  });

  final UsageStatus status;

  /// Latest usage (empty until [status] is [UsageStatus.ready]).
  final UsageSnapshot snapshot;

  UsageState copyWith({UsageStatus? status, UsageSnapshot? snapshot}) =>
      UsageState(
        status: status ?? this.status,
        snapshot: snapshot ?? this.snapshot,
      );

  @override
  List<Object?> get props => [status, snapshot];
}
