import 'dart:convert';
import 'dart:io' as io;

import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';

/// Changes the POSIX mode of [path] (e.g. `600`).
typedef Chmod = void Function(String path, String mode);

/// Reads and writes the configuration file.
///
/// The file is written atomically (temporary file + rename) and, on POSIX
/// systems, created with mode 0600 inside a 0700 directory *before* any
/// content is written, because it can contain API keys.
class ConfigStore {
  new({required this.path, this.posix = true, Chmod? chmod})
    : _chmod = chmod ?? _systemChmod;

  /// The default location for [environment]:
  /// `$MOZHI_CONFIG`, else `$XDG_CONFIG_HOME/mozhi/config.json`, else
  /// `%APPDATA%\mozhi\config.json` on Windows, else
  /// `$HOME/.config/mozhi/config.json`.
  ///
  /// Throws a [CliException] when no location can be determined.
  static String defaultPath(
    Map<String, String> environment, {
    required bool isWindows,
  }) {
    String? variable(String name) {
      final value = environment[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final separator = isWindows ? r'\' : '/';
    String join(String directory) {
      final base = directory.endsWith(separator)
          ? directory.substring(0, directory.length - 1)
          : directory;
      return [base, 'mozhi', 'config.json'].join(separator);
    }

    final explicit = variable('MOZHI_CONFIG');
    if (explicit != null) return explicit;
    final xdg = variable('XDG_CONFIG_HOME');
    // The XDG spec says relative paths must be ignored.
    if (xdg != null && (isWindows || xdg.startsWith('/'))) return join(xdg);
    if (isWindows) {
      final appData = variable('APPDATA');
      if (appData != null) return join(appData);
    }
    final home = variable('HOME') ?? variable('USERPROFILE');
    if (home == null) {
      throw const CliException.config(
        'Cannot locate the configuration directory (HOME is not set).',
        hint: 'Set XDG_CONFIG_HOME or MOZHI_CONFIG, or pass --config <file>.',
      );
    }
    return join(isWindows ? home : '$home/.config');
  }

  /// Location of the configuration file.
  final String path;

  /// Whether POSIX file modes apply (false on Windows).
  final bool posix;
  final Chmod _chmod;

  io.File get _file => io.File(path);

  /// Whether something exists at [path] (a directory there is reported as
  /// unreadable by [load]).
  bool get exists =>
      io.FileSystemEntity.typeSync(path) != io.FileSystemEntityType.notFound;

  /// Whether group or others can access the file (POSIX only).
  bool get isExposed {
    if (!posix || !exists) return false;
    return _file.statSync().mode & 0x3f != 0; // 0o077
  }

  /// The stored configuration, or an empty one when there is no file.
  ///
  /// Throws a [CliException] (exit code 78) for unreadable or malformed
  /// files.
  CliConfig load() {
    if (!exists) return const CliConfig();
    try {
      final contents = _file.readAsStringSync();
      if (contents.trim().isEmpty) return const CliConfig();
      final json = jsonDecode(contents);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      return CliConfig.fromJson(json);
    } on FormatException catch (error) {
      throw CliException.config(
        'The configuration file $path is not valid: ${error.message}',
        hint: 'Fix or delete the file.',
      );
    } on io.FileSystemException catch (error) {
      throw CliException.config(
        'Cannot read the configuration file $path: ${error.message}',
      );
    }
  }

  /// Writes [config] atomically with owner-only permissions.
  void save(CliConfig config) {
    final contents =
        '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n';
    final temporary = io.File('$path.${io.pid}.tmp');
    try {
      final directory = _file.parent;
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
        if (posix) _chmod(directory.path, '700');
      }
      // Restrict the (empty) file before the secrets are written to it.
      temporary.writeAsStringSync('');
      if (posix) _chmod(temporary.path, '600');
      temporary
        ..writeAsStringSync(contents, flush: true)
        ..renameSync(path);
    } on io.FileSystemException catch (error) {
      if (temporary.existsSync()) temporary.deleteSync();
      throw CliException.config(
        'Cannot write the configuration file $path: ${error.message}',
      );
    }
  }

  static void _systemChmod(String path, String mode) {
    final io.ProcessResult result;
    try {
      result = io.Process.runSync('chmod', [mode, path]);
    } on io.ProcessException catch (error) {
      throw io.FileSystemException(
        'chmod $mode failed: ${error.message}',
        path,
      );
    }
    if (result.exitCode != 0) {
      throw io.FileSystemException(
        'chmod $mode failed: ${result.stderr}'.trim(),
        path,
      );
    }
  }
}
