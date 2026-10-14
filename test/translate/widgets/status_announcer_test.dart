import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

Widget _app(
  String? message, {
  required bool supportsAnnounce,
  bool announceInitial = false,
  TextDirection? textDirection,
  Object? announcementId,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(supportsAnnounce: supportsAnnounce),
      child: Scaffold(
        body: StatusAnnouncer(
          message: message,
          announceInitial: announceInitial,
          textDirection: textDirection,
          announcementId: announcementId,
          child: const Text('content'),
        ),
      ),
    ),
  ),
);

void main() {
  group('StatusAnnouncer', () {
    testWidgets('announces each new message once', (tester) async {
      await tester.pumpWidget(_app(null, supportsAnnounce: true));
      await tester.pumpWidget(_app('Ready', supportsAnnounce: true));
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Ready', textDirection: TextDirection.ltr),
      ]);
      // Rebuilding with the same message says nothing.
      await tester.pumpWidget(_app('Ready', supportsAnnounce: true));
      expect(tester.takeAnnouncements(), isEmpty);
      // Null resets, so the same message is announced again afterwards.
      await tester.pumpWidget(_app(null, supportsAnnounce: true));
      await tester.pumpWidget(
        _app('مرحبا', supportsAnnounce: true, textDirection: TextDirection.rtl),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('مرحبا', textDirection: TextDirection.rtl),
      ]);
    });

    testWidgets('a new announcement id repeats the same message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app('Ready', supportsAnnounce: true, announcementId: 1),
      );
      await tester.pumpWidget(
        _app('Ready', supportsAnnounce: true, announcementId: 2),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Ready'),
      ]);
      await tester.pumpWidget(
        _app('Ready', supportsAnnounce: true, announcementId: 2),
      );
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('stays silent on the first build unless asked', (tester) async {
      await tester.pumpWidget(_app('Done', supportsAnnounce: true));
      expect(tester.takeAnnouncements(), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _app('Done', supportsAnnounce: true, announceInitial: true),
      );
      expect(tester.takeAnnouncements(), [isAccessibilityAnnouncement('Done')]);
    });

    testWidgets('lays its child out as if it were not there', (tester) async {
      for (final message in [null, 'Ready']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatusAnnouncer(message: message, child: const Text('x')),
                ],
              ),
            ),
          ),
        );
        expect(tester.getSize(find.text('x')).width, 800);
      }
    });

    testWidgets('falls back to a live region without announce support', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(null, supportsAnnounce: false));
      expect(
        find.byKey(const Key('status_announcer_live_region')),
        findsNothing,
      );
      await tester.pumpWidget(_app('Ready', supportsAnnounce: false));
      expect(tester.takeAnnouncements(), isEmpty);
      expect(
        tester.getSemantics(
          find.byKey(const Key('status_announcer_live_region')),
        ),
        isSemantics(isLiveRegion: true, label: 'Ready'),
      );
      expect(find.text('content'), findsOneWidget);
      await tester.pumpWidget(_app(null, supportsAnnounce: false));
      expect(
        find.byKey(const Key('status_announcer_live_region')),
        findsNothing,
      );
      handle.dispose();
    });
  });
}
