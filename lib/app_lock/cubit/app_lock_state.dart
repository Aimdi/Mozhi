import 'package:equatable/equatable.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';

/// The state of `AppLockCubit`: what the lock gate shows.
class AppLockState extends Equatable {
  const new({
    this.status = AppLockStatus.checking,
    this.prompting = false,
    this.failed = false,
  });

  /// Whether the app is locked, unlocked, or still finding out.
  final AppLockStatus status;

  /// Whether the system unlock prompt is showing.
  final bool prompting;

  /// Whether the last prompt ended without unlocking (cancelled or
  /// failed): the lock screen says so and offers to try again.
  final bool failed;

  /// Whether the app's content may be shown.
  bool get unlocked => status == AppLockStatus.unlocked;

  AppLockState copyWith({
    AppLockStatus? status,
    bool? prompting,
    bool? failed,
  }) => AppLockState(
    status: status ?? this.status,
    prompting: prompting ?? this.prompting,
    failed: failed ?? this.failed,
  );

  @override
  List<Object?> get props => [status, prompting, failed];
}
