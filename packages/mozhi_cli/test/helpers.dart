import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/command_runner.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/config/config_store.dart';
import 'package:mozhi_cli/src/console.dart';
import 'package:translation_repository/translation_repository.dart';

class MockLogger extends Mock implements Logger;

class MockProgress extends Mock implements Progress;

class MockConsole extends Mock implements Console;

class MockRepository extends Mock implements TranslationRepository;

const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'mozhi.aryak.me',
  mozhiEngine: 'google',
);

const deeplEngine = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  subtitle: 'mozhi.aryak.me',
  mozhiEngine: 'deepl',
);

const ollamaProvider = AiProviderConfig(
  id: 'local',
  name: 'Local',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'gemma3',
);

const claudeProvider = AiProviderConfig(
  id: 'claude',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
  apiKey: 'sk-stored',
);

const english = Language(code: 'en', name: 'English');
const french = Language(code: 'fr', name: 'French');
const german = Language(code: 'de', name: 'German');

/// Everything a command test needs: mocks, a temporary config file and a
/// runner wired to them.
class Harness {
  new() {
    directory = Directory.systemTemp.createTempSync('mozhi_cli_test_');
    configPath = '${directory.path}/mozhi/config.json';
    logger = MockLogger();
    console = MockConsole();
    repository = MockRepository();
    progress = MockProgress();
    chmods = [];

    when(() => logger.level).thenAnswer((_) => level);
    when(() => logger.level = any()).thenAnswer((invocation) {
      level = invocation.positionalArguments.first as Level;
    });
    void record(List<String> sink, Invocation invocation) {
      final message = invocation.positionalArguments.first as String?;
      final style = invocation.namedArguments[#style] as LogStyle?;
      sink.add(style == null ? '$message' : '${style(message)}');
    }

    when(
      () => logger.info(any(), style: any(named: 'style')),
    ).thenAnswer((i) => record(out, i));
    when(
      () => logger.success(any(), style: any(named: 'style')),
    ).thenAnswer((i) => record(out, i));
    when(
      () => logger.detail(any(), style: any(named: 'style')),
    ).thenAnswer((i) => record(details, i));
    when(
      () => logger.err(any(), style: any(named: 'style')),
    ).thenAnswer((i) => record(err, i));
    when(
      () => logger.warn(
        any(),
        tag: any(named: 'tag'),
        style: any(named: 'style'),
      ),
    ).thenAnswer((i) => warnings.add(i.positionalArguments.first as String));
    when(() => logger.write(any())).thenAnswer(
      (i) => written.write(i.positionalArguments.first as String?),
    );
    when(() => logger.progress(any())).thenReturn(progress);
    when(() => console.environment).thenReturn(environment);
    when(() => console.isWindows).thenReturn(false);
    when(() => console.stdinHasTerminal).thenReturn(true);
    when(() => console.stdoutHasTerminal).thenReturn(false);
    when(() => console.supportsAnsiEscapes).thenReturn(false);
    when(() => console.terminalColumns).thenReturn(80);
    when(() => console.terminalLines).thenReturn(24);
    when(() => repository.activeInstance).thenReturn(
      MozhiInstance.publicInstances.first,
    );

    runner = MozhiCliCommandRunner(
      logger: logger,
      console: console,
      repositoryFactory: () {
        repositoriesCreated++;
        return repository;
      },
      configStoreFactory: (path) => ConfigStore(
        path: path,
        chmod: (path, mode) {
          chmods.add((path, mode));
          Process.runSync('chmod', [mode, path]);
        },
      ),
    );
  }

  late final Directory directory;
  late final String configPath;
  late final MockLogger logger;
  late final MockConsole console;
  late final MockRepository repository;
  late final MockProgress progress;
  late final List<(String, String)> chmods;
  late final MozhiCliCommandRunner runner;
  final Map<String, String> environment = {};
  int repositoriesCreated = 0;

  /// Runs `mozhi --config <tmp> ...args`.
  Future<int> run(List<String> args) =>
      runner.run(['--config', configPath, ...args]);

  ConfigStore get store => ConfigStore(path: configPath);

  void writeConfig(CliConfig config) => store.save(config);

  CliConfig readConfig() => store.load();

  /// Pipes [text] into standard input.
  void pipe(String text) {
    when(() => console.stdinHasTerminal).thenReturn(false);
    when(() => console.readStdin()).thenAnswer((_) async => text);
  }

  /// Pretends standard output is an ANSI terminal.
  void terminal({int columns = 80, int lines = 24}) {
    when(() => console.stdoutHasTerminal).thenReturn(true);
    when(() => console.supportsAnsiEscapes).thenReturn(true);
    when(() => console.terminalColumns).thenReturn(columns);
    when(() => console.terminalLines).thenReturn(lines);
  }

  /// Standard output lines (`info` and `success`), styles applied.
  final List<String> out = [];

  /// Standard error lines (`err`), styles applied.
  final List<String> err = [];
  final List<String> warnings = [];
  final List<String> details = [];

  /// Text written with `logger.write` (streaming).
  final StringBuffer written = StringBuffer();
  Level level = Level.info;

  /// Standard output as one string.
  String get stdout => out.join('\n');

  /// Standard error as one string.
  String get stderr => err.join('\n');

  /// The JSON printed on standard output.
  Object? json() => jsonDecode(out.single);

  void dispose() => directory.deleteSync(recursive: true);
}

void registerFallbacks() {
  registerFallbackValue(googleEngine);
  registerFallbackValue(const TranslationRequest(text: '', source: english, target: french));
  registerFallbackValue(const MozhiInstance(url: 'https://example.com'));
  registerFallbackValue(ollamaProvider);
  registerFallbackValue(<MozhiInstance>[]);
  registerFallbackValue(<AiProviderConfig>[]);
}
