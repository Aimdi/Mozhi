import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/app/view/shared_file_loader.dart';
import 'package:mozhi/app/view/shared_image_picker.dart';
import 'package:mozhi/image_translate/data/image_picker_service.dart';
import 'package:mozhi/image_translate/models/image_translate_exception.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/l10n/l10n.dart';

class _MockPicker extends Mock implements ImagePickerService;

void main() {
  final file = SharedFile(
    name: 'shot.png',
    bytes: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0, 0]),
    path: '/cache/shared_files/x/shot.png',
  );

  group('SharedFileLoader', () {
    Future<void> pump(
      WidgetTester tester,
      Future<SharedFile?> Function(String? token, {bool keep}) take, {
      String? token = 'abc',
    }) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        // Not `home`: its route would keep the first loader.
        builder: (context, _) => SharedFileLoader(
          token: token,
          keep: true,
          take: take,
          builder: (context, file, token) =>
              Text('${file?.name ?? 'none'} $token'),
        ),
      ),
    );

    testWidgets('shows a loading screen, then the file', (tester) async {
      final completer = Completer<SharedFile?>();
      String? token;
      bool? kept;
      await pump(tester, (t, {keep = false}) {
        token = t;
        kept = keep;
        return completer.future;
      });

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Loading…'), findsWidgets);
      completer.complete(file);
      await tester.pump();

      expect(find.text('shot.png abc'), findsOneWidget);
      expect(token, 'abc');
      expect(kept, isTrue);
    });

    testWidgets('builds without a file when reading fails', (tester) async {
      await pump(tester, (t, {keep = false}) async => throw StateError('x'));
      await tester.pump();
      expect(find.text('none abc'), findsOneWidget);
    });

    testWidgets('builds at once without a token', (tester) async {
      var takes = 0;
      await pump(tester, (t, {keep = false}) async {
        takes++;
        return file;
      }, token: null);
      expect(find.text('none null'), findsOneWidget);
      expect(takes, 0);
    });

    testWidgets('keeps what it built while a new token is read', (
      tester,
    ) async {
      final reads = <String?, Completer<SharedFile?>>{
        'abc': Completer(),
        'def': Completer(),
      };
      Future<SharedFile?> take(String? t, {bool keep = false}) =>
          reads[t]!.future;
      await pump(tester, take);
      reads['abc']!.complete(file);
      await tester.pump();
      expect(find.text('shot.png abc'), findsOneWidget);

      await pump(tester, take, token: 'def');
      // Not the loading screen: the screen built for the first file stays.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('shot.png abc'), findsOneWidget);
      reads['def']!.complete(null);
      await tester.pump();
      await tester.pump();
      expect(find.text('none def'), findsOneWidget);
    });

    testWidgets('shows only the latest of two reads', (tester) async {
      final first = Completer<SharedFile?>();
      await pump(
        tester,
        (t, {keep = false}) => t == 'abc' ? first.future : Future.value(),
      );
      await pump(
        tester,
        (t, {keep = false}) => t == 'abc' ? first.future : Future.value(),
        token: 'def',
      );
      await tester.pump();
      expect(find.text('none def'), findsOneWidget);
      first.complete(file);
      await tester.pump();
      expect(find.text('none def'), findsOneWidget);
    });

    testWidgets('forgets a file that arrives too late', (tester) async {
      final completer = Completer<SharedFile?>();
      await pump(tester, (t, {keep = false}) => completer.future);
      await tester.pumpWidget(const SizedBox());
      completer.complete(file);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('SharedItemsNotice', () {
    Future<void> pump(WidgetTester tester, {String? id, bool several = true}) =>
        tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            home: Scaffold(
              body: SharedItemsNotice(
                id: id,
                several: several,
                child: const Text('page'),
              ),
            ),
          ),
        );

    testWidgets('says that only the first of several items opens', (
      tester,
    ) async {
      await pump(tester, id: 'a');
      await tester.pump();
      expect(find.text('page'), findsOneWidget);
      expect(find.text('Only the first item is opened.'), findsOneWidget);
    });

    testWidgets('says nothing for one item, again for a new share', (
      tester,
    ) async {
      await pump(tester, id: 'a', several: false);
      await tester.pump();
      expect(find.byKey(const Key('shared_first_item_only')), findsNothing);
      await pump(tester, id: 'a');
      await tester.pump();
      expect(find.byKey(const Key('shared_first_item_only')), findsNothing);
      await pump(tester, id: 'b');
      await tester.pump();
      expect(find.byKey(const Key('shared_first_item_only')), findsOneWidget);
    });
  });

  group('SharedImagePicker', () {
    late _MockPicker fallback;

    setUpAll(() => registerFallbackValue(ImagePickSource.gallery));

    setUp(() {
      fallback = _MockPicker();
      when(() => fallback.supportsCamera).thenReturn(true);
      when(() => fallback.pick(any())).thenAnswer((_) async => null);
      when(fallback.retrieveLost).thenAnswer((_) async => null);
    });

    test(
      'hands over the shared image once, then the platform picker',
      () async {
        final picker = SharedImagePicker(file, fallback: fallback);

        final image = await picker.retrieveLost();

        expect(image!.name, 'shot.png');
        expect(image.mimeType, 'image/png');
        expect(image.path, file.path);
        expect(image.bytes, file.bytes);
        expect(await picker.retrieveLost(), isNull);
        verify(fallback.retrieveLost).called(1);

        expect(picker.supportsCamera, isTrue);
        await picker.pick(ImagePickSource.camera);
        verify(() => fallback.pick(ImagePickSource.camera)).called(1);
      },
    );

    test('reports a shared image that could not be opened, once', () async {
      const error = ImageTranslateException(
        ImageTranslateErrorKind.fileTooLarge,
      );
      final picker = SharedImagePicker.failed(error, fallback: fallback);
      await expectLater(picker.retrieveLost(), throwsA(error));
      expect(await picker.retrieveLost(), isNull);
      verify(fallback.retrieveLost).called(1);
      expect(SharedImagePicker.failed(error).supportsCamera, isA<bool>());
    });

    test('uses the platform picker by default', () {
      expect(SharedImagePicker(file).supportsCamera, isA<bool>());
    });
  });
}
