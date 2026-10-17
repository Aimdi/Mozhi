import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import 'helpers/golden_helpers.dart';

/// Share of differing pixels a screenshot may have and still match its
/// golden (anti-aliasing can differ slightly between machines).
const double goldenTolerance = 0.005;

/// Runs the golden tests (this directory only) with real fonts and a
/// comparator that tolerates [goldenTolerance] of differing pixels.
///
/// flutter_test draws all text in its block test font by default. Here
/// Roboto (under the app theme's font family and `Roboto`) and the
/// Material Icons font are loaded from the Flutter SDK's cache
/// (`<FLUTTER_ROOT>/bin/cache/artifacts/material_fonts`). When they cannot
/// be found the golden tests are skipped ([goldenSkipReason]) instead of
/// failing on a different machine.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fonts = _materialFontsDirectory();
  if (fonts == null) {
    goldenSkipReason =
        'Golden tests skipped: the Material fonts were not found under '
        r'$FLUTTER_ROOT/bin/cache/artifacts/material_fonts (run '
        '`flutter precache` or set FLUTTER_ROOT).';
  } else if (await _loadFonts(fonts) case final missing?) {
    goldenSkipReason = 'Golden tests skipped: $missing';
  } else {
    goldenSkipReason = null;
  }
  final comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenComparator(
      // Any file in the test's directory: goldens resolve against it.
      comparator.basedir.resolve('golden_test.dart'),
      tolerance: goldenTolerance,
    );
  }
  await testMain();
}

/// The SDK's `material_fonts` directory: from `FLUTTER_ROOT` (set by
/// `flutter test`) or, failing that, from the test runner's location
/// (`<FLUTTER_ROOT>/bin/cache/artifacts/engine/<platform>/flutter_tester`).
Directory? _materialFontsDirectory() {
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?
        when root.isNotEmpty)
      root,
  ];
  var dir = File(Platform.resolvedExecutable).absolute.parent;
  while (dir.parent.path != dir.path) {
    roots.add(dir.path);
    dir = dir.parent;
  }
  for (final root in roots) {
    final fonts = Directory('$root/bin/cache/artifacts/material_fonts');
    if (fonts.existsSync()) return fonts;
  }
  return null;
}

/// Loads Roboto and Material Icons from [directory]; returns what is
/// missing, or null when both were loaded.
Future<String?> _loadFonts(Directory directory) async {
  final files = directory.listSync().whereType<File>().toList();
  bool isRoboto(File file) {
    final name = file.uri.pathSegments.last;
    return name.startsWith('Roboto-') && name.endsWith('.ttf');
  }

  final roboto = files.where(isRoboto).toList();
  final icons = File('${directory.path}/MaterialIcons-Regular.otf');
  if (roboto.isEmpty) return 'no Roboto-*.ttf in ${directory.path}.';
  if (!icons.existsSync()) return 'no ${icons.path}.';

  // The app theme does not name a family: its text styles come from the
  // platform's typography (Roboto on Android, the test platform).
  final appFamily = AppThemes.fromSettings(const AppSettings())
      .light
      .textTheme
      .bodyMedium
      ?.fontFamily;
  for (final family in {'Roboto', ?appFamily}) {
    final loader = FontLoader(family);
    for (final file in roboto) {
      loader.addFont(_bytesOf(file));
    }
    await loader.load();
  }
  final iconLoader = FontLoader(Icons.add.fontFamily ?? 'MaterialIcons')
    ..addFont(_bytesOf(icons));
  await iconLoader.load();
  return null;
}

Future<ByteData> _bytesOf(File file) async =>
    ByteData.sublistView(await file.readAsBytes());

/// A [LocalFileComparator] that accepts screenshots differing from their
/// golden in at most [tolerance] (a share, 0.005 = 0.5 %) of the pixels,
/// and prints the difference when there is one.
class TolerantGoldenComparator extends LocalFileComparator {
  new(super.testFile, {required this.tolerance});

  /// Largest accepted share of differing pixels.
  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    try {
      if (result.passed) return true;
      final percent = (result.diffPercent * 100).toStringAsFixed(3);
      final limit = (tolerance * 100).toStringAsFixed(1);
      if (result.diffPercent <= tolerance) {
        debugPrint(
          'Golden $golden: $percent % of pixels differ (accepted, ≤ $limit %).',
        );
        return true;
      }
      final error = await generateFailureOutput(result, golden, basedir);
      throw FlutterError('$error\n$percent % of pixels differ (> $limit %).');
    } finally {
      result.dispose();
    }
  }
}
