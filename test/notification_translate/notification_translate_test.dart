import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/notification_translate/cubit/notification_translate_settings_cubit.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:mozhi/notification_translate/data/notification_translate_runner.dart';
import 'package:mozhi/notification_translate/view/notification_translate_settings.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:translation_repository/translation_repository.dart';

final class _FakeControls implements NotificationTranslateControls {
  new({
    this.isSupported = true,
    this.hasAccess = false,
    this.enabled = false,
    this.notificationsAllowed = true,
    List<String>? muted,
  }) : grantNotificationPermissionResult = true,
       preferredTargetLanguage = null,
       muted = List.of(muted ?? const []);

  @override
  bool isSupported;
  bool hasAccess;
  bool enabled;
  bool notificationsAllowed;
  bool grantNotificationPermissionResult;
  final List<String> muted;
  String? preferredTargetLanguage;
  int openedSettings = 0;
  int notificationPermissionRequests = 0;
  final List<({int id, String title, String translation})> posted = [];
  final StreamController<IncomingNotification> controller =
      StreamController<IncomingNotification>.broadcast();

  @override
  Future<NotificationTranslateStatus> status() async =>
      NotificationTranslateStatus(
        hasAccess: hasAccess,
        enabled: enabled,
        notificationsAllowed: notificationsAllowed,
        mutedPackages: List.unmodifiable(muted),
        targetLanguage: preferredTargetLanguage,
      );

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
  Future<bool> requestNotificationPermission() async {
    notificationPermissionRequests++;
    if (grantNotificationPermissionResult) {
      notificationsAllowed = true;
    }
    return grantNotificationPermissionResult;
  }

  @override
  Future<List<String>> mutedPackages() async => List.unmodifiable(muted);

  @override
  Future<void> setPackageMuted(
    String packageName, {
    required bool muted,
  }) async {
    if (muted) {
      if (!this.muted.contains(packageName)) this.muted.add(packageName);
    } else {
      this.muted.remove(packageName);
    }
  }

