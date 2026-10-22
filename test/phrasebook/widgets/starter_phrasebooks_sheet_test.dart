import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/starter_phrasebooks_sheet.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';

import '../pump.dart';
import '../starter_fixtures.dart';

void main() {
  final bytes = starterPackBytes(starterPackJson());
  final info = starterInfo(bytes);

  Future<void> open(WidgetTester tester, StarterPhrasebooks packs) async {
    await tester.pumpPhrasebook(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showStarterPhrasebooks(context, packs),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('downloads, then deletes a phrasebook', (tester) async {
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    await open(tester, packs);
    expect(find.text('Starter phrasebooks'), findsOneWidget);
    expect(find.text('Portuguese'), findsOneWidget);
    expect(find.textContaining('3 phrases ·'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_download_pt')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Downloaded'), findsOneWidget);
    expect(await packs.installed(), hasLength(1));
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_delete_pt')),
    );
    await tester.pumpAndSettle();
    expect(await packs.installed(), isEmpty);
    expect(
      find.byKey(const ValueKey('phrasebook_starter_download_pt')),
      findsOneWidget,
    );
  });

  testWidgets('shows the progress of a download', (tester) async {
    final release = http.StreamedResponse(
      Stream<List<int>>.fromIterable([bytes.sublist(0, 10)])
          .asyncExpand((chunk) async* {
            yield chunk;
            await Future<void>.delayed(const Duration(seconds: 1));
            yield bytes.sublist(10);
          }),
      200,
    );
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient.streaming((request, body) async => release),
    );
    await open(tester, packs);
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_download_pt')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Downloading…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('Downloaded'), findsOneWidget);
  });

  testWidgets('says why a download failed', (tester) async {
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await open(tester, packs);
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_download_pt')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Couldn't download it. Check your connection and the model source.",
      ),
      findsOneWidget,
    );
    final checksum = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient((_) async => http.Response('x', 200)),
    );
    await open(tester, checksum);
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_download_pt')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text("The download didn't match its checksum and was discarded."),
      findsOneWidget,
    );
  });

  testWidgets('offers updates', (tester) async {
    final store = MemoryStore();
    await installStarterPack(
      store,
      starterPackBytes(starterPackJson(revision: 1)),
    );
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: store,
      httpClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    await open(tester, packs);
    await tester.tap(
      find.byKey(const ValueKey('phrasebook_starter_update_pt')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('phrasebook_starter_update_pt')),
      findsNothing,
    );
  });

  testWidgets('credits Wikivoyage and its licence', (tester) async {
    final opened = <Uri>[];
    LinkLauncher.launcher = (uri) async {
      opened.add(uri);
      return true;
    };
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
        store: MemoryStore(),
      ),
    );
    expect(find.byKey(const Key('phrasebook_starter_empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('phrasebook_starter_source')));
    await tester.tap(find.byKey(const Key('phrasebook_starter_license')));
    expect(opened, [wikivoyageUrl, ccBySa4Url]);
  });
}
