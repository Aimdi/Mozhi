import 'package:bloc/bloc.dart';
import 'package:mozhi/backup/cubit/backup_create_state.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';

export 'backup_create_state.dart';

/// Makes a `.mozhibackup` file: the chosen sections of the [BackupRegistry]
/// (secrets only when the user includes them), encrypted for a passphrase
/// by the [BackupCodec] and saved through [BackupFiles] as
/// `mozhi-<date>.mozhibackup` ([fileNameFor]); then records the time in
/// the [BackupStatusStore].
///
/// The passphrase is only an argument of [create]: it is never kept.
class BackupCreateCubit extends Cubit<BackupCreateState> {
  new({
    required this._registry,
    required this._files,
    required this._status,
    this._codec = const BackupCodec(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super(
         BackupCreateState(
           sections: [for (final section in _registry.sections) section.id],
           selected: {for (final section in _registry.sections) section.id},
         ),
       );

  final BackupRegistry _registry;
  final BackupFiles _files;
  final BackupStatusStore _status;
  final BackupCodec _codec;
  final DateTime Function() _clock;

  /// The file name of a backup made at [at]: `mozhi-2026-10-22.mozhibackup`.
  static String fileNameFor(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'mozhi-${at.year}-${two(at.month)}-${two(at.day)}'
        '.${BackupCodec.fileExtension}';
  }

  /// Reads when the last backup was made.
  Future<void> load() async {
    try {
      final last = await _status.lastBackupAt();
      if (!isClosed) emit(state.copyWith(lastBackupAt: () => last));
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Includes the section [id] or leaves it out.
  void toggleSection(String id, {required bool selected}) {
    if (!state.sections.contains(id)) return;
    emit(
      state.copyWith(
        selected: selected
            ? {...state.selected, id}
            : ({...state.selected}..remove(id)),
      ),
    );
  }

  /// Includes API keys and passwords, or leaves them out.
  void setIncludeSecrets({required bool include}) =>
      emit(state.copyWith(includeSecrets: include));

  /// Back to choosing after a failure.
  void edit() => emit(
    state.copyWith(
      status: BackupCreateStatus.editing,
      failure: () => null,
      failedSection: () => null,
    ),
  );

  /// Makes the backup, encrypted for [passphrase], and lets the user save
  /// it. Cancelling the save goes back to [BackupCreateStatus.editing].
  Future<void> create(String passphrase) async {
    if (!state.canCreate) return;
    emit(
      state.copyWith(
        status: BackupCreateStatus.working,
        failure: () => null,
        failedSection: () => null,
      ),
    );
    final BackupSnapshot snapshot;
    try {
      snapshot = await _registry.snapshot(
        includeSecrets: state.includeSecrets,
        only: state.selected,
      );
    } on BackupSectionException catch (error, stackTrace) {
      addError(error, stackTrace);
      _fail(BackupCreateFailure.section, section: error.sectionId);
      return;
    }
    final now = _clock();
    final name = fileNameFor(now);
    final bool saved;
    try {
      final bytes = await _codec.encrypt(snapshot, passphrase);
      if (isClosed) return;
      saved = await _files.save(fileName: name, bytes: bytes);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      _fail(BackupCreateFailure.save);
      return;
    }
    if (isClosed) return;
    if (!saved) {
      emit(state.copyWith(status: BackupCreateStatus.editing));
      return;
    }
    try {
      await _status.recordBackup(now);
    } on Object catch (error, stackTrace) {
      // The file is saved; only the date shown in the settings is missing.
      addError(error, stackTrace);
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        status: BackupCreateStatus.saved,
        fileName: () => name,
        lastBackupAt: () => now,
      ),
    );
  }

  void _fail(BackupCreateFailure failure, {String? section}) {
    if (isClosed) return;
    emit(
      state.copyWith(
        status: BackupCreateStatus.failure,
        failure: () => failure,
        failedSection: () => section,
      ),
    );
  }
}
