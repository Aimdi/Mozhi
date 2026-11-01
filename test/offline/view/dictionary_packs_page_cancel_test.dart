import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../../helpers/helpers.dart';

class _MockPacks extends Mock implements DictionaryPacks;

void main() {
  late Uint8List spanish;
  late DictionaryPackInfo es;
  late _MockPacks packs;
  late Completer<void> download;
  late List<String> cancelled;

  setUp(() {
    spanish = spanishPack();
    es = packInfo('es', spanish);
    packs = _MockPacks();
    download = Completer<void>()..complete();
    cancelled = [];
    when(() => packs.changes).thenAnswer((_) => const Stream.empty());
    when(() => packs.catalog).thenReturn(DictionaryPackCatalog([es]));
    when(() => packs.isSupported).thenReturn(true);
    when(() => packs.installing).thenReturn(const {});
    when(packs.installed).thenAnswer((_) async => const []);
    when(
      () => packs.install(
        es,
        wifiOnly: any(named: 'wifiOnly'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) {
      final onProgress =
          invocation.namedArguments[#onProgress] as void Function(double)?;
      onProgress?.call(0.4);
      // Made in the test's zone, where the cubit awaits it.
      download = Completer<void>();
      return download.future;
    });
    when(() => packs.cancelInstall(any())).thenAnswer((invocation) async {
      cancelled.add(invocation.positionalArguments.first as String);
      if (!download.isCompleted) {
        download.completeError(const OfflineDownloadCancelledException('es'));
      }
    });
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      DictionaryPacksPage(packs: packs, store: MemoryStore()),
    );
    await tester.pumpAndSettle();
  }

  final cancel = find.byKey(const Key('offline_cancel_download'));

  group('DictionaryPacksPage Cancel', () {
    testWidgets('stops a download quietly', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download Spanish'));
      await tester.pump();
      expect(find.text('Downloading… 40%'), findsOneWidget);
      expect(cancel, findsOneWidget);
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
      expect(
        find.bySemanticsLabel('Cancel downloading Spanish'),
        findsOneWidget,
      );

      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(cancelled, ['es']);
      expect(find.byType(SnackBar), findsNothing);
      expect(cancel, findsNothing);
      expect(find.byTooltip('Download Spanish'), findsOneWidget);
      semantics.dispose();
    });
  });
}
