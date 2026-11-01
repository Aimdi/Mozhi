import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/offline/widgets/offline_download_failure_listener.dart';

const _french = OfflineLanguage(code: 'fr', name: 'French');

void main() {
  group(OfflineDownloadFailureListener, () {
    late OfflineDownloadNotices notices;

    setUp(() => notices = OfflineDownloadNotices());
    tearDown(() => notices.close());

    void fail({OfflineModelError? error}) => notices.join('fr')
      ..leave()
      ..failedUnseen(
        OfflineModelOutcome(
          language: _french,
          operation: OfflineModelOperation.download,
          succeeded: false,
          error: error,
        ),
      );

    testWidgets('tells a download that failed after its screen closed', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              OfflineDownloadFailureListener(notices: notices, child: child!),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      fail();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('offline_download_failed_fr')), findsOne);
      expect(find.text('Couldn’t download French'), findsOne);
    });

    testWidgets('says why, through the given messenger', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(
        MaterialApp(
          scaffoldMessengerKey: messenger,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => OfflineDownloadFailureListener(
            notices: notices,
            messengerKey: messenger,
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      fail(error: const OfflineModelError(OfflineModelErrorKind.network));
      await tester.pumpAndSettle();

      final l10n = tester.element(find.byType(Scaffold)).l10n;
      expect(find.text(l10n.offlineErrorNetwork('French')), findsOne);
    });

    testWidgets('does nothing without a messenger, or once gone', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: OfflineDownloadFailureListener(
            notices: notices,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      fail();
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      fail();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('listens to the app-wide notices by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              OfflineDownloadFailureListener(child: child!),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      OfflineDownloadNotices.instance.join('de')
        ..leave()
        ..failedUnseen(
          const OfflineModelOutcome(
            language: OfflineLanguage(code: 'de', name: 'German'),
            operation: OfflineModelOperation.update,
            succeeded: false,
          ),
        )
        ..end();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('offline_download_failed_de')), findsOne);
    });
  });
}
