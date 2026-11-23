import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/notification_translate/cubit/notification_translate_settings_cubit.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:mozhi/notification_translate/data/notification_translate_runner.dart';
import 'package:mozhi/notification_translate/view/notification_translate_settings.dart';
import 'package:translation_repository/translation_repository.dart';

final class _FakeControls implements NotificationTranslateControls {
  new({this.isSupported = true, this.hasAccess = false, this.enabled = false});

  @override
  bool isSupported;
  bool hasAccess;
  bool enabled;
  int openedSettings = 0;
  final List<({int id, String title, String translation})> posted = [];
  final StreamController<IncomingNotification> controller =
      StreamController<IncomingNotification>.broadcast();

  @override
  Future<NotificationTranslateStatus> status() async =>
      NotificationTranslateStatus(hasAccess: hasAccess, enabled: enabled);

  @override
  Future<void> setEnabled({required bool enabled}) async {
    this.enabled = enabled;
  }

  @override
  Future<bool> openAccessSettings() async {
    openedSettings++;
    return true;
  }

  @override
  Future<void> postTranslation({
    required int id,
    required String title,
    required String translation,
  }) async {
    posted.add((id: id, title: title, translation: translation));
  }

  @override
  Stream<IncomingNotification> get notifications => controller.stream;

  Future<void> dispose() => controller.close();
}

final class _FakeOfflineTranslator implements OfflineTranslator {
  new();

  Set<String> downloaded = const {'en', 'de'};
  String? detected = 'de';
  String result = 'Hello world';
  int translateCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'de', 'fr'};

  @override
  Future<Set<String>> downloadedLanguages() async => downloaded;

  @override
  Future<String?> identifyLanguage(String text) async => detected;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    translateCalls++;
    return result;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('NotificationTranslateRunner', () {
    late _FakeControls controls;
    late _FakeOfflineTranslator offline;
    late NotificationTranslateRunner runner;

    setUp(() {
      controls = _FakeControls(hasAccess: true, enabled: true);
      offline = _FakeOfflineTranslator();
      runner = NotificationTranslateRunner(
        controls: controls,
        offline: offline,
        targetLanguage: () => 'en',
      );
    });

    tearDown(() async {
      await runner.dispose();
      await controls.dispose();
    });

    test('translates foreign notification strictly on device', () async {
      final ok = await runner.handle(
        const IncomingNotification(
          id: 7,
          packageName: 'org.example.chat',
          title: 'Alice',
          text: 'Hallo Welt',
        ),
      );
      expect(ok, isTrue);
      expect(offline.translateCalls, 1);
      expect(controls.posted, hasLength(1));
      expect(controls.posted.single.id, 7);
      expect(controls.posted.single.title, 'Alice');
      expect(controls.posted.single.translation, 'Hello world');
    });

    test('skips notifications already in target language', () async {
      offline.detected = 'en';
      final ok = await runner.handle(
        const IncomingNotification(
          id: 8,
          packageName: 'org.example.chat',
          title: 'Bob',
          text: 'Already English',
        ),
      );
      expect(ok, isFalse);
      expect(offline.translateCalls, 0);
      expect(controls.posted, isEmpty);
    });

    test('skips when required offline language is not downloaded', () async {
      offline
        ..detected = 'fr'
        ..downloaded = const {'en', 'de'};
      final ok = await runner.handle(
        const IncomingNotification(
          id: 9,
          packageName: 'org.example.chat',
          title: 'Claire',
          text: 'Bonjour',
        ),
      );
      expect(ok, isFalse);
      expect(offline.translateCalls, 0);
      expect(controls.posted, isEmpty);
    });
  });

  group('NotificationTranslateSettingsCubit', () {
    test(
      'opens notification access settings when permission is missing',
      () async {
        final controls = _FakeControls();
        addTearDown(controls.dispose);
        final cubit = NotificationTranslateSettingsCubit(controls: controls);
        addTearDown(cubit.close);

        await cubit.enable();
        expect(controls.openedSettings, 1);
        expect(cubit.state.status.enabled, isFalse);

        controls.hasAccess = true;
        await cubit.enable();
        expect(cubit.state.status.isActive, isTrue);

        await cubit.disable();
        expect(cubit.state.status.isActive, isFalse);
      },
    );
  });

  group('NotificationTranslateSettingsSection widget', () {
    testWidgets('shows unavailable tile when unsupported', (tester) async {
      final controls = _FakeControls(isSupported: false);
      addTearDown(controls.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: NotificationTranslateSettingsSection(controls: controls),
          ),
        ),
      );
      expect(
        find.byKey(const Key('settings_notification_translate_unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('shows opt-in switch and permission dialog when supported', (
      tester,
    ) async {
      final controls = _FakeControls();
      addTearDown(controls.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: NotificationTranslateSettingsSection(controls: controls),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings_notification_translate')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Open notification access'));
      await tester.pumpAndSettle();
      expect(controls.openedSettings, 1);
    });
  });

  group('Android NotificationTranslateService wiring', () {
    test('declares NotificationListenerService and plugin registration', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(
        manifest,
        contains('android:name=".NotificationTranslateService"'),
      );
      expect(
        manifest,
        contains('android.permission.BIND_NOTIFICATION_LISTENER_SERVICE'),
      );

      final mainActivity = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/MainActivity.kt',
      ).readAsStringSync();
      expect(mainActivity, contains('NotificationTranslatePlugin()'));

      final plugin = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/NotificationTranslatePlugin.kt',
      ).readAsStringSync();
      expect(
        plugin,
        contains(MethodChannelNotificationTranslateControls.channelName),
      );
    });
  });
}
