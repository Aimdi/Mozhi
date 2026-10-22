import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/app/view/shared_file_loader.dart';
import 'package:mozhi/app/view/shared_image_picker.dart';
import 'package:mozhi/image_translate/data/image_picker_service.dart';
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
      Future<SharedFile?> Function(String? token, {bool keep}) take,
    ) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        home: SharedFileLoader(
          token: 'abc',
          keep: true,
          take: take,
          builder: (context, file) => Text(file?.name ?? 'none'),
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

      expect(find.text('shot.png'), findsOneWidget);
      expect(token, 'abc');
      expect(kept, isTrue);
    });

    testWidgets('builds without a file when reading fails', (tester) async {
      await pump(tester, (t, {keep = false}) async => throw StateError('x'));
      await tester.pump();
      expect(find.text('none'), findsOneWidget);
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

    test('uses the platform picker by default', () {
      expect(SharedImagePicker(file).supportsCamera, isA<bool>());
    });
  });
}
