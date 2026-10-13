import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// A file chosen by the user.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Thrown by [DocumentFileService.shareFile] when the platform cannot share
/// files (e.g. Linux).
class ShareUnsupportedException implements Exception {
  const ShareUnsupportedException();

  @override
  String toString() => 'ShareUnsupportedException';
}

/// Platform file operations used by the document translator, behind an
/// interface so they can be faked in tests.
abstract interface class DocumentFileService {
  /// Lets the user pick one file with one of [extensions] (lower case,
  /// without dot); null when cancelled.
  Future<PickedFile?> pickFile({required List<String> extensions});

  /// Lets the user save [bytes] (a download on the web). Returns false when
  /// the user cancelled.
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  });

  /// Whether [shareFile] is available on this platform.
  bool get canShareFiles;

  /// Opens the system share sheet with a file. [origin] anchors the sheet
  /// on iPad/macOS. Throws [ShareUnsupportedException] when unavailable.
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  });

  /// Copies [text] to the clipboard.
  Future<void> copyText(String text);

  /// Reads plain text from the clipboard (null when empty).
  Future<String?> pasteText();
}

/// [DocumentFileService] backed by `file_picker`, `share_plus` and the
/// Flutter clipboard.
// coverage:ignore-start
class PlatformDocumentFileService implements DocumentFileService {
  const PlatformDocumentFileService();

  /// Android/iOS pickers reject extensions without a known MIME type
  /// (`.srt`, `.vtt`, `.arb`, `.md`), so any file is offered there and the
  /// extension is checked afterwards.
  static bool get _filterByExtension =>
      kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS);

  @override
  Future<PickedFile?> pickFile({required List<String> extensions}) async {
    final filter = _filterByExtension;
    final file = await FilePicker.pickFile(
      type: filter ? FileType.custom : FileType.any,
      allowedExtensions: filter ? extensions : null,
    );
    if (file == null) return null;
    return PickedFile(name: file.name, bytes: await file.readAsBytes());
  }

  @override
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );
    return uri != null;
  }

  @override
  bool get canShareFiles =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.linux;

  @override
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    if (!canShareFiles) throw const ShareUnsupportedException();
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, name: fileName, mimeType: mimeType)],
          fileNameOverrides: [fileName],
          sharePositionOrigin: origin,
        ),
      );
      // share_plus reports unsupported platforms (old Windows) this way.
      // ignore: avoid_catching_errors
    } on UnimplementedError {
      throw const ShareUnsupportedException();
    }
  }

  @override
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    return text == null || text.isEmpty ? null : text;
  }
}

// coverage:ignore-end
