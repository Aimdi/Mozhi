// Static checks of the Android project (android/app) that a build does not
// make: the launcher shortcuts against the router and MainActivity, the
// per-app language list against the app's locales, and the manifest
// entries real devices need (package visibility, permissions, backup).
// Paths are relative to the package root, where `flutter test` runs.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/conversation/view/conversation_page.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart';
import 'package:mozhi/image_translate/models/picked_image.dart'
    show ImagePickSource;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';

import '../app/mocks.dart';

const _app = 'android/app';
const _manifest = '$_app/src/main/AndroidManifest.xml';
const _mainActivity =
    '$_app/src/main/kotlin/io/github/aimdi/mozhi/MainActivity.kt';

/// Source sets with a shortcuts.xml, and their product flavour.
const _shortcutFlavors = {
  'main': 'production',
  'staging': 'staging',
  'development': 'development',
};

String _read(String path) => File(path).readAsStringSync();

/// [xml] without its comments.
String _uncommented(String xml) =>
    xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

/// The `android:` attributes in [tag] (the text of one start tag).
Map<String, String> _attributes(String tag) => {
  for (final match in RegExp(r'android:(\w+)="([^"]*)"').allMatches(tag))
    match[1]!: match[2]!,
};

/// The start tags `<name …>` in [xml], as attribute maps (not `<name-x …>`).
List<Map<String, String>> _tags(String xml, String name) => [
  for (final match in RegExp(
    '<$name(?=[\\s/>])([^>]*)>',
  ).allMatches(_uncommented(xml)))
    _attributes(match[1]!),
];

/// A string constant of MainActivity.kt.
String _kotlinConstant(String name) {
  final match = RegExp('const val $name = "([^"]*)"')
      .firstMatch(_read(_mainActivity));
  expect(match, isNotNull, reason: '$name in $_mainActivity');
  return match![1]!;
}

/// A `name = "value"` setting of android/app/build.gradle.kts.
String _gradleSetting(String name) =>
    RegExp('\\b$name = "([^"]*)"')
        .firstMatch(_read('$_app/build.gradle.kts'))![1]!;

/// The applicationId of [flavor] (the base id plus its suffix).
String _applicationId(String flavor) {
  final suffix = RegExp(
    'create\\("$flavor"\\) \\{[^}]*applicationIdSuffix = "([^"]*)"',
  ).firstMatch(_read('$_app/build.gradle.kts'));
  expect(suffix, isNotNull, reason: 'flavour $flavor');
  return _gradleSetting('applicationId') + suffix![1]!;
}

/// One `<shortcut>` of a shortcuts.xml: its attributes and its intent's.
typedef _Shortcut = ({
  Map<String, String> shortcut,
  Map<String, String> intent,
});

List<_Shortcut> _shortcuts(String sourceSet) {
  final xml = _uncommented(_read('$_app/src/$sourceSet/res/xml/shortcuts.xml'));
  return [
    for (final match in RegExp(
      r'<shortcut\b([^>]*)>(.*?)</shortcut>',
      dotAll: true,
    ).allMatches(xml))
      (
        shortcut: _attributes(match[1]!),
        intent: _attributes(
          RegExp(r'<intent\b([^>]*)>').firstMatch(match[2]!)![1]!,
        ),
      ),
  ];
}

/// The `mozhi://` links of the shortcuts that open a screen.
List<String> _shortcutLinks() => [
  for (final shortcut in _shortcuts('main'))
    if (shortcut.intent['action'] == 'android.intent.action.VIEW')
      shortcut.intent['data']!,
];

