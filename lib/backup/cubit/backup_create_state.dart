import 'package:equatable/equatable.dart';

/// Where creating a backup is.
enum BackupCreateStatus {
  /// Choosing what to include and the passphrase.
  editing,

  /// Collecting, encrypting and saving the backup.
  working,

  /// Saved ([BackupCreateState.fileName]).
  saved,

  /// It failed ([BackupCreateState.failure]).
  failure,
}

/// Why creating a backup failed.
enum BackupCreateFailure {
  /// A section could not be read ([BackupCreateState.failedSection]).
  section,

  /// The file could not be encrypted or saved.
  save,
}

/// The state of `BackupCreateCubit`. Never holds the passphrase.
class BackupCreateState extends Equatable {
  const new({
    this.sections = const [],
    this.selected = const {},
    this.includeSecrets = false,
    this.status = BackupCreateStatus.editing,
    this.failure,
    this.failedSection,
    this.fileName,
    this.lastBackupAt,
  });

  /// The ids of every section a backup can hold, in the registry's order.
  final List<String> sections;

  /// The ids of the sections to include.
  final Set<String> selected;

  /// Whether API keys and passwords are included (off unless the user
  /// turns it on).
  final bool includeSecrets;

  final BackupCreateStatus status;
  final BackupCreateFailure? failure;

  /// The id of the section that could not be read.
  final String? failedSection;

  /// The name the backup was saved as.
  final String? fileName;

  /// When the last backup was saved (on this device).
  final DateTime? lastBackupAt;

  /// Whether a backup can be made: something is selected and nothing is
  /// running.
  bool get canCreate =>
      selected.isNotEmpty && status != BackupCreateStatus.working;

  BackupCreateState copyWith({
    Set<String>? selected,
    bool? includeSecrets,
    BackupCreateStatus? status,
    BackupCreateFailure? Function()? failure,
    String? Function()? failedSection,
    String? Function()? fileName,
    DateTime? Function()? lastBackupAt,
  }) => BackupCreateState(
    sections: sections,
    selected: selected ?? this.selected,
    includeSecrets: includeSecrets ?? this.includeSecrets,
    status: status ?? this.status,
    failure: failure != null ? failure() : this.failure,
    failedSection: failedSection != null ? failedSection() : this.failedSection,
    fileName: fileName != null ? fileName() : this.fileName,
    lastBackupAt: lastBackupAt != null ? lastBackupAt() : this.lastBackupAt,
  );

  @override
  List<Object?> get props => [
    sections,
    selected,
    includeSecrets,
    status,
    failure,
    failedSection,
    fileName,
    lastBackupAt,
  ];
}