  @override
  Future<void> setTargetLanguage(String? code) async {
    final trimmed = code?.trim();
    preferredTargetLanguage = (trimmed == null || trimmed.isEmpty)
        ? null
        : trimmed;
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

final class _FakeOfflineTranslator
    implements OfflineTranslator, OfflineLanguageDirections {
  new();

  Set<String> downloaded = const {'en', 'de'};
  @override
  Set<String> supportedLanguages = const {'en', 'de', 'fr', 'zh-CN'};
  @override
  Map<String, OfflineLanguageDirection> oneWayLanguages = const {};
  String? detected = 'de';
  String result = 'Hello world';
  int translateCalls = 0;
  String? lastSource;
  String? lastTarget;
  VoidCallback? onTranslate;

  @override
  bool get isAvailable => true;

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
    lastSource = source;
    lastTarget = target;
    onTranslate?.call();
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
    late bool locked;

    setUp(() {
      locked = false;
      controls = _FakeControls(hasAccess: true, enabled: true);
      offline = _FakeOfflineTranslator();
      runner = NotificationTranslateRunner(
        controls: controls,
        offline: offline,
        targetLanguage: () => 'en',
        isLocked: () => locked,
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

    test('skips translation when App Lock is locked', () async {
      locked = true;
      final ok = await runner.handle(
        const IncomingNotification(
          id: 10,
          packageName: 'org.example.chat',
          title: 'Alice',
          text: 'Hallo Welt',
        ),
      );
      expect(ok, isFalse);
      expect(offline.translateCalls, 0);
      expect(controls.posted, isEmpty);
    });

    test('does not post if App Lock engages during translation', () async {
      offline.onTranslate = () => locked = true;
      final ok = await runner.handle(
        const IncomingNotification(
          id: 11,
          packageName: 'org.example.chat',
          title: 'Alice',
          text: 'Hallo Welt',
        ),
      );
      expect(ok, isFalse);
      expect(offline.translateCalls, 1);
      expect(controls.posted, isEmpty);
    });

    test(
      'matches zh-CN case-insensitively and passes canonical code to engine',
      () async {
        offline
          ..downloaded = const {'en', 'zh-CN'}
          ..detected = 'zh-cn'
          ..result = 'Hello';
        final ok = await runner.handle(
          const IncomingNotification(
            id: 12,
            packageName: 'org.example.chat',
            title: 'Wei',
            text: '你好',
          ),
        );
        expect(ok, isTrue);
        expect(offline.lastSource, 'zh-CN');
        expect(offline.lastTarget, 'en');
      },
    );

    test(
      'checks one-way language direction before calling offline.translate',
      () async {
        offline
          ..downloaded = const {'en', 'az'}
          ..supportedLanguages = const {'en'}
          ..oneWayLanguages = const {'az': OfflineLanguageDirection.intoOnly}
          ..detected = 'az';

        // Translating FROM an intoOnly language must be skipped.
        final fromSkipped = await runner.handle(
          const IncomingNotification(
            id: 13,
            packageName: 'org.example.chat',
            title: 'A',
            text: 'Salam',
          ),
        );
        expect(fromSkipped, isFalse);
        expect(offline.translateCalls, 0);

        // Translating INTO an intoOnly language is allowed.
        controls.preferredTargetLanguage = 'az';
        offline
          ..detected = 'en'
          ..result = 'Salam';
        final intoOk = await runner.handle(
          const IncomingNotification(
            id: 14,
            packageName: 'org.example.chat',
            title: 'A',
            text: 'Hello',
          ),
        );
        expect(intoOk, isTrue);
        expect(offline.lastSource, 'en');
        expect(offline.lastTarget, 'az');
      },
    );

    test('skips notifications from muted packages', () async {
      controls.muted.add('org.example.noisy');
      final ok = await runner.handle(
        const IncomingNotification(
          id: 15,
          packageName: 'org.example.noisy',
          title: 'Bot',
          text: 'Hallo Welt',
        ),
      );
      expect(ok, isFalse);
      expect(offline.translateCalls, 0);
      expect(controls.posted, isEmpty);
    });

    test(
      'uses dedicated target language instead of Translate tab fallback',
      () async {
        controls.preferredTargetLanguage = 'zh-CN';
        offline
          ..downloaded = const {'en', 'de', 'zh-CN'}
          ..detected = 'de'
          ..result = '你好世界';

        final ok = await runner.handle(
          const IncomingNotification(
            id: 16,
            packageName: 'org.example.chat',
            title: 'Alice',
            text: 'Hallo Welt',
          ),
        );
        expect(ok, isTrue);
        expect(offline.lastSource, 'de');
        expect(offline.lastTarget, 'zh-CN');
      },
    );

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
    test('remembers pending enable across Notification Access settings and '
        'requests POST_NOTIFICATIONS on return', () async {
      final controls = _FakeControls(notificationsAllowed: false);
      addTearDown(controls.dispose);
      final cubit = NotificationTranslateSettingsCubit(controls: controls);
      addTearDown(cubit.close);

      await cubit.enable();
      expect(controls.openedSettings, 1);
      expect(cubit.state.status.enabled, isFalse);
      expect(cubit.state.pendingEnable, isTrue);

      // User grants Notification Access in Android Settings and returns.
      controls.hasAccess = true;
      await cubit.refresh();
      expect(controls.notificationPermissionRequests, 1);
      expect(cubit.state.status.isActive, isTrue);
      expect(cubit.state.pendingEnable, isFalse);

      await cubit.disable();
      expect(cubit.state.status.isActive, isFalse);
    });

    test(
      'clears pending enable if user returns without granting access',
      () async {
        final controls = _FakeControls();
        addTearDown(controls.dispose);
        final cubit = NotificationTranslateSettingsCubit(controls: controls);
        addTearDown(cubit.close);

        await cubit.enable();
        expect(cubit.state.pendingEnable, isTrue);

        await cubit.refresh();
        expect(cubit.state.pendingEnable, isFalse);
        expect(cubit.state.status.enabled, isFalse);
      },
    );

    test('updates dedicated target language and muted packages', () async {
      final controls = _FakeControls(
        hasAccess: true,
        enabled: true,
        muted: ['org.example.chat'],
      );
      addTearDown(controls.dispose);
      final cubit = NotificationTranslateSettingsCubit(controls: controls);
      addTearDown(cubit.close);

      await cubit.setTargetLanguage('de');
      expect(cubit.state.status.targetLanguage, 'de');

      await cubit.setTargetLanguage(null);
      expect(cubit.state.status.targetLanguage, isNull);

      await cubit.setPackageMuted('org.example.chat', muted: false);
      expect(cubit.state.status.mutedPackages, isEmpty);
    });
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

    testWidgets(
      'shows no-offline-languages hint when fewer than 2 languages downloaded',
      (tester) async {
        final controls = _FakeControls(hasAccess: true);
        final offline = _FakeOfflineTranslator()..downloaded = const {'en'};
        addTearDown(controls.dispose);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NotificationTranslateSettingsSection(
                controls: controls,
                offline: offline,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const Key('settings_notification_translate_no_offline_hint'),
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Download an offline language in Settings > Offline languages '
            'first.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('allows choosing dedicated target language and unmuting apps', (
      tester,
    ) async {
      final controls = _FakeControls(
        hasAccess: true,
        enabled: true,
        muted: ['org.example.chat'],
      );
      final offline = _FakeOfflineTranslator()
        ..downloaded = const {'en', 'de', 'zh-CN'};
      addTearDown(controls.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: [
                NotificationTranslateSettingsSection(
                  controls: controls,
                  offline: offline,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('settings_notification_translate_no_offline_hint'),
        ),
        findsNothing,
      );
      expect(find.text('Follow Translate tab'), findsOneWidget);

      // Pick dedicated target language.
      await tester.tap(
        find.byKey(
          const Key('settings_notification_translate_target_language'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChoiceDialog.saveKey));
      await tester.pumpAndSettle();
      expect(controls.preferredTargetLanguage, 'de');
      expect(find.text('German'), findsOneWidget);

      // Muted package is displayed and can be unmuted.
      expect(find.text('org.example.chat'), findsOneWidget);
      await tester.tap(find.text('Unmute'));
      await tester.pumpAndSettle();
      expect(controls.muted, isEmpty);
      expect(find.text('org.example.chat'), findsNothing);
    });
  });

  group('Android NotificationTranslateService wiring', () {
    test('declares NotificationListenerService and hardening guards', () {
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
      expect(plugin, contains('POST_NOTIFICATIONS'));
      expect(plugin, contains('setPackageMuted'));
      expect(plugin, contains('setTargetLanguage'));

      final service = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/'
        'NotificationTranslateService.kt',
      ).readAsStringSync();
      expect(service, contains('VISIBILITY_SECRET'));
      expect(service, contains('FLAG_FOREGROUND_SERVICE'));
      expect(service, contains('FLAG_NO_CLEAR'));
      expect(service, contains('CATEGORY_CALL'));
      expect(service, contains('EXTRA_MESSAGES'));
      expect(service, contains('override fun onNotificationRemoved'));
      expect(service, contains('setContentIntent'));
      expect(service, contains('PREF_MUTED_PACKAGES'));
    });
  });
}
