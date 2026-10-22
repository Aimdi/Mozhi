// Static checks of the system entry points (share targets, the translucent
// quick translate window, the web share target) that a build does not
// make: the manifest and Kotlin constants against the Dart side. Paths are
// relative to the package root, where `flutter test` runs.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';

const _main = 'android/app/src/main';
const _kotlin = '$_main/kotlin/io/github/aimdi/mozhi';

String _read(String path) => File(path).readAsStringSync();

String _uncommented(String xml) =>
    xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

Map<String, String> _attributes(String tag) => {
  for (final match in RegExp(r'android:(\w+)="([^"]*)"').allMatches(tag))
    match[1]!: match[2]!,
};

/// The `<activity>` / `<activity-alias>` named [name]: its attributes and
/// its body.
({Map<String, String> attributes, String body}) _component(
  String manifest,
  String element,
  String name,
) {
  final match = RegExp(
    '<$element\\b([^>]*android:name="${RegExp.escape(name)}"[^>]*)>'
    '(.*?)</$element>',
    dotAll: true,
  ).firstMatch(_uncommented(manifest));
  expect(match, isNotNull, reason: '$element $name');
  return (attributes: _attributes(match![1]!), body: match[2]!);
}

/// `name -> resource/value` of the `<meta-data>` in [body].
Map<String, String> _metaData(String body) => {
  for (final match in RegExp(r'<meta-data\b([^>]*)/?>').allMatches(body))
    _attributes(match[1]!)['name']!:
        _attributes(match[1]!)['resource'] ?? _attributes(match[1]!)['value']!,
};

List<String> _actions(String body) => [
  for (final match in RegExp(r'<action\b([^>]*)/?>').allMatches(body))
    _attributes(match[1]!)['name']!,
];

List<String> _mimeTypes(String body) => [
  for (final match in RegExp(r'<data\b([^>]*)/?>').allMatches(body))
    ?_attributes(match[1]!)['mimeType'],
];

/// A `const val` of [file]: a string, or a Long product such as
/// `60L * 60 * 1000`.
Object _constant(String file, String name) {
  final match = RegExp('const val $name = ([^\\n]+)')
      .firstMatch(_read('$_kotlin/$file'));
  expect(match, isNotNull, reason: '$name in $file');
  final value = match![1]!.trim();
  if (value.startsWith('"')) return value.substring(1, value.length - 1);
  return value
      .split('*')
      .map((factor) => int.parse(factor.trim().replaceAll('L', '')))
      .reduce((a, b) => a * b);
}

