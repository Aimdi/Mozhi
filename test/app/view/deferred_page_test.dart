import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/deferred_page.dart';
import 'package:mozhi/l10n/l10n.dart';

void main() {
  group('DeferredLibrary', () {
    test('loads once', () async {
      var calls = 0;
      final library = DeferredLibrary(() async => calls++);

      expect(library.isLoaded, isFalse);
      await Future.wait([library.load(), library.load()]);
      await library.load();

      expect(calls, 1);
      expect(library.isLoaded, isTrue);
    });

    test('can be retried after a failed load', () async {
      var calls = 0;
      final library = DeferredLibrary(() async {
        if (calls++ == 0) throw StateError('offline');
      });

      await expectLater(library.load(), throwsStateError);
      expect(library.isLoaded, isFalse);

      await library.load();
      expect(calls, 2);
      expect(library.isLoaded, isTrue);
    });
  });

  group('DeferredPage', () {
    late List<Completer<void>> loads;
    late DeferredLibrary library;

    setUp(() {
      loads = [];
      library = DeferredLibrary(() {
        final load = Completer<void>();
        loads.add(load);
        return load.future;
      });
    });

    Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DeferredPage(
          library: library,
          builder: (context) => const Text('loaded page'),
        ),
      ),
    );

    testWidgets('shows a loading screen until the library is loaded', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Loading…'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('loaded page'), findsNothing);

      loads.single.complete();
      await tester.pump();

      expect(find.text('loaded page'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('builds right away once loaded', (tester) async {
      unawaited(library.load());
      loads.single.complete();
      await tester.runAsync(library.load);

      await pumpPage(tester);

      expect(find.text('loaded page'), findsOneWidget);
      expect(loads, hasLength(1));
    });

    testWidgets('offers a retry when the download fails', (tester) async {
      await pumpPage(tester);

      loads.single.completeError(StateError('offline'));
      await tester.pump();

      expect(
        find.text(
          "This screen couldn't be loaded. Check your connection and try "
          'again.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(loads, hasLength(2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      loads.last.complete();
      await tester.pump();

      expect(find.text('loaded page'), findsOneWidget);
    });

    testWidgets('ignores a load that finishes after it is gone', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.pumpWidget(const SizedBox.shrink());

      loads.single.completeError(StateError('offline'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores a successful load after it is gone', (tester) async {
      await pumpPage(tester);
      await tester.pumpWidget(const SizedBox.shrink());

      loads.single.complete();
      await tester.pump();

      expect(library.isLoaded, isTrue);
    });
  });
}
