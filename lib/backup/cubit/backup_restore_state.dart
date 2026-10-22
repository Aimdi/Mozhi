import 'package:equatable/equatable.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';

/// Where restoring a backup is.
enum BackupRestoreStep {
  /// No file yet.
  pick,

  /// A backup file was picked ([BackupRestoreState.header]); it needs its
  /// passphrase.
  locked,

  /// Deriving the key and decrypting.
  unlocking,

  /// Decrypted ([BackupRestoreState.snapshot]): what it holds, and
  /// Replace or Merge.
  review,

  /// Restoring ([BackupRestoreState.mode]).
  restoring,

  /// Restored ([BackupRestoreState.report]), or failed halfway
  /// ([BackupRestoreFailure.restore]).
  done,
}

/// What went wrong.
enum BackupRestoreFailure {
  /// The picked file is not a Mozhi backup.
  notBackup,

  /// It was made by a newer version of the app.
  newerVersion,

  /// The file is larger than any backup.
  tooLarge,

  /// The file could not be read.
  unreadable,

  /// Wrong passphrase, or the file is damaged.
  wrongPassphrase,

  /// A section could not be restored ([BackupRestoreState.failedSection]);
  /// the others were.
  restore,
}

/// The state of `BackupRestoreCubit`. Never holds the passphrase.
class BackupRestoreState extends Equatable {
  const new({
    this.step = BackupRestoreStep.pick,
    this.fileName,
    this.header,
    this.snapshot,
    this.selected = const {},
    this.mode,
    this.report,
    this.failure,
    this.failedSection,
  });

  final BackupRestoreStep step;

  /// The picked file's name.
  final String? fileName;

  /// The picked file's readable header (date, app version).
  final BackupHeader? header;

  /// The decrypted backup.
  final BackupSnapshot? snapshot;

  /// The ids of the sections to restore (of those this app knows).
  final Set<String> selected;

  /// How the backup is being, or was, restored.
  final BackupRestoreMode? mode;

  /// What the restore did.
  final BackupRestoreReport? report;

  final BackupRestoreFailure? failure;

  /// The section that could not be restored.
  final String? failedSection;

  BackupRestoreState copyWith({
    BackupRestoreStep? step,
    String? Function()? fileName,
    BackupHeader? Function()? header,
    BackupSnapshot? Function()? snapshot,
    Set<String>? selected,
    BackupRestoreMode? Function()? mode,
    BackupRestoreReport? Function()? report,
    BackupRestoreFailure? Function()? failure,
    String? Function()? failedSection,
  }) => BackupRestoreState(
    step: step ?? this.step,
    fileName: fileName != null ? fileName() : this.fileName,
    header: header != null ? header() : this.header,
    snapshot: snapshot != null ? snapshot() : this.snapshot,
    selected: selected ?? this.selected,
    mode: mode != null ? mode() : this.mode,
    report: report != null ? report() : this.report,
    failure: failure != null ? failure() : this.failure,
    failedSection: failedSection != null ? failedSection() : this.failedSection,
  );

  @override
  List<Object?> get props => [
    step,
    fileName,
    header,
    snapshot,
    selected,
    mode,
    report,
    failure,
    failedSection,
  ];
}