void main() {
  group('launcher shortcuts', () {
    test('the four launchers show are the quickest ways in', () {
      // Most launchers (Pixel, Launcher3) show the first four: the
      // clipboard, the camera, a conversation and the screen. The tabs
      // come after them (Android 7 to 9 publish five: Proofread, sixth,
      // only from Android 10).
      expect(
        [for (final s in _shortcuts('main')) s.shortcut['shortcutId']],
        [
          'translate_clipboard',
          'camera',
          'conversation',
          'translate_screen',
          'dictionary',
          'proofread',
        ],
      );
    });

    test('Camera opens the camera translation like the widget', () {
      final camera = _shortcuts('main')
          .singleWhere((s) => s.shortcut['shortcutId'] == 'camera');
      final widget = RegExp('const val CAMERA_LINK = "([^"]*)"').firstMatch(
        _read(
          '$_app/src/main/kotlin/io/github/aimdi/mozhi/MozhiWidgetProvider.kt',
        ),
      );
      expect(camera.intent['data'], widget![1]);
      final link = Uri.parse(camera.intent['data']!);
      expect(
        appRedirect(link, null),
        AppRoutes.imageTranslate(source: ImagePickSource.camera),
      );
      expect(camera.shortcut['icon'], '@drawable/ic_shortcut_camera');
      for (final icon in [
        'drawable/ic_shortcut_camera.xml',
        'drawable/ic_shortcut_camera_foreground.xml',
        'drawable-anydpi-v26/ic_shortcut_camera.xml',
      ]) {
        expect(File('$_app/src/main/res/$icon').existsSync(), isTrue);
      }
    });

    test('are the same in every flavour but for the package', () {
      final main = _shortcuts('main');
      for (final MapEntry(key: sourceSet, value: flavor)
          in _shortcutFlavors.entries) {
        final shortcuts = _shortcuts(sourceSet);
        expect(shortcuts, hasLength(main.length), reason: sourceSet);
        for (var i = 0; i < main.length; i++) {
          expect(shortcuts[i].shortcut, main[i].shortcut, reason: sourceSet);
          expect(
            shortcuts[i].intent['targetPackage'],
            _applicationId(flavor),
            reason: '$sourceSet: targetPackage must be the applicationId',
          );
          expect(
            {...shortcuts[i].intent}..remove('targetPackage'),
            {...main[i].intent}..remove('targetPackage'),
            reason: sourceSet,
          );
        }
      }
    });

    test('have labels in every Android language', () {
      final names = {
        for (final shortcut in _shortcuts('main')) ...[
          shortcut.shortcut['shortcutShortLabel']!,
          shortcut.shortcut['shortcutLongLabel']!,
        ],
      }.map((label) => label.replaceFirst('@string/', ''));
      final folders = Directory('$_app/src/main/res')
          .listSync()
          .whereType<Directory>()
          .where((dir) => File('${dir.path}/strings.xml').existsSync());
      expect(folders, isNotEmpty);
      for (final folder in folders) {
        final strings = _read('${folder.path}/strings.xml');
        for (final name in names) {
          expect(strings, contains('name="$name"'), reason: folder.path);
        }
      }
    });

    test('translate the clipboard through the non-exported alias', () {
      final clipboard = _shortcuts(
        'main',
      ).singleWhere((s) => s.shortcut['shortcutId'] == 'translate_clipboard');
      final alias = _kotlinConstant('TRANSLATE_CLIPBOARD_ALIAS');
      expect(
        clipboard.intent['action'],
        _kotlinConstant('ACTION_TRANSLATE_CLIPBOARD'),
      );
      expect(clipboard.intent['targetClass'], alias);
      // MainActivity honours the action only through this alias, which
      // other apps can't start.
      final namespace = _gradleSetting('namespace');
      final declared = _tags(
        _read(_manifest),
        'activity-alias',
      ).singleWhere((tag) => '$namespace${tag['name']}' == alias);
      expect(declared['exported'], 'false');
      expect(
        _kotlinConstant('ACTION_VALUE_TRANSLATE_CLIPBOARD'),
        SharedText.translateClipboardAction,
      );
    });

    test('open every tab but Translate (the clipboard one opens it), and '
        'the camera', () {
      final namespace = _gradleSetting('namespace');
      final locations = <String>[];
      for (final shortcut in _shortcuts('main')) {
        if (shortcut.intent['action'] != 'android.intent.action.VIEW') {
          continue;
        }
        expect(shortcut.intent['targetClass'], '$namespace.MainActivity');
        final link = Uri.parse(shortcut.intent['data']!);
        final location = deepLinkLocation(link);
        expect(location, isNotNull, reason: '$link is a mozhi:// link');
        // The router sends the link there, the location stays (it is not
        // redirected again), and no launch redirect (onboarding, the first
        // tab of the user's order) replaces it.
        expect(appRedirect(link, null), location, reason: '$link');
        expect(appRedirect(Uri.parse(location!), null), isNull);
        expect(isLaunchLocation(Uri.parse(location)), isFalse);
        locations.add(location);
      }
      expect(locations, [
        AppRoutes.imageTranslate(source: ImagePickSource.camera),
        AppRoutes.conversation,
        AppRoutes.dictionary,
        AppRoutes.proofread,
      ]);
    });

    group('through the router', () {
      setUpAll(() async {
        registerAppFallbacks();
        await Future.wait(
          DeferredFeatures.all.map((library) => library.load()),
        );
      });

      final pages = {
        AppRoutes.dictionary: DictionaryPage,
        AppRoutes.proofread: ProofreadPage,
        AppRoutes.conversation: ConversationPage,
      };
      // The camera link opens the system camera on arrival (checked
      // above): only the tabs are opened here.
      for (final link in _shortcutLinks().where(
        (link) => pages.containsKey(deepLinkLocation(Uri.parse(link))),
      )) {
        testWidgets('$link opens its tab', (tester) async {
          final env = TestEnvironment();
          final router = createAppRouter();
          addTearDown(router.dispose);
          await tester.pumpWidget(
            env.wrap(
              MaterialApp.router(
                routerConfig: router,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
              ),
            ),
          );
          router.go(link);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));

          final location = router.routerDelegate.currentConfiguration.uri;
          expect(location.toString(), deepLinkLocation(Uri.parse(link)));
          expect(find.byType(pages[location.path]!), findsOneWidget);
          expect(find.byType(AppShell), findsOneWidget);
        });
      }
    });
  });

  group('per-app language (Android 13+)', () {
    test('locales_config.xml lists exactly the app languages', () {
      final config = _read('$_app/src/main/res/xml/locales_config.xml');
      final languages = _tags(config, 'locale')
          // zh-Hans: Flutter picks the `zh` translations by language.
          .map((tag) => tag['name']!.split('-').first)
          .toList();
      expect(languages.toSet(), hasLength(languages.length));
      expect(
        languages.toSet(),
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      );
    });

    test('the manifest points Android to it', () {
      final application = _tags(_read(_manifest), 'application').single;
      expect(application['localeConfig'], '@xml/locales_config');
    });

    test('every app language has translated Android labels', () {
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        // Android still names Indonesian resources with the legacy `in`.
        final folder = locale.languageCode == 'id' ? 'in' : locale.languageCode;
        expect(
          File('$_app/src/main/res/values-$folder/strings.xml').existsSync(),
          isTrue,
          reason: 'values-$folder',
        );
      }
    });
  });

  group('manifest', () {
    late String manifest;

    setUpAll(() => manifest = _read(_manifest));

    test('lets the plugins see the apps they use (Android 11+)', () {
      final queries = RegExp(
        '<queries>(.*?)</queries>',
        dotAll: true,
      ).firstMatch(_uncommented(manifest))![1]!;
      final actions = _tags(queries, 'action').map((tag) => tag['name']);
      expect(
        actions,
        containsAll([
          // speech_to_text: the device's speech recognizers.
          'android.speech.RecognitionService',
          // flutter_tts: the text-to-speech engines.
          'android.intent.action.TTS_SERVICE',
          // The engine's text selection menu items of other apps.
          'android.intent.action.PROCESS_TEXT',
          // image_picker: the camera app.
          'android.media.action.IMAGE_CAPTURE',
          // url_launcher: browsers.
          'android.intent.action.VIEW',
        ]),
      );
      final schemes = _tags(queries, 'data').map((tag) => tag['scheme']);
      expect(schemes, containsAll(['https', 'http']));
    });

    test('asks only for the permissions it uses', () {
      final permissions = _tags(
        manifest,
        'uses-permission',
      ).map((tag) => tag['name']).toSet();
      // No storage or media permissions: the system photo and file pickers
      // need none.
      expect(permissions, {
        'android.permission.INTERNET',
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.RECORD_AUDIO',
        // Live camera (Camera2, asked when the live view opens); with it
        // declared, image_picker asks for it before the camera app opens.
        'android.permission.CAMERA',
        // App lock: the system's biometric prompt (a normal permission).
        'android.permission.USE_BIOMETRIC',
        // Translate screen: the one-shot screenshot (a mediaProjection
        // foreground service) and the opt-in bubble (Display over other
        // apps, a specialUse foreground service, its notification).
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
        'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
        'android.permission.SYSTEM_ALERT_WINDOW',
        'android.permission.POST_NOTIFICATIONS',
      });
      final microphone = _tags(
        manifest,
        'uses-feature',
      ).singleWhere((tag) => tag['name'] == 'android.hardware.microphone');
      expect(microphone['required'], 'false');
      // CAMERA alone would make app stores require a camera.
      final features = {
        for (final tag in _tags(manifest, 'uses-feature'))
          tag['name']: tag['required'],
      };
      for (final camera in [
        'android.hardware.camera.any',
        'android.hardware.camera',
        'android.hardware.camera.autofocus',
      ]) {
        expect(features[camera], 'false', reason: camera);
      }
    });

    test('keeps the data on the device and refuses platform cleartext', () {
      final application = _tags(manifest, 'application').single;
      expect(application['allowBackup'], 'false');
      expect(application['dataExtractionRules'], '@xml/data_extraction_rules');
      expect(application['fullBackupContent'], '@xml/backup_rules');
      expect(application['enableOnBackInvokedCallback'], 'true');
      final security = _read(
        '$_app/src/main/res/xml/network_security_config.xml',
      );
      // Plain http is for Dart's HttpClient only, which ignores this file
      // (the comment in it says why); the network policy in lib/core/network
      // limits it to the local network.
      expect(
        _uncommented(security),
        contains('<base-config cleartextTrafficPermitted="false">'),
      );
    });
  });
}
