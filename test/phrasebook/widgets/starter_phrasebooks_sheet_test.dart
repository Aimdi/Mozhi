import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/starter_phrasebooks_sheet.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';

import '../pump.dart';
import '../starter_fixtures.dart';

/// Taps [finder] and lets the download it starts run for real: downloads
/// time out per chunk (`Stream.timeout`), which never finishes on a
/// widget test's fake clock.
Future<void> _tapAndDownload(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

Finder _button(String action) =>
    find.byKey(ValueKey('phrasebook_starter_${action}_pt'));

void main() {
  final bytes = starterPackBytes(starterPackJson());
  final info = starterInfo(bytes);

  Future<void> open(WidgetTester tester, StarterPhrasebooks packs) async {
    // A new tree: no sheet of an earlier call is left open.
    await tester.pumpWidget(const SizedBox.shrink());
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
    expect(find.text('English ↔ Portuguese'), findsOneWidget);
    expect(find.textContaining('3 phrases ·'), findsOneWidget);
    await _tapAndDownload(tester, _button('download'));
    expect(find.textContaining('Downloaded'), findsOneWidget);
    expect(await packs.installed(), hasLength(1));
    await tester.tap(_button('delete'));
    await tester.pumpAndSettle();
    expect(await packs.installed(), isEmpty);
    expect(_button('download'), findsOneWidget);
  });

  testWidgets('shows the progress of a download', (tester) async {
    final chunks = StreamController<List<int>>();
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient.streaming(
        (request, body) async => http.StreamedResponse(chunks.stream, 200),
      ),
    );
    await open(tester, packs);
    await tester.runAsync(() async {
      await tester.tap(_button('download'));
      chunks.add(bytes.sublist(0, 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining('Downloading…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.runAsync(() async {
      chunks.add(bytes.sublist(10));
      await chunks.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Downloaded'), findsOneWidget);
  });

  testWidgets('says why a download failed', (tester) async {
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: MemoryStore(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      ),
    );
    await _tapAndDownload(tester, _button('download'));
    expect(
      find.text(
        "Couldn't download it. Check your connection and the model source.",
      ),
      findsOneWidget,
    );
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: MemoryStore(),
        httpClient: MockClient((_) async => http.Response('x', 200)),
      ),
    );
    await _tapAndDownload(tester, _button('download'));
    expect(
      find.text("The download didn't match its checksum and was discarded."),
      findsOneWidget,
    );
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: _FullStore(),
        httpClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
      ),
    );
    await _tapAndDownload(tester, _button('download'));
    expect(find.text("Couldn't save it on this device."), findsOneWidget);
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: MemoryStore(),
        httpClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
        freeSpace: FreeSpace(isWeb: true, browser: () async => 0),
      ),
    );
    await _tapAndDownload(tester, _button('download'));
    expect(find.textContaining('Not enough free space: needs'), findsOneWidget);
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
    await _tapAndDownload(tester, _button('update'));
    expect(_button('update'), findsNothing);
    expect(_button('delete'), findsOneWidget);
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

  testWidgets("in German: names packs in German, without German's", (
    tester,
  ) async {
    final german = starterPackBytes(
      starterPackJson(id: 'de', language: 'de', name: 'German'),
    );
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([
        starterInfo(german, id: 'de', language: 'de', name: 'German'),
        info,
      ]),
      store: MemoryStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStarterPhrasebooks(context, packs),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Englisch ↔ Portugiesisch'), findsOneWidget);
    expect(find.byKey(const ValueKey('phrasebook_starter_de')), findsNothing);
    expect(find.byKey(const ValueKey('phrasebook_starter_pt')), findsOneWidget);
  });

  testWidgets('a language the app does not know keeps its name', (
    tester,
  ) async {
    final klingon = starterPackBytes(
      starterPackJson(id: 'zz', language: 'zz', name: 'Zedish'),
    );
    await open(
      tester,
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([
          starterInfo(klingon, id: 'zz', language: 'zz', name: 'Zedish'),
        ]),
        store: MemoryStore(),
      ),
    );
    expect(find.text('English ↔ Zedish'), findsOneWidget);
  });
}

/// A store that is full.
class _FullStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('QuotaExceededError');
}
