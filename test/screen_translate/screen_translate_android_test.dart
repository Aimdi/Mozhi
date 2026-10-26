// Static checks of the Android side of "Translate screen" that a build does
// not make: the manifest entries, the Kotlin constants against the Dart
// side, the launcher shortcut and the strings of every language. Paths are
// relative to the package root, where `flutter test` runs.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app_lock/data/app_lock_windows.dart';
import 'package:mozhi/screen_translate/screen_translate.dart';

const _main = 'android/app/src/main';
const _kotlin = '$_main/kotlin/io/github/aimdi/mozhi';

String _read(String path) => File(path).readAsStringSync();

String _uncommented(String xml) =>
    xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

Map<String, String> _attributes(String tag) => {
  for (final match in RegExp(r'android:(\w+)="([^"]*)"').allMatches(tag))
    match[1]!: match[2]!,
};

/// The `<element>` named [name] in the manifest: attributes and body.
({Map<String, String> attributes, String body}) _component(
  String manifest,
  String element,
  String name,
) {
  final xml = _uncommented(manifest);
  final start = RegExp(
    '<$element\\b([^>]*android:name="${RegExp.escape(name)}"[^>]*?)(/?)>',
    dotAll: true,
  ).firstMatch(xml);
  expect(start, isNotNull, reason: '$element $name');
  if (start![2] == '/') return (attributes: _attributes(start[1]!), body: '');
  final end = xml.indexOf('</$element>', start.end);
  return (
    attributes: _attributes(start[1]!),
    body: xml.substring(start.end, end),
  );
}

