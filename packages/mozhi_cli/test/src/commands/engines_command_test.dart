import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('engines', () {
    late Harness h;

    const local = TranslationEngine(
      id: 'ai:local',
      kind: EngineKind.ai,
      name: 'Local',
      subtitle: 'gemma3',
      providerId: 'local',
      isLocal: true,
    );
    const cloud = TranslationEngine(
      id: 'ai:claude',
      kind: EngineKind.ai,
      name: 'Claude',
      subtitle: 'claude-opus-5-5',
      providerId: 'claude',
    );

    setUp(() {
      h = Harness();
      when(
        () => h.repository.getEngines(),
      ).thenAnswer((_) async => [googleEngine, deeplEngine, local, cloud]);
    });

    tearDown(() => h.dispose());

    test('prints a table and marks the default engine', () async {
      when(() => h.console.stdoutHasTerminal).thenReturn(true);
      expect(await h.run(['engines']), ExitCode.success.code);
      final table = h.stdout;
      expect(table, contains('ID'));
      expect(table, contains('mozhi:google *'));
      expect(table, contains('via mozhi.aryak.me'));
      expect(table, contains('gemma3 · local'));
      expect(table, contains('claude-opus-5-5 · cloud'));
      expect(h.stderr, contains('default engine'));
      verify(() => h.repository.dispose()).called(1);
    });

    test('prints JSON', () async {
      expect(await h.run(['engines', '--json']), 0);
      final json = h.json()! as List<Object?>;
      expect(json.first, {
        'id': 'mozhi:google',
        'kind': 'mozhi',
        'name': 'Google',
        'subtitle': 'mozhi.aryak.me',
      });
      expect(json[2], containsPair('local', true));
    });

    test('warns when only AI engines are available', () async {
      when(
        () => h.repository.getEngines(),
      ).thenAnswer((_) async => [local]);
      expect(await h.run(['engines']), 0);
      expect(h.warnings.single, contains('No Mozhi instance'));
    });

    test('skips the default marker when the default is invalid', () async {
      h.writeConfig(const CliConfig(engine: 'ai:gone'));
      expect(await h.run(['engines']), 0);
      expect(h.stdout, isNot(contains('*')));
    });
  });
}