void main() {
  late String manifest;

  setUpAll(() => manifest = _read('$_main/AndroidManifest.xml'));

  group('text selections', () {
    test('open the translucent quick translate window', () {
      final quick = _component(manifest, 'activity', '.QuickTranslateActivity');
      expect(quick.attributes['exported'], 'true');
      expect(quick.attributes['theme'], '@style/TransparentTheme');
      expect(quick.attributes['excludeFromRecents'], 'true');
      expect(_actions(quick.body), ['android.intent.action.PROCESS_TEXT']);
      expect(_mimeTypes(quick.body), ['text/plain']);
      expect(_metaData(quick.body), {
        'io.flutter.embedding.android.NormalTheme': '@style/TransparentTheme',
        'flutter_deeplinking_enabled': 'false',
      });
    });

    test('"Translate offline" uses the same window', () {
      final alias = _component(
        manifest,
        'activity-alias',
        '.TranslateOfflineActivity',
      );
      expect(alias.attributes['targetActivity'], '.QuickTranslateActivity');
      expect(alias.attributes['exported'], 'true');
      expect(_actions(alias.body), ['android.intent.action.PROCESS_TEXT']);
      expect(
        _metaData(alias.body)['io.flutter.embedding.android.NormalTheme'],
        '@style/TransparentTheme',
      );
    });

    test('no longer reach the opaque main activity', () {
      final main = _component(manifest, 'activity', '.MainActivity');
      expect(
        _actions(main.body),
        isNot(contains('android.intent.action.PROCESS_TEXT')),
      );
      expect(
        _actions(main.body),
        isNot(contains('android.intent.action.SEND')),
      );
    });

    test('the window shares the main activity and the Dart names', () {
      expect(
        _read('$_kotlin/MainActivity.kt'),
        contains('open class MainActivity : FlutterActivity()'),
      );
      final quick = _read('$_kotlin/QuickTranslateActivity.kt');
      expect(quick, contains('class QuickTranslateActivity : MainActivity()'));
      expect(quick, contains('BackgroundMode.transparent'));
      expect(
        _constant('QuickTranslateActivity.kt', 'ROUTE'),
        AppRoutes.quickTranslate,
      );
      expect(
        _constant('QuickTranslateActivity.kt', 'CHANNEL'),
        QuickTranslateHost.channelName,
      );
    });

    test('the window theme is translucent', () {
      final styles = _read('$_main/res/values/styles.xml');
      final theme = RegExp(
        '<style name="TransparentTheme"[^>]*>(.*?)</style>',
        dotAll: true,
      ).firstMatch(styles);
      expect(theme, isNotNull);
      expect(
        theme![0],
        contains('parent="@android:style/Theme.Translucent.NoTitleBar"'),
      );
      expect(
        theme[1],
        contains('<item name="android:windowIsTranslucent">true</item>'),
      );
      expect(theme[1], contains('@android:color/transparent</item>'));
    });
  });

  group('the share sheet', () {
    test('takes text, images and text documents', () {
      final share = _component(manifest, 'activity', '.ShareReceiverActivity');
      expect(share.attributes['exported'], 'true');
      expect(share.attributes['theme'], '@style/TransparentTheme');
      expect(_actions(share.body), ['android.intent.action.SEND']);
      expect(
        _mimeTypes(share.body),
        unorderedEquals([
          'text/*',
          'image/*',
          'application/x-subrip',
          'application/json',
        ]),
      );
    });

    test('stores files where the app takes them from', () {
      const file = 'ShareReceiverActivity.kt';
      expect(_constant(file, 'SHARED_FOLDER'), SharedFiles.folder);
      expect(_constant(file, 'TOKEN_PARAMETER'), SharedFiles.parameter);
      expect(
        _constant(file, 'MAX_AGE_MILLIS'),
        SharedFiles.maxAge.inMilliseconds,
      );
      expect(_constant(file, 'MAX_IMAGE_BYTES'), SharedFiles.maxBytes);
      expect(
        _constant(file, 'MAX_DOCUMENT_BYTES') as int,
        lessThanOrEqualTo(SharedFiles.maxBytes),
      );
      final source = _read('$_kotlin/$file');
      // Never a file:// path or one of Mozhi's own providers.
      expect(source, contains('ContentResolver.SCHEME_CONTENT'));
      expect(source, contains('provider?.packageName == packageName'));
    });

    test('opens the image and document screens with the token', () {
      const token = '0123456789abcdef0123456789abcdef';
      for (final (screen, location) in [
        ('image', AppRoutes.sharedImage(token)),
        ('documents', AppRoutes.sharedDocument(token)),
      ]) {
        final link = Uri.parse('mozhi://$screen?shared=$token');
        expect(appRedirect(link, null), location);
        expect(isLaunchLocation(Uri.parse(location)), isFalse);
      }
      expect(
        _read('$_kotlin/ShareReceiverActivity.kt'),
        contains('"image" else "documents"'),
      );
    });
  });

  group('web manifest', () {
    late Map<String, Object?> web;

    setUpAll(
      () =>
          web = jsonDecode(_read('web/manifest.json')) as Map<String, Object?>,
    );

    test('uses the light look for the title bar and the splash', () {
      // The installed app's title bar matches the default app bar (the
      // page colour), like the splash; index.html sets the dark one.
      expect(web['theme_color'], '#FFFFFF');
      expect(web['background_color'], '#FFFFFF');
    });

    test('shares text into the translate screen', () {
      final target = web['share_target']! as Map<String, Object?>;
      expect(target['method'], 'GET');
      expect(target['action'], './');
      final params = target['params']! as Map<String, Object?>;
      expect(params['text'], 'text');
      // What the browser opens, and how the app reads it.
      final link = TranslateLink.fromUri(
        Uri.parse('https://example.org/app/?title=&text=hola%20mundo&url='),
      );
      expect(link?.text, 'hola mundo');
    });
  });
}
