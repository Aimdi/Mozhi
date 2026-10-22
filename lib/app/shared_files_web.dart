import 'package:mozhi/app/shared_files.dart';

/// Browsers share text only (the web app's `share_target`): no files.
Future<SharedFile?> takeSharedFile(
  String token, {
  required bool keep,
  required DateTime now,
  Future<String> Function()? cacheDirectory,
}) async => null;
