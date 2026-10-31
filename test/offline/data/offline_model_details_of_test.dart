import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';

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

  test('the web translator imports picked files by their contents', () {
    final translator = createWebBergamotTranslator(
      catalog: catalog,
      channel: _NoWorker(),
      httpClient: client,
      isAvailable: true,
    );
    final details = offlineModelDetailsOf(translator);
    expect(details, isA<WebBergamotModelDetails>());
    expect(details, isA<OfflineModelContentsImport>());
    expect(details!.downloadSize('de'), translator.downloadSize('de'));
    expect((details as WebBergamotModelDetails).manualFiles('de'), isNotEmpty);
    // A browser has no paths.
    expect(details.importFiles(['/x']), throwsUnsupportedError);
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
}
