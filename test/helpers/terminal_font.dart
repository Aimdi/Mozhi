import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mozhi/app/theme.dart';

/// Loads the app's bundled JetBrains Mono (`assets/fonts/jetbrains_mono`)
/// under [kTerminalFontFamily], so terminal-look text is measured as on a
/// device (flutter_test draws every glyph of an unknown family as a 1 em
/// square). Call it from `setUpAll`; it affects only that family.
Future<void> loadTerminalFont() async {
  final files =
      Directory('assets/fonts/jetbrains_mono')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.ttf'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final loader = FontLoader(kTerminalFontFamily);
  for (final file in files) {
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
}
