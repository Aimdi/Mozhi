import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';
import '../../image_translate/helpers/fake_ocr.dart';
import '../helpers.dart';

void main() {
  late CancellableOcrData data;

  setUp(() => data = CancellableOcrData());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      OcrLanguagesPage(
        data: data,
        store: MemoryStore(),
        picker: stubOfflineModelFilePicker(paths: const []),
      ),
    );
    await tester.pumpAndSettle();
  }

  final cancel = find.byKey(const Key('offline_cancel_download'));

  group('OcrLanguagesPage Cancel', () {
    testWidgets('stops a download quietly', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(cancel, findsOneWidget);
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(cancel).width, greaterThanOrEqualTo(48));
      expect(
        find.bySemanticsLabel('Cancel downloading French'),
        findsOneWidget,
      );

      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(data.cancelled, ['fra']);
      expect(find.byType(SnackBar), findsNothing);
      expect(cancel, findsNothing);
      expect(find.byTooltip('Download French'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a download that cannot be cancelled has no Cancel', (
      tester,
    ) async {
      // A plain recognizer: its downloads finish on their own.
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final plain = FakeOcrData()..downloadGate = Completer<void>();
      await tester.pumpApp(
        OcrLanguagesPage(
          data: plain,
          store: MemoryStore(),
          picker: stubOfflineModelFilePicker(paths: const []),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(cancel, findsNothing);
      plain.downloadGate!.complete();
      await tester.pumpAndSettle();
    });
  });
}
