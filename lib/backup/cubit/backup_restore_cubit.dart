import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:mozhi/backup/cubit/backup_restore_state.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';

export 'backup_restore_state.dart';

/// Restores a backup: [pickFile] (its header says when it was made),
/// [unlock] with the passphrase, review what it holds and [restore] it
/// with Replace or Merge through the [BackupRegistry].
///
/// Given a `snapshot` (e.g. received from another phone, already
/// decrypted) it starts at [BackupRestoreStep.review].
///
/// The passphrase is only an argument of [unlock]: it is never kept.
class BackupRestoreCubit extends Cubit<BackupRestoreState> {
  new({
    required this._registry,
    required this._files,
    this._codec = const BackupCodec(),
    BackupSnapshot? snapshot,
  }) : super(
         snapshot == null
             ? const BackupRestoreState()
             : BackupRestoreState(
                 step: BackupRestoreStep.review,
                 snapshot: snapshot,
                 selected: _known(_registry, snapshot),
               ),
       );

  final BackupRegistry _registry;
  final BackupFiles _files;
  final BackupCodec _codec;

  /// The picked file (ciphertext).
  Uint8List? _bytes;

  /// The ids of [snapshot]'s sections that [registry] knows.
  static Set<String> _known(BackupRegistry registry, BackupSnapshot snapshot) =>
      {
        for (final id in snapshot.sections.keys)
          if (registry.section(id) != null) id,
      };

  /// Lets the user pick a backup file and reads its header.
  Future<void> pickFile() async {
    final PickedBackupFile? file;
    try {
      file = await _files.pick();
    } on BackupFileTooLargeException {
      _fail(BackupRestoreFailure.tooLarge, step: BackupRestoreStep.pick);
      return;
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      _fail(BackupRestoreFailure.unreadable, step: BackupRestoreStep.pick);
      return;
    }
    if (file == null || isClosed) return;
    final BackupHeader header;
    try {
      header = _codec.readHeader(file.bytes);
    } on BackupFormatException catch (error) {
      _fail(
        error.newerVersion
            ? BackupRestoreFailure.newerVersion
            : BackupRestoreFailure.notBackup,
        step: BackupRestoreStep.pick,
      );
      return;
    }
    _bytes = file.bytes;
    emit(
      BackupRestoreState(
        step: BackupRestoreStep.locked,
        fileName: file.name,
        header: header,
      ),
    );
  }

  /// Decrypts the picked file with [passphrase].
  Future<void> unlock(String passphrase) async {
    final bytes = _bytes;
    if (bytes == null || state.step != BackupRestoreStep.locked) return;
    emit(
      state.copyWith(step: BackupRestoreStep.unlocking, failure: () => null),
    );
    final BackupSnapshot snapshot;
    try {
      snapshot = await _codec.decrypt(bytes, passphrase);
    } on BackupPassphraseException {
      _fail(
        BackupRestoreFailure.wrongPassphrase,
        step: BackupRestoreStep.locked,
      );
      return;
    } on BackupFormatException catch (error) {
      _fail(
        error.newerVersion
            ? BackupRestoreFailure.newerVersion
            : BackupRestoreFailure.notBackup,
        step: BackupRestoreStep.locked,
      );
      return;
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        step: BackupRestoreStep.review,
        snapshot: () => snapshot,
        selected: _known(_registry, snapshot),
      ),
    );
  }

  /// Restores the section [id] or leaves it out.
  void toggleSection(String id, {required bool selected}) {
    final snapshot = state.snapshot;
    if (snapshot == null || !_known(_registry, snapshot).contains(id)) return;
    emit(
      state.copyWith(
        selected: selected
            ? {...state.selected, id}
            : ({...state.selected}..remove(id)),
      ),
    );
  }

  /// Restores the selected sections with [mode].
  Future<void> restore(BackupRestoreMode mode) async {
    final snapshot = state.snapshot;
    if (snapshot == null ||
        state.step != BackupRestoreStep.review ||
        state.selected.isEmpty) {
      return;
    }
    emit(state.copyWith(step: BackupRestoreStep.restoring, mode: () => mode));
    try {
      final report = await _registry.restore(
        snapshot,
        mode: mode,
        only: state.selected,
      );
      if (!isClosed) {
        emit(
          state.copyWith(step: BackupRestoreStep.done, report: () => report),
        );
      }
    } on BackupSectionException catch (error, stackTrace) {
      addError(error, stackTrace);
      if (!isClosed) {
        emit(
          state.copyWith(
            step: BackupRestoreStep.done,
            failure: () => BackupRestoreFailure.restore,
            failedSection: () => error.sectionId,
          ),
        );
      }
    }
  }

  /// Picks another file instead.
  void startOver() {
    _bytes = null;
    emit(const BackupRestoreState());
  }

  void _fail(BackupRestoreFailure failure, {required BackupRestoreStep step}) {
    if (isClosed) return;
    emit(state.copyWith(step: step, failure: () => failure));
  }
}