/// [kotlin] without its comments.
String _code(String kotlin) => kotlin
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The argument lists of the calls of [name] in [source] (balanced
/// parentheses).
List<String> _calls(String source, String name) {
  final calls = <String>[];
  var from = 0;
  while (true) {
    final start = source.indexOf(name, from);
    if (start < 0) return calls;
    final open = source.indexOf('(', start);
    var depth = 0;
    var end = open;
    for (; end < source.length; end++) {
      if (source[end] == '(') depth++;
      if (source[end] == ')' && --depth == 0) break;
    }
    calls.add(source.substring(open + 1, end));
    from = end;
  }
}

/// A string `const val` of [file].
String _constant(String file, String name) {
  final match = RegExp('const val $name = "([^"]*)"')
      .firstMatch(_read('$_kotlin/$file'));
  expect(match, isNotNull, reason: '$name in $file');
  return match![1]!;
}

void main() {
  late String manifest;

  setUpAll(() => manifest = _read('$_main/AndroidManifest.xml'));

  group('the window', () {
    test('is a translucent MainActivity no other app can start', () {
      final window = _component(
        manifest,
        'activity',
        '.ScreenTranslateActivity',
      );
      expect(window.attributes['exported'], 'false');
      expect(window.attributes['theme'], '@style/TransparentTheme');
      expect(window.attributes['excludeFromRecents'], 'true');
      expect(window.attributes['taskAffinity'], '');
      expect(window.attributes['configChanges'], contains('orientation'));
      expect(window.body, contains('io.flutter.embedding.android.NormalTheme'));
      expect(window.body, contains('flutter_deeplinking_enabled'));
      expect(window.body, isNot(contains('<intent-filter')));
      final source = _read('$_kotlin/ScreenTranslateActivity.kt');
      expect(
        source,
        contains('class ScreenTranslateActivity : MainActivity()'),
      );
      expect(source, contains('BackgroundMode.transparent'));
    });

    test('shares the route and the channel names with Dart', () {
      const file = 'ScreenTranslateActivity.kt';
      expect(_constant(file, 'ROUTE'), AppRoutes.screenTranslate);
      expect(_constant(file, 'ROUTE'), ScreenTranslateHost.location);
      // The app lock knows the window by the same route.
      expect(screenTranslateLocation, ScreenTranslateHost.location);
      expect(_constant(file, 'CHANNEL'), ScreenTranslateHost.channelName);
      expect(_constant(file, 'STATUS_OK'), 'ok');
      expect(_constant(file, 'STATUS_DECLINED'), 'declined');
      expect(_constant(file, 'STATUS_FAILED'), 'failed');
      expect(
        _constant('ScreenTranslatePlugin.kt', 'CHANNEL'),
        MethodChannelScreenTranslateControls.channelName,
      );
      for (final result in TileRequestResult.values) {
        expect(
          _read('$_kotlin/ScreenTranslatePlugin.kt'),
          contains('"${result.name}"'),
          reason: result.name,
        );
      }
    });

    test('the plugin is registered in every window', () {
      expect(
        _read('$_kotlin/MainActivity.kt'),
        contains('flutterEngine.plugins.add(ScreenTranslatePlugin())'),
      );
    });

    test('asks for consent every time, for the whole display', () {
      final source = _read('$_kotlin/ScreenTranslateActivity.kt');
      expect(source, contains('createScreenCaptureIntent('));
      expect(source, contains('createConfigForDefaultDisplay()'));
      expect(source, contains('FLAG_ACTIVITY_CLEAR_TASK'));
    });
  });

  group('the capture', () {
    test('is a mediaProjection foreground service of the app only', () {
      final service = _component(manifest, 'service', '.ScreenCaptureService');
      expect(service.attributes['exported'], 'false');
      expect(service.attributes['foregroundServiceType'], 'mediaProjection');
      final source = _read('$_kotlin/ScreenCaptureService.kt');
      expect(source, contains('FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION'));
      // Android 14: the callback before the virtual display.
      expect(
        source.indexOf('registerCallback('),
        lessThan(source.indexOf('createVirtualDisplay(')),
      );
      // The foreground first, then the projection.
      expect(
        source.indexOf('startInForeground()'),
        lessThan(source.indexOf('getMediaProjection(')),
      );
    });

    test('keeps the screenshot in the private cache only', () {
      final source = _read('$_kotlin/ScreenCaptures.kt');
      expect(source, contains('File(context.cacheDir, FOLDER)'));
      for (final file in [
        'ScreenCaptures.kt',
        'ScreenCaptureService.kt',
        'ScreenTranslateActivity.kt',
      ]) {
        final kotlin = _code(_read('$_kotlin/$file'));
        expect(kotlin, isNot(contains('MediaStore')), reason: file);
        expect(kotlin, isNot(contains('getExternal')), reason: file);
      }
    });

    test('a leftover of an earlier app process goes at the next start', () {
      // Every window (MainActivity and the windows derived from it) sweeps
      // once per process, on a thread of its own, sparing this process's
      // files, which are known before they exist.
      final main = _code(_read('$_kotlin/MainActivity.kt'));
      expect(main, contains('ScreenCaptures.sweepLeftovers(this)'));
      final captures = _code(_read('$_kotlin/ScreenCaptures.kt'));
      final sweep = captures.substring(
        captures.indexOf('fun sweepLeftovers('),
        captures.indexOf('fun deleteAll('),
      );
      expect(sweep, contains('if (leftoversSwept) return'));
      expect(sweep, contains('thread(name = SWEEP_THREAD)'));
      expect(sweep, contains('!in ownFiles'));
      final newFile = captures.substring(
        captures.indexOf('fun newFile('),
        captures.indexOf('fun sweepLeftovers('),
      );
      expect(
        newFile.indexOf('ownFiles.add(name)'),
        allOf(isNonNegative, lessThan(newFile.indexOf('return File('))),
      );
      // The window's own sweep stays too.
      expect(
        _code(_read('$_kotlin/ScreenTranslateActivity.kt')),
        contains('ScreenCaptures.deleteAll(this)'),
      );
    });
  });

  group('the bubble', () {
    test('is a specialUse foreground service that names its use', () {
      final service = _component(
        manifest,
        'service',
        '.TranslateBubbleService',
      );
      expect(service.attributes['exported'], 'false');
      expect(service.attributes['foregroundServiceType'], 'specialUse');
      expect(
        service.body,
        contains('android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"'),
      );
      final source = _read('$_kotlin/TranslateBubbleService.kt');
      expect(source, contains('FOREGROUND_SERVICE_TYPE_SPECIAL_USE'));
      expect(source, contains('Settings.canDrawOverlays'));
    });

    test('links its notification to its settings row', () {
      final link = Uri.parse(
        _constant('TranslateBubbleService.kt', 'SETTINGS_LINK'),
      );
      final location = deepLinkLocation(link);
      expect(
        location,
        '/settings/general?row=${ScreenTranslateAnchors.bubble}',
      );
    });

    test('its long press reads the clipboard in a window of its own', () {
      final reader = _component(
        manifest,
        'activity',
        '.BubbleClipboardActivity',
      );
      expect(reader.attributes['exported'], 'false');
      expect(reader.attributes['theme'], '@style/TransparentTheme');
      expect(reader.attributes['noHistory'], 'true');
      final source = _read('$_kotlin/BubbleClipboardActivity.kt');
      expect(source, contains('onWindowFocusChanged'));
      expect(source, contains('QuickTranslateActivity::class.java'));
      expect(source, contains('EXTRA_PROCESS_TEXT_READONLY, true'));
    });

    test('every PendingIntent is immutable', () {
      for (final file in [
        'TranslateBubbleService.kt',
        'TranslateScreenTileService.kt',
      ]) {
        final calls = _calls(
          _code(_read('$_kotlin/$file')),
          'PendingIntent.get',
        );
        expect(calls, isNotEmpty, reason: file);
        for (final call in calls) {
          expect(call, contains('FLAG_IMMUTABLE'), reason: file);
        }
      }
    });
  });

  group('the tile', () {
    test('is a Quick Settings tile of the system only', () {
      final tile = _component(
        manifest,
        'service',
        '.TranslateScreenTileService',
      );
      expect(tile.attributes['exported'], 'true');
      expect(
        tile.attributes['permission'],
        'android.permission.BIND_QUICK_SETTINGS_TILE',
      );
      expect(tile.attributes['icon'], '@drawable/ic_tile_translate_screen');
      expect(
        tile.body,
        contains('android.service.quicksettings.action.QS_TILE'),
      );
    });
  });

  group('the launcher shortcut', () {
    for (final (sourceSet, package) in [
      ('main', 'io.github.aimdi.mozhi'),
      ('staging', 'io.github.aimdi.mozhi.stg'),
      ('development', 'io.github.aimdi.mozhi.dev'),
    ]) {
      test('opens the window ($sourceSet)', () {
        final xml = _uncommented(
          _read('android/app/src/$sourceSet/res/xml/shortcuts.xml'),
        );
        final shortcut = RegExp(
          r'<shortcut\b[^>]*android:shortcutId="translate_screen"[^>]*>'
          '(.*?)</shortcut>',
          dotAll: true,
        ).firstMatch(xml);
        expect(shortcut, isNotNull);
        final intent = _attributes(
          RegExp(r'<intent\b([^>]*)>').firstMatch(shortcut![1]!)![1]!,
        );
        expect(
          intent['action'],
          _constant('ScreenTranslateActivity.kt', 'ACTION_TRANSLATE_SCREEN'),
        );
        expect(intent['targetPackage'], package);
        expect(
          intent['targetClass'],
          'io.github.aimdi.mozhi.ScreenTranslateActivity',
        );
      });
    }
  });

  test('every Android language has the strings', () {
    final names = RegExp(r'<string name="(\w+)"')
        .allMatches(_read('$_main/res/values/strings.xml'))
        .map((m) => m[1]!)
        .where(
          (name) =>
              name.contains('translate_screen') ||
              name.startsWith('notification_') ||
              name.startsWith('bubble_'),
        )
        .toList();
    expect(names, hasLength(17));
    final folders = Directory('$_main/res')
        .listSync()
        .whereType<Directory>()
        .where((dir) => File('${dir.path}/strings.xml').existsSync());
    for (final folder in folders) {
      final strings = _read('${folder.path}/strings.xml');
      for (final name in names) {
        expect(strings, contains('name="$name"'), reason: folder.path);
      }
    }
  });

  test('the drawables it names exist', () {
    for (final name in [
      'ic_tile_translate_screen',
      'ic_shortcut_translate_screen',
      'ic_shortcut_translate_screen_foreground',
      'ic_bubble_translate',
      'ic_bubble_remove',
      'bubble_background',
      'bubble_remove_background',
    ]) {
      expect(
        File('$_main/res/drawable/$name.xml').existsSync(),
        isTrue,
        reason: name,
      );
    }
    expect(
      _read('$_main/res/values/ids.xml'),
      contains('name="bubble_action_remove"'),
    );
  });
}
