import 'package:file_picker/file_picker.dart';

/// Lets the user choose model files to import (`file_picker`, any type and
/// several at once).
///
/// On Android the picker copies the chosen files into the app's cache
/// first; [clearCopies] removes those copies after the import.
// coverage:ignore-start
class OfflineModelFilePicker {
  const new();

  /// Local paths of the chosen files (empty when cancelled). [onCopying]
  /// runs when the platform starts copying them (large files take a
  /// moment).
  Future<List<String>> pick({void Function()? onCopying}) async {
    final files = await FilePicker.pickFiles(
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking) onCopying?.call();
      },
    );
    return [for (final file in files) ?file.path];
  }

  /// Deletes the picker's temporary copies (Android).
  Future<void> clearCopies() => FilePicker.clearTemporaryFiles();
}

// coverage:ignore-end
