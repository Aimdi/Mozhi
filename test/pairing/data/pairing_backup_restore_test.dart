import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_packs.dart';
import '../helpers/loopback.dart';

/// A sending phone that offers one thing and sends another: the receiving
/// phone restores only what it showed (security review, Wave 4, 1).
void main() {
  late Directory temp;
  late SettingsRepository repository;
  late FakeSection history;
  late BackupRegistry registry;
  late PairingChannel senderChannel;
  late PairingChannel receiverChannel;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_restore_');
    repository = SettingsRepository(
      prefs: MemoryStore(),
      secrets: MemoryStore(),
    );
    await repository.save(
      const AppSettings(
        onboardingComplete: true,
        providers: [
          AiProviderConfig(
            id: 'p1',
            name: 'OpenAI',
            provider: LlmProvider.openAiCompatible,
            baseUrl: 'https://api.openai.com/v1',
            model: 'gpt',
            apiKey: 'sk-victim',
          ),
          AiProviderConfig(
            id: 'p2',
            name: 'Local',
            provider: LlmProvider.openAiCompatible,
            baseUrl: 'http://192.168.1.5:8080/v1',
            model: 'llama',
          ),
        ],
        instances: [MozhiInstance(url: 'https://mine.example')],
      ),
    );
    history = FakeSection('history', ['mine']);
    registry = BackupRegistry(appVersion: () async => '1')
      ..register(history)
      ..register(SettingsBackupSection(repository));
    (senderChannel, receiverChannel) = await channelPair();
  });

  tearDown(() {
    senderChannel.destroy();
    receiverChannel.destroy();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A snapshot file holding [sections] (data by id).
  List<int> snapshotBytes(Map<String, Object?> sections) => utf8.encode(
    jsonEncode({
      'format': 'mozhi-backup',
      'formatVersion': 1,
      'createdAt': '2026-10-22T00:00:00.000Z',
      'appVersion': '1',
      'sections': {
        for (final MapEntry(:key, :value) in sections.entries)
          key: {'version': 1, 'data': value},
      },
    }),
  );

  final evilSettings = {
    'settings': {
      'instances': [
        {'url': 'https://evil.example', 'label': 'Mirror'},
      ],
    },
  };

  /// Offers the data item with [sections] and [secrets] but sends
  /// [bytes]; returns what became of it on both phones.
  Future<PairingItemOutcome> transfer(
    List<int> bytes, {
    required List<String> sections,
    bool secrets = false,
    BackupRestoreMode mode = BackupRestoreMode.merge,
  }) async {
    final sender = PairingSender(senderChannel);
    final receiver = PairingReceiver(
      receiverChannel,
      PairingLibrary(backup: registry),
      workDirectory: Directory('${temp.path}/work'),
    );
    final requested = sender.offer([
      PairingOutgoingItem(
        PairingItem(
          kind: PairingItemKind.data,
          key: PairingBackupItem.key,
          files: [
            PairingFile(name: PairingBackupItem.fileName, size: bytes.length),
          ],
          sections: sections,
          secrets: secrets,
        ),
        {PairingBackupItem.fileName: () => Stream.value(bytes)},
      ),
    ]);
    final offered = await receiver.offer();
    // What the receiving phone shows is what the offer says.
    expect(offered.single.item.sections, sections);
    expect(offered.single.item.secrets, secrets);
    final received = receiver.accept({PairingBackupItem.id}, mode: mode);
    final sent = await sender.send(await requested);
    expect(await received, sent);
    return sent.single.outcome;
  }

  test('a backup holding sections the offer left out is refused', () async {
    final outcome = await transfer(
      snapshotBytes({
        'history': {
          'value': ['theirs'],
        },
        'settings': evilSettings,
      }),
      sections: const ['history'],
    );
    expect(outcome, PairingItemOutcome.damaged);
    final after = await repository.load();
    expect(after.instances.map((i) => i.url), ['https://mine.example']);
    // Nothing of it is restored, not even what was announced.
    expect(history.restores, isEmpty);
  });

  test('a Replace cannot sneak in unannounced settings either', () async {
    final outcome = await transfer(
      snapshotBytes({'settings': evilSettings}),
      sections: const ['history'],
      mode: BackupRestoreMode.replace,
    );
    expect(outcome, PairingItemOutcome.damaged);
    final after = await repository.load();
    expect(after.instances.map((i) => i.url), ['https://mine.example']);
    expect(after.providers.map((p) => p.id), ['p1', 'p2']);
  });

  test(
    'a backup holding secrets the offer did not announce is refused',
    () async {
      final outcome = await transfer(
        snapshotBytes({
          'settings': {
            ...evilSettings,
            'secrets': {
              'apiKeys': {'p2': 'sk-attacker'},
            },
          },
        }),
        sections: const ['settings'],
      );
      expect(outcome, PairingItemOutcome.damaged);
      final after = await repository.load();
      expect(after.providers.last.apiKey, isNull);
      expect(after.instances.map((i) => i.url), ['https://mine.example']);
    },
  );

  test('what the offer announced is restored', () async {
    final outcome = await transfer(
      snapshotBytes({
        'history': {
          'value': ['theirs'],
        },
        'settings': {
          ...evilSettings,
          'secrets': {
            'apiKeys': {'p2': 'sk-mine-too'},
          },
        },
      }),
      sections: const ['history', 'settings'],
      secrets: true,
    );
    expect(outcome, PairingItemOutcome.installed);
    expect(history.restores.single.$1, {
      'value': ['theirs'],
    });
  });

  test('the backup is never written to storage', () async {
    final seen = <String>[];
    registry = BackupRegistry(appVersion: () async => '1')
      ..register(
        _SpySection('history', () {
          seen.addAll([
            for (final entity in temp.listSync(recursive: true))
              if (entity is File) entity.path,
          ]);
        }),
      );
    final outcome = await transfer(
      snapshotBytes({
        'history': {
          'value': ['theirs'],
        },
      }),
      sections: const ['history'],
    );
    expect(outcome, PairingItemOutcome.installed);
    expect(seen, isEmpty);
    expect(Directory('${temp.path}/work').existsSync(), isFalse);
  });
}

/// A backup section that calls [onRestore] when it is restored.
class _SpySection implements BackupSection {
  new(this.id, this.onRestore);

  @override
  final String id;

  final void Function() onRestore;

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async => null;

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async => onRestore();
}
