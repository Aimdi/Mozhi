import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';

/// The platform parts the backup screens use: the file picker and save
/// dialog ([files]), and the [codec] (with the platform's Argon2id
/// parameters). Tests replace them.
abstract final class BackupServices {
  static BackupFiles files = const PlatformBackupFiles();

  static BackupCodec codec = const BackupCodec();
}
