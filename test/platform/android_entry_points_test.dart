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
import 'package:mozhi/app_lock/data/app_lock_windows.dart';
import 'package:mozhi/documents/documents.dart'
    show DocumentFormat, DocumentTranslateCubitDefaults;
import 'package:mozhi/platform/shared_text_service.dart';
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

/// [kotlin] without its comments.
String _code(String kotlin) => kotlin
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The body of the Kotlin function [name] of [file] (without comments),
/// from its `fun` to the next `fun` or the end of the class.
String _function(String file, String name) {
  final code = _code(_read('$_kotlin/$file'));
  final start = code.indexOf(RegExp('fun $name\\b'));
  expect(start, isNonNegative, reason: '$name in $file');
  final next = code.indexOf(RegExp(r'\bfun '), start + 4);
  return code.substring(start, next < 0 ? code.length : next);
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

    test('"Improve with Mozhi" uses the same window', () {
      final alias = _component(
        manifest,
        'activity-alias',
        '.ImproveTextActivity',
      );
      expect(alias.attributes['targetActivity'], '.QuickTranslateActivity');
      expect(alias.attributes['exported'], 'true');
      expect(alias.attributes['label'], '@string/improve_with_mozhi');
      expect(_actions(alias.body), ['android.intent.action.PROCESS_TEXT']);
      expect(_mimeTypes(alias.body), ['text/plain']);
      expect(_metaData(alias.body), {
        'io.flutter.embedding.android.NormalTheme': '@style/TransparentTheme',
        'flutter_deeplinking_enabled': 'false',
      });
      expect(
        alias.body,
        contains('<intent-filter android:label="@string/improve_with_mozhi">'),
      );
    });

    test('"Improve with Mozhi" marks the selection for Dart', () {
      expect(
        _constant('MainActivity.kt', 'IMPROVE_TEXT_ALIAS'),
        'io.github.aimdi.mozhi.ImproveTextActivity',
      );
      expect(
        _constant('MainActivity.kt', 'ACTION_VALUE_IMPROVE'),
        SharedText.improveAction,
      );
      expect(
        _constant('MainActivity.kt', 'ACTION_VALUE_TRANSLATE_OFFLINE'),
        SharedText.translateOfflineAction,
      );
      final shared = _function('MainActivity.kt', 'sharedTextOf');
      expect(shared, contains('isImproveText(intent) ->'));
      expect(shared, contains('(KEY_ACTION to ACTION_VALUE_IMPROVE)'));
      final check = _function('MainActivity.kt', 'isImproveText');
      expect(check, contains('it.packageName == packageName'));
      expect(check, contains('it.className == IMPROVE_TEXT_ALIAS'));
    });

    test('the selection labels are translated in every Android language', () {
      final folders = Directory('$_main/res')
          .listSync()
          .whereType<Directory>()
          .where((dir) => File('${dir.path}/strings.xml').existsSync());
      expect(folders, isNotEmpty);
      for (final folder in folders) {
        final strings = _read('${folder.path}/strings.xml');
        for (final name in [
          'translate_with_mozhi',
          'translate_offline',
          'improve_with_mozhi',
        ]) {
          expect(strings, contains('name="$name"'), reason: folder.path);
        }
      }
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
    test('takes text, images, text documents, office files, e-books and '
        'PDFs', () {
      final share = _component(manifest, 'activity', '.ShareReceiverActivity');
      expect(share.attributes['exported'], 'true');
      expect(share.attributes['theme'], '@style/TransparentTheme');
      // Several files at once too (the first is opened).
      expect(_actions(share.body), [
        'android.intent.action.SEND',
        'android.intent.action.SEND_MULTIPLE',
      ]);
      expect(
        _mimeTypes(share.body),
        unorderedEquals([
          'text/*',
          'image/*',
          'application/x-subrip',
          'application/json',
          for (final format in DocumentFormat.values)
            if (format.isBinary) format.mimeType,
          // Translation files (.po, .xliff, .arb, .strings, .xcstrings) as
          // file managers and mail apps type them.
          'application/xml',
          'application/x-xliff+xml',
          'application/xliff+xml',
          'application/x-gettext',
          'application/octet-stream',
        ]),
      );
      // A shared PDF without a name still opens as one.
      expect(
        _read('$_kotlin/ShareReceiverActivity.kt'),
        contains('"application/pdf" -> "pdf"'),
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
        allOf(
          lessThanOrEqualTo(SharedFiles.maxBytes),
          // Office documents and e-books as large as the screen takes.
          greaterThanOrEqualTo(DocumentTranslateCubitDefaults.maxPackageBytes),
        ),
      );
      final source = _read('$_kotlin/$file');
      // Never a file:// path or one of Mozhi's own providers.
      expect(source, contains('ContentResolver.SCHEME_CONTENT'));
      expect(source, contains('provider?.packageName == packageName'));
    });

    test('says why a shared file is missing, and how many were shared', () {
      const file = 'ShareReceiverActivity.kt';
      expect(_constant(file, 'ERROR_PARAMETER'), SharedFiles.errorParameter);
      expect(_constant(file, 'NAME_PARAMETER'), SharedFiles.nameParameter);
      expect(_constant(file, 'COUNT_PARAMETER'), SharedFiles.countParameter);
      expect(
        _constant(file, 'ERROR_TOO_LARGE'),
        SharedFileError.tooLarge.value,
      );
      expect(
        _constant(file, 'ERROR_UNREADABLE'),
        SharedFileError.unreadable.value,
      );
      final source = _code(_read('$_kotlin/$file'));
      expect(source, contains('Intent.ACTION_SEND_MULTIPLE ->'));
      // Too large, unreadable and empty files keep their token.
      expect(source, contains('Stored(token, ERROR_TOO_LARGE, name)'));
      expect(RegExp('return null').hasMatch(_function(file, 'store')), isFalse);
      // The link the router reads.
      final link = Uri.parse(
        'mozhi://documents?shared=0123456789abcdef0123456789abcdef'
        '&shared_error=too_large&name=big%20file.pdf&shared_count=3',
      );
      final location = Uri.parse(appRedirect(link, null)!);
      expect(location.path, AppRoutes.documents);
      expect(
        SharedFileError.tryParse(
          location.queryParameters[SharedFiles.errorParameter],
        ),
        SharedFileError.tooLarge,
      );
      expect(
        location.queryParameters[SharedFiles.nameParameter],
        'big file.pdf',
      );
      expect(SharedFiles.sharedSeveral(location.queryParameters), isTrue);
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

  group('the app lock', () {
    test('every window tells Dart which one it is, whatever the intent', () {
      // The Dart entrypoint argument, from the activity's class.
      expect(
        _constant('MainActivity.kt', 'WINDOW_ARGUMENT'),
        AppLockWindow.entrypointArgumentPrefix,
      );
      for (final (constant, window) in [
        ('WINDOW_MAIN', AppLockWindow.main),
        ('WINDOW_QUICK_TRANSLATE', AppLockWindow.quickTranslate),
        ('WINDOW_SCREEN_TRANSLATE', AppLockWindow.screenTranslate),
      ]) {
        expect(_constant('MainActivity.kt', constant), window.name);
      }
      expect(
        _function('MainActivity.kt', 'getDartEntrypointArgs'),
        contains('listOf(WINDOW_ARGUMENT + lockWindow)'),
      );
      expect(
        _code(_read('$_kotlin/MainActivity.kt')),
        contains('get() = WINDOW_MAIN'),
      );
      for (final (file, constant) in [
        ('QuickTranslateActivity.kt', 'WINDOW_QUICK_TRANSLATE'),
        ('ScreenTranslateActivity.kt', 'WINDOW_SCREEN_TRANSLATE'),
      ]) {
        final code = _code(_read('$_kotlin/$file'));
        expect(
          code,
          matches(
            RegExp(
              r'override val lockWindow: String\s+'
              'get\\(\\) = MainActivity\\.$constant',
            ),
          ),
          reason: file,
        );
        // Their route is their own, never the intent's.
        expect(
          code,
          contains('override fun getInitialRoute(): String = ROUTE'),
        );
      }
      // ... and Dart reads it at start.
      for (final flavor in ['development', 'staging', 'production']) {
        final main = _read('lib/main_$flavor.dart');
        expect(main, contains('Future<void> main(List<String> args)'));
        expect(main, contains('AppLockWindow.declare(args);'));
      }
    });

    test('the main window never starts at the route of another one', () {
      final route = _function('MainActivity.kt', 'getInitialRoute');
      // The `route` extra and deep links, then the data Flutter would take.
      expect(route, contains('super.getInitialRoute()'));
      expect(route, contains('isWindowRoute(route)'));
      expect(route, contains('isWindowRoute(data)'));
      final check = _function('MainActivity.kt', 'isWindowRoute');
      expect(check, contains(r"replace('\\', '/')"));
      expect(check, contains('.pathSegments'));
      expect(check, contains('ignoreCase = true'));
      final names = _code(_read('$_kotlin/MainActivity.kt'));
      expect(names, contains("QuickTranslateActivity.ROUTE.trimStart('/')"));
      expect(names, contains("ScreenTranslateActivity.ROUTE.trimStart('/')"));
      expect(
        _constant('QuickTranslateActivity.kt', 'ROUTE'),
        AppRoutes.quickTranslate,
      );
    });

    test('only pickers, the camera and saving a file are own trips', () {
      final plugin = _code(_read('$_kotlin/AppLockPlugin.kt'));
      final actions = RegExp(
        r'OWN_TRIP_ACTIONS = setOf\((.*?)\)',
        dotAll: true,
      ).firstMatch(plugin)![1]!;
      expect(
        RegExp(r'[\w.]+|"[^"]+"').allMatches(actions).map((m) => m[0]).toList(),
        unorderedEquals([
          'Intent.ACTION_OPEN_DOCUMENT',
          'Intent.ACTION_CREATE_DOCUMENT',
          'Intent.ACTION_OPEN_DOCUMENT_TREE',
          'Intent.ACTION_GET_CONTENT',
          'Intent.ACTION_PICK',
          'MediaStore.ACTION_IMAGE_CAPTURE',
          // The photo picker (MediaStore.ACTION_PICK_IMAGES) and the
          // fallbacks of androidx's PickVisualMedia.
          '"android.provider.action.PICK_IMAGES"',
          '"androidx.activity.result.contract.action.PICK_IMAGES"',
          '"com.google.android.gms.provider.action.PICK_IMAGES"',
        ]),
      );
      // A chooser counts by what it offers: sharing (ACTION_SEND in
      // share_plus's chooser) is an ordinary absence.
      final classify = _function('AppLockPlugin.kt', 'isOwnTripIntent');
      expect(classify, contains('Intent.ACTION_CHOOSER'));
      expect(
        _function('AppLockPlugin.kt', 'chooserTarget'),
        contains('Intent.EXTRA_INTENT'),
      );
      expect(plugin, isNot(contains('ACTION_SEND')));
      expect(
        _function('MainActivity.kt', 'startActivityForResult'),
        contains(
          'noteActivityStartedForResult('
          'ownTrip = isOwnTrip(intent, requestCode))',
        ),
      );
      // Translate screen's consent dialog (an intent without an action).
      expect(
        _function('ScreenTranslateActivity.kt', 'isOwnTrip'),
        contains('requestCode == REQUEST_CONSENT ||'),
      );
    });

    test('a clipboard request carries no clipboard', () {
      // Dart reads it once unlocked (SharedTextHandler).
      final code = _code(_read('$_kotlin/MainActivity.kt'));
      expect(code, isNot(contains('primaryClip')));
      expect(
        _function('MainActivity.kt', 'clipboardPayload'),
        contains('mapOf(KEY_ACTION to ACTION_VALUE_TRANSLATE_CLIPBOARD)'),
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
