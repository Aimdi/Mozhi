import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/platform/text_recognition_io.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';

import '../helpers.dart';

class _MockTextRecognitionData extends Mock
    implements TextRecognitionService, TextRecognitionLanguageData;

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;
  late _MockTextRecognitionData ocr;

  setUp(() {
    history = createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit();
    ocr = _MockTextRecognitionData();
    when(ocr.installedOcrLanguages)
        .thenAnswer((_) async => {'deu': 1500000, 'eng': 4100000});
    when(() => ocr.deleteOcrLanguage(any())).thenAnswer((_) async {});
  });

  test('deletes every text recognition language, then the folder', () async {
    var folderDeleted = false;
    await LocalDataEraser(
      history: history,
      settings: settings,
      textRecognition: ocr,
      deleteTextRecognitionFiles: () async {
        verify(() => ocr.deleteOcrLanguage('deu')).called(1);
        verify(() => ocr.deleteOcrLanguage('eng')).called(1);
        folderDeleted = true;
      },
    ).erase();
    expect(folderDeleted, isTrue);
  });

  test('still deletes the folder and the rest when a language fails', () async {
    when(() => ocr.deleteOcrLanguage(any())).thenThrow(StateError('busy'));
    var folderDeleted = false;
    await expectLater(
      LocalDataEraser(
        history: history,
        settings: settings,
        textRecognition: ocr,
        deleteTextRecognitionFiles: () async => folderDeleted = true,
      ).erase(),
      throwsStateError,
    );
    expect(folderDeleted, isTrue);
    verify(() => settings.update(any())).called(1);
  });

  group('deleteTextRecognitionFiles', () {
    late Directory support;

    setUp(() => support = Directory.systemTemp.createTempSync('ocr_data'));
    tearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    test('removes the tesseract folder with everything in it', () async {
      final data = File(
        '${support.path}/$textRecognitionFolder/tessdata/deu.traineddata.part',
      )..createSync(recursive: true);
      final other = File('${support.path}/bergamot/keep')
        ..createSync(recursive: true);
      await deleteTextRecognitionFiles(supportDirectory: () async => support);
      expect(data.existsSync(), isFalse);
      expect(
        Directory('${support.path}/$textRecognitionFolder').existsSync(),
        isFalse,
      );
      expect(other.existsSync(), isTrue);
    });

    test('does nothing when there is no folder', () async {
      await deleteTextRecognitionFiles(supportDirectory: () async => support);
      expect(support.existsSync(), isTrue);
    });
  });
}
