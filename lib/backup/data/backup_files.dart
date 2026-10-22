import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/backup/data/backup_codec.dart';

/// A backup file chosen by the user.
class PickedBackupFile {
  const new({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// The file is larger than any backup ([BackupCodec.maxFileLength]).
class BackupFileTooLargeException implements Exception {
  const new();

  @override
  String toString() => 'BackupFileTooLargeException';
}

/// Picking and saving backup files, behind an interface so tests can fake
/// them.
abstract interface class BackupFiles {
  /// Lets the user pick a backup file; null when cancelled. Throws
  /// [BackupFileTooLargeException] for a file over
  /// [BackupCodec.maxFileLength].
  Future<PickedBackupFile?> pick();

  /// Lets the user save [bytes] as [fileName] ([BackupCodec.mimeType]):
  /// the system's save dialog on Android, a download in the web app.
  /// Returns false when the user cancelled.
  Future<bool> save({required String fileName, required Uint8List bytes});
}

/// [BackupFiles] backed by `file_picker`.
// coverage:ignore-start
class PlatformBackupFiles implements BackupFiles {
  const new();

  @override
  Future<PickedBackupFile?> pick() async {
    // Android's picker knows no MIME type for .mozhibackup: any file there.
    final file = await FilePicker.pickFile(
      type: kIsWeb ? FileType.custom : FileType.any,
      allowedExtensions: kIsWeb ? const [BackupCodec.fileExtension] : null,
    );
    if (file == null) return null;
    final length = await file.length();
    if (length != null && length > BackupCodec.maxFileLength) {
      throw const BackupFileTooLargeException();
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > BackupCodec.maxFileLength) {
      throw const BackupFileTooLargeException();
    }
    return PickedBackupFile(name: file.name, bytes: bytes);
  }

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
    // The web starts a download and never says where it went.
    return kIsWeb || uri != null;
  }
}

// coverage:ignore-end
