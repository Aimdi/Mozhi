import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/clipboard_service.dart';

import '../../helpers/helpers.dart';

void main() {
  const german = OfflineLanguage(code: 'de', name: 'German');
  const english = OfflineLanguage(code: 'en', name: 'English');
  const model = OfflineModelFile(
    source: 'de',
    target: 'en',
    name: 'model.deen.intgemm.alphas.bin.gz',
    url: 'https://models.test/de-en/model.deen.intgemm.alphas.bin.gz',
    size: 25 * 1024 * 1024,
  );
  const vocab = OfflineModelFile(
    source: 'en',
    target: 'de',
    name: 'vocab.ende.spm.gz',
    url: 'https://models.test/en-de/vocab.ende.spm.gz',
    size: 400 * 1024,
  );
  const directions = [
    OfflineManualDirection(source: german, target: english, files: [model]),
    OfflineManualDirection(source: english, target: german, files: [vocab]),
  ];

  late List<String> copied;

  setUp(() {
    copied = [];
    final previous = ClipboardService.instance;
    addTearDown(() => ClipboardService.instance = previous);
    ClipboardService.instance = ClipboardService(
      isAndroid: false,
      setData: (data) async => copied.add(data.text!),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    List<OfflineManualDirection> directions = directions,
  }) async {
    await tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfflineManualFilesSheet(
              context,
              language: german,
              directions: directions,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('OfflineManualFilesSheet', () {
    testWidgets('lists the files of each direction', (tester) async {
      await open(tester);
      expect(find.text('Files for German'), findsOneWidget);
      expect(find.textContaining('without Mozhi going online'), findsOneWidget);
      expect(find.text('\u2068German\u2069 → \u2068English\u2069'), findsOne);
      expect(find.text('\u2068English\u2069 → \u2068German\u2069'), findsOne);
      expect(find.text(model.name), findsOneWidget);
      expect(find.text('25.0 MB'), findsOneWidget);
      expect(find.text(vocab.name), findsOneWidget);
    });

    testWidgets('copies one link or all of them', (tester) async {
      await open(tester);

      await tester.tap(find.byTooltip('Copy link to ${vocab.name}'));
      await tester.pump();
      expect(copied, [vocab.url]);
      expect(find.byTooltip('Copied to clipboard'), findsOneWidget);
      expect(find.byTooltip('Copy link to ${vocab.name}'), findsNothing);

      await tester.tap(find.byKey(const Key('offline_manual_copy_all')));
      await tester.pump();
      expect(copied.last, '${model.url}\n${vocab.url}');
      expect(find.text('Copied to clipboard'), findsOneWidget);
      // Only the latest copy is marked.
      expect(find.byTooltip('Copy link to ${vocab.name}'), findsOneWidget);
    });

    group('with a mirror as the model source', () {
      const mirrored = [
        OfflineManualDirection(
          source: german,
          target: english,
          files: [
            OfflineModelFile(
              source: 'de',
              target: 'en',
              name: 'model.deen.intgemm.alphas.bin.gz',
              url: 'https://models.test/de-en/model.deen.intgemm.alphas.bin.gz',
              size: 25 * 1024 * 1024,
              mirrorUrl:
                  'https://mirror.example/models/bergamot/de-en/v1/'
                  'model.deen.intgemm.alphas.bin.gz',
            ),
          ],
        ),
      ];
      final file = mirrored.single.files.single;

      testWidgets('offers the mirror first, the publisher as a fallback', (
        tester,
      ) async {
        await open(tester, directions: mirrored);
        expect(find.textContaining('mirror.example'), findsOneWidget);
        expect(
          find.text('Publisher’s link, if the mirror doesn’t have it'),
          findsOneWidget,
        );
        expect(file.preferredUrl, file.mirrorUrl);

        await tester.tap(find.byTooltip('Copy link to ${file.name}'));
        await tester.pump();
        expect(copied, [file.mirrorUrl]);

        await tester.tap(
          find.byTooltip('Copy the publisher’s link to ${file.name}'),
        );
        await tester.pump();
        expect(copied.last, file.url);
        // Only the latest copy is marked.
        expect(find.byTooltip('Copy link to ${file.name}'), findsOneWidget);

        await tester.tap(find.byKey(const Key('offline_manual_copy_all')));
        await tester.pump();
        expect(copied.last, file.mirrorUrl);
      });

      testWidgets('without one, only the publishers are listed', (
        tester,
      ) async {
        await open(tester);
        expect(find.textContaining('model source'), findsNothing);
        expect(find.textContaining('Publisher'), findsNothing);
        expect(model.preferredUrl, model.url);
      });
    });
  });
}
