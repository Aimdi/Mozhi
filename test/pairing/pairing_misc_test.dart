import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/view/pairing_environment_of.dart';
import 'package:mozhi/pairing/widgets/pairing_labels.dart';
import 'package:mozhi/pairing/widgets/pairing_widgets.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/helpers.dart';
import 'helpers/bergamot_fixture.dart';

class _MockEngine extends Mock implements WhisperEngine;

void main() {
  test('exceptions name themselves without the other phone text', () {
    const exceptions = <PairingException>[
      PairingClosedException(),
      PairingTimeoutException(),
      PairingAuthenticationException(),
      PairingProtocolException('bad'),
      PairingAddressException(),
      PairingCancelledException(),
      PairingDeclinedException(),
      PairingExpiredException(),
      PairingExpiredException(tooManyAttempts: true),
      PairingUnreachableException(),
    ];
    expect(
      [for (final e in exceptions) '$e'],
      [
        'PairingClosedException(Connection closed)',
        'PairingTimeoutException(Timed out)',
        'PairingAuthenticationException(Authentication failed)',
        'PairingProtocolException(bad)',
        'PairingAddressException(Not a private address)',
        'PairingCancelledException(Cancelled)',
        'PairingDeclinedException(Declined)',
        'PairingExpiredException(Code expired)',
        'PairingExpiredException(Too many attempts)',
        'PairingUnreachableException(Unreachable)',
      ],
    );
  });

  test('failures are explained', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final messages = {
      for (final failure in PairingFailure.values)
        pairingFailureMessage(l10n, failure),
    };
    expect(messages, hasLength(PairingFailure.values.length));
    expect(
      PairingFailure.of(
        const FileSystemException('full', 'x', OSError('No space', 28)),
      ),
      PairingFailure.noSpace,
    );
    expect(PairingFailure.of(StateError('x')), PairingFailure.unknown);
    expect(
      PairingFailure.of(const PairingClosedException(), connecting: true),
      PairingFailure.refused,
    );
  });

  test('items have titles and icons', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    PairingItem item(PairingItemKind kind, String key) =>
        PairingItem(kind: kind, key: key, files: const []);
    expect(
      pairingItemTitle(l10n, item(PairingItemKind.ocr, 'deu'), language: 'de'),
      'Text recognition: German',
    );
    expect(
      pairingItemTitle(l10n, item(PairingItemKind.dictionary, 'zz')),
      'Dictionary: zz',
    );
    for (final kind in PairingItemKind.values) {
      expect(pairingItemIcon(kind), isA<IconData>());
    }
    expect(
      pairingOutcomeText(l10n, PairingItemOutcome.installed, isData: true),
      'Restored',
    );
  });

  testWidgets('a number of another length is shown as it is', (tester) async {
    await tester.pumpApp(const PairingNumber(sas: '12', title: 'Check'));
    expect(find.text('12'), findsOneWidget);
  });

  group('PairingEnvironment', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('mozhi_env_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('listens only on private addresses by default', () async {
      final environment = PairingEnvironment(
        library: PairingLibrary(),
        temporaryDirectory: () async => temp,
      );
      await environment.keepScreenOn(enabled: true);
      await expectLater(
        environment.listen(InternetAddress.loopbackIPv4, Duration.zero),
        throwsA(isA<PairingAddressException>()),
      );
      expect(environment.codeValidity, const Duration(minutes: 5));
    });

    test('a transfer folder starts without leftovers', () async {
      final environment = PairingEnvironment(
        library: PairingLibrary(),
        temporaryDirectory: () async => temp,
      );
      File('${temp.path}/pairing/1/old.bin').createSync(recursive: true);
      final folder = await environment.workDirectory();
      expect(folder.parent.path, '${temp.path}/pairing');
      expect(Directory('${temp.path}/pairing').existsSync(), isFalse);
      // Nothing to delete is fine too.
      await PairingEnvironment.deleteFiles(() async => temp);
      // Without a cache folder (no platform) nothing happens.
      await deletePairingFiles();
    });

    testWidgets('the app environment takes what the widget tree has', (
      tester,
    ) async {
      final catalog = TinyCatalog()..add('de', 'en', 'v1');
      final engine = _MockEngine();
      when(engine.dispose).thenAnswer((_) async {});
      final speech = OfflineSpeech(
        whisper: WhisperSpeech(
          catalog: WhisperModelCatalog(
            models: [
              WhisperCatalogModel(
                id: 'tiny',
                name: 'ggml-tiny.bin',
                url: Uri.parse('https://models.example/ggml-tiny.bin'),
                size: 1,
                sha1: 'a' * 40,
              ),
            ],
          ),
          root: temp,
          httpClient: MockClient((_) async => http.Response('', 404)),
          engine: engine,
          isAvailable: false,
        ),
        store: MemoryStore(),
      );
      addTearDown(speech.dispose);
      final registry = BackupRegistry(appVersion: () async => '1');
      late PairingEnvironment environment;
      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<OfflineTranslator>.value(
              value: catalog.translator(temp),
            ),
            RepositoryProvider<OfflineSpeech>.value(value: speech),
            RepositoryProvider<DictionaryPacks>.value(
              value: DictionaryPacks(
                catalog: DictionaryPackCatalog(const []),
                storage: MemoryDictionaryPackStorage(),
                httpClient: MockClient((_) async => http.Response('', 404)),
              ),
            ),
            RepositoryProvider<BackupRegistry>.value(value: registry),
          ],
          child: Builder(
            builder: (context) {
              environment = pairingEnvironmentOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(environment.library.backup, same(registry));
      expect(
        environment.library.packs.keys,
        containsAll([
          PairingItemKind.translation,
          PairingItemKind.speech,
          PairingItemKind.dictionary,
        ]),
      );
    });
  });
}
