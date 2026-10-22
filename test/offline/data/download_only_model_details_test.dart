import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';

class _MockDetails extends Mock implements OfflineModelDetails;

class _NoWorker implements BergamotWorkerChannel {
  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async => op == 'list' ? const <Object?>[] : null;

  @override
  void terminate() {}
}

void main() {
  final catalog = ModelCatalog.parse(
    File('packages/bergamot_translator/assets/catalog.json').readAsStringSync(),
  );
  final client = MockClient((_) async => http.Response('', 404));

  test('the web translator has details without imports', () {
    final translator = createWebBergamotTranslator(
      catalog: catalog,
      channel: _NoWorker(),
      httpClient: client,
      isAvailable: true,
    );
    final details = offlineModelDetailsOf(translator);
    expect(details, isA<DownloadOnlyModelDetails>());
    expect(details, isNot(isA<OfflineModelImport>()));
    expect(
      (details! as DownloadOnlyModelDetails).details,
      isA<BergamotModelDetails>(),
    );
    expect(details.downloadSize('de'), translator.downloadSize('de'));
  });

  test('the Android translator keeps its imports', () {
    final translator = BergamotTranslator(
      catalog: catalog,
      root: Directory.systemTemp,
      isMeteredConnection: () async => false,
      httpClient: client,
      isAvailable: false,
    );
    expect(offlineModelDetailsOf(translator), isA<OfflineModelImport>());
  });

  test('DownloadOnlyModelDetails delegates everything', () async {
    final inner = _MockDetails();
    when(() => inner.downloadSize('de')).thenReturn(42);
    when(() => inner.storage(['de']))
        .thenAnswer((_) async => const OfflineStorage(totalBytes: 7));
    when(
      () => inner.download(
        'de',
        wifiOnly: true,
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((_) async {});
    final details = DownloadOnlyModelDetails(inner);
    expect(details.downloadSize('de'), 42);
    expect((await details.storage(['de'])).totalBytes, 7);
    void progress(double _) {}
    await details.download('de', wifiOnly: true, onProgress: progress);
    verify(() => inner.download('de', wifiOnly: true, onProgress: progress))
        .called(1);
  });
}
