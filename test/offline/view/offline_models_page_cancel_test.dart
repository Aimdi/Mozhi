import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  late CancellableTranslatorStub stub;

  setUp(() => stub = CancellableTranslatorStub());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      OfflineModelsPage(translator: stub.translator, store: MemoryStore()),
    );
    await tester.pumpAndSettle();
  }

  final cancel = find.byKey(const Key('offline_cancel_download'));

  group('OfflineModelsPage Cancel', () {
    testWidgets('stops a download quietly', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(find.text('Downloading…'), findsOneWidget);
      expect(cancel, findsOneWidget);

      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(stub.cancelled, ['fr']);
      expect(find.byType(SnackBar), findsNothing);
      expect(cancel, findsNothing);
      expect(find.byTooltip('Download French'), findsOneWidget);
      expect(find.text('2 languages downloaded'), findsOneWidget);
    });

    testWidgets('a failed download still says why', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      stub.finishDownload(
        'fr',
        error: const ModelDownloadException('en-fr', 'SocketException'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('French'), findsWidgets);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
