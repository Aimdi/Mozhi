// Static checks of the Android side of live captions that a build does not
// make: the manifest entries, the Kotlin constants against the Dart side,
// the registration in MainActivity and the strings of every language.
// Paths are relative to the package root, where `flutter test` runs.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/live_captions/data/method_channel_captions_host.dart';

const _main = 'android/app/src/main';
const _kotlin = '$_main/kotlin/io/github/aimdi/mozhi';
const _service = '$_kotlin/LiveCaptionService.kt';
const _plugin = '$_kotlin/LiveCaptionsPlugin.kt';

String _read(String path) => File(path).readAsStringSync();

String _uncommented(String xml) =>
    xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

/// [kotlin] without its comments.
String _code(String kotlin) => kotlin
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

Map<String, String> _attributes(String tag) => {
  for (final match in RegExp(r'android:(\w+)="([^"]*)"').allMatches(tag))
    match[1]!: match[2]!,
};

/// A string `const val` of [file].
String _constant(String file, String name) {
  final match = RegExp('const val $name = "([^"]*)"').firstMatch(_read(file));
  expect(match, isNotNull, reason: '$name in $file');
  return match![1]!;
}

void main() {
  group('manifest', () {
    final manifest = _uncommented(_read('$_main/AndroidManifest.xml'));

    test('declares the service: not exported, a media projection', () {
      final tag = RegExp(
        r'<service\b([^>]*android:name="\.LiveCaptionService"[^>]*)>',
      ).firstMatch(manifest);
      expect(tag, isNotNull);
      final attributes = _attributes(tag![1]!);
      expect(attributes['exported'], 'false');
      expect(attributes['foregroundServiceType'], 'mediaProjection');
    });

    test('has the permissions it needs, asked at run time', () {
      final permissions = {
        for (final match in RegExp(
          r'<uses-permission\b[^>]*android:name="([^"]+)"',
        ).allMatches(manifest))
          match[1],
      };
      expect(
        permissions,
        containsAll(<String>[
          'android.permission.RECORD_AUDIO',
          'android.permission.FOREGROUND_SERVICE',
          'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
          'android.permission.SYSTEM_ALERT_WINDOW',
          'android.permission.POST_NOTIFICATIONS',
        ]),
      );
    });
  });

  group('Kotlin', () {
    test('the channels are the Dart ones', () {
      expect(
        _constant(_plugin, 'CHANNEL'),
        MethodChannelCaptionsHost.channelName,
      );
      expect(
        _constant(_plugin, 'AUDIO_CHANNEL'),
        MethodChannelCaptionsHost.audioChannelName,
      );
      expect(
        _constant(_plugin, 'EVENTS_CHANNEL'),
        MethodChannelCaptionsHost.eventsChannelName,
      );
    });

    test('every event and failure has a Dart name', () {
      for (final name in [
        'EVENT_STOP_TAPPED',
        'EVENT_OPEN_TAPPED',
        'EVENT_ENDED',
        'EVENT_LOCKED',
        'EVENT_UNLOCKED',
      ]) {
        expect(
          CaptionBarEvent.parse(_constant(_plugin, name)),
          isNotNull,
          reason: name,
        );
      }
      for (final name in [
        'REASON_UNSUPPORTED',
        'REASON_BUSY',
        'REASON_FOREGROUND',
        'REASON_PROJECTION',
        'REASON_AUDIO',
      ]) {
        expect(
          CaptureFailure.parse(_constant(_service, name)),
          isNot(CaptureFailure.unknown),
          reason: name,
        );
      }
      expect(
        CaptureFailure.parse(_constant(_plugin, 'REASON_PERMISSION')),
        CaptureFailure.permission,
      );
    });

    test('MainActivity registers the plugin', () {
      expect(
        _code(_read('$_kotlin/MainActivity.kt')),
        contains('flutterEngine.plugins.add(LiveCaptionsPlugin())'),
      );
    });

    test("captures other apps' sound only, in ~100 ms blocks at 16 kHz", () {
      final service = _code(_read(_service));
      expect(service, contains('AudioPlaybackCaptureConfiguration.Builder'));
      for (final usage in ['USAGE_MEDIA', 'USAGE_GAME', 'USAGE_UNKNOWN']) {
        expect(service, contains('AudioAttributes.$usage'));
      }
      // Audio only: no picture of the screen.
      expect(service, isNot(contains('createVirtualDisplay')));
      expect(service, contains('const val TARGET_RATE = 16000'));
      expect(service, contains('const val BLOCKS_PER_SECOND = 10'));
      // The bar never takes the keyboard from another app.
      expect(service, contains('FLAG_NOT_FOCUSABLE'));
      expect(service, contains('TYPE_APPLICATION_OVERLAY'));
      // Text in sp: it follows the font size.
      expect(service, contains('COMPLEX_UNIT_SP'));
      // Guarded: AudioPlaybackCapture is Android 10+.
      expect(service, contains('Build.VERSION_CODES.Q'));
    });

    test('the consent is asked every time, then the service starts', () {
      final plugin = _code(_read(_plugin));
      expect(plugin, contains('createScreenCaptureIntent'));
      expect(plugin, contains('Manifest.permission.RECORD_AUDIO'));
      expect(plugin, contains('LiveCaptionService.start('));
    });
  });

  group('resources', () {
    final names = RegExp('<string name="(live_captions_[a-z_]+)"')
        .allMatches(_read('$_main/res/values/strings.xml'))
        .map((match) => match[1]!)
        .toList();

    test('every string the Kotlin uses exists', () {
      final kotlin = _read(_service) + _read(_plugin);
      final used = RegExp(r'R\.string\.(live_captions_[a-z_]+)')
          .allMatches(kotlin)
          .map((match) => match[1]!)
          .toSet();
      expect(used, isNotEmpty);
      expect(names.toSet(), containsAll(used));
    });

    test('are translated in every language', () {
      expect(names, hasLength(8));
      final folders = Directory('$_main/res')
          .listSync()
          .whereType<Directory>()
          .where((dir) => File('${dir.path}/strings.xml').existsSync());
      expect(folders.length, greaterThan(10));
      for (final folder in folders) {
        final strings = _read('${folder.path}/strings.xml');
        for (final name in names) {
          expect(strings, contains('name="$name"'), reason: folder.path);
        }
      }
    });

    test('the drawables and colours it names exist', () {
      final kotlin = _read(_service);
      for (final match in RegExp(
        r'R\.drawable\.([a-z_]+)',
      ).allMatches(kotlin)) {
        expect(
          File('$_main/res/drawable/${match[1]}.xml').existsSync(),
          isTrue,
          reason: match[1],
        );
      }
      final colors = _read('$_main/res/values/live_captions_colors.xml');
      for (final match in RegExp(r'R\.color\.([a-z_]+)').allMatches(kotlin)) {
        expect(colors, contains('name="${match[1]}"'), reason: match[1]);
      }
    });
  });
}
