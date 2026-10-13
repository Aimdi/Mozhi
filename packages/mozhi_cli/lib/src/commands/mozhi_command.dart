import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/config/config_store.dart';
import 'package:mozhi_cli/src/console.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// Base class of the mozhi commands: access to the configuration, the
/// repository, input and output helpers.
abstract class MozhiCommand extends Command<int> {
  new(this.context);

  final CliContext context;

  Logger get logger => context.logger;
  Console get console => context.console;

  ArgResults get args => argResults!;

  ConfigStore? _store;
  CliConfig? _config;
  ArgResults? _cachedFor;

  /// Commands are reused when a runner runs several times: forget what was
  /// loaded for previous arguments.
  void _invalidate() {
    if (identical(_cachedFor, argResults)) return;
    _cachedFor = argResults;
    _store = null;
    _config = null;
  }

  /// The configuration store (`--config` overrides the default location).
  ConfigStore get configStore =>
      (this.._invalidate())._store ??= context.configStoreFactory(
        (globalResults?['config'] as String?) ??
            ConfigStore.defaultPath(
              console.environment,
              isWindows: console.isWindows,
            ),
      );

  /// The stored configuration (loaded once).
  CliConfig get config => (this.._invalidate())._config ??= configStore.load();

  /// Saves [config] and makes it the current configuration.
  void saveConfig(CliConfig config) {
    configStore.save(config);
    _config = config;
  }

  /// Enabled AI providers with API keys resolved from the environment.
  List<AiProviderConfig> get providers => [
    for (final entry in config.providers)
      if (entry.config.enabled) entry.resolve(console.environment),
  ];

  bool flag(String name) => args[name] as bool;

  String? option(String name) {
    final value = args[name] as String?;
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  List<String> multiOption(String name) => args[name] as List<String>;

  /// Adds the `--json` flag.
  void addJsonFlag() => argParser.addFlag(
    'json',
    negatable: false,
    help: 'Print machine-readable JSON.',
  );

  /// Adds `--instance`.
  void addInstanceOption() => argParser.addOption(
    'instance',
    abbr: 'i',
    valueHelp: 'url',
    help:
        'Mozhi instance to use instead of the configured one '
        '(e.g. https://mozhi.aryak.me).',
  );

  /// Adds `--engine`.
  void addEngineOption({String? help}) => argParser.addOption(
    'engine',
    abbr: 'e',
    valueHelp: 'engine',
    help:
        help ??
        'Translation engine: a Mozhi engine (google, deepl, yandex, '
            'reverso, libre, mymemory, duckduckgo or mozhi:<id>), or '
            'ai / ai:<provider> for a configured AI provider. '
            'Default: the configured engine, else mozhi:google.',
  );

  bool get jsonOutput => args.options.contains('json') && flag('json');

  /// Instances to use: `--instance`, else the configured instance, else
  /// the public instances (with failover).
  List<MozhiInstance> get instances {
    final override = args.options.contains('instance')
        ? option('instance')
        : null;
    final url = override ?? config.instance;
    if (url == null) return MozhiInstance.publicInstances;
    return [MozhiInstance(url: normalizeInstanceUrl(url))];
  }

  /// Normalises a user-supplied instance URL (usage error when invalid).
  static String normalizeInstanceUrl(String url) {
    try {
      return MozhiApiClient.normalizeBaseUrl(url).toString();
    } on FormatException catch (error) {
      throw CliException.usage('Invalid instance URL "$url": ${error.message}');
    }
  }

  /// A repository configured with [instances] and [providers]. Close it
  /// with `dispose` when done.
  TranslationRepository openRepository() =>
      context.repositoryFactory()
        ..updateConfiguration(instances: instances, providers: providers);

  /// Runs [body] with a fresh repository that is disposed afterwards.
  Future<T> withRepository<T>(
    Future<T> Function(TranslationRepository repository) body,
  ) async {
    final repository = openRepository();
    try {
      return await body(repository);
    } finally {
      repository.dispose();
    }
  }

  /// The `--engine` option, else the configured engine, else
  /// [CliConfig.defaultEngine].
  TranslationEngine selectedEngine() => resolveEngine(
    option('engine') ?? config.engine ?? CliConfig.defaultEngine,
    providers,
  );

  /// The text from the positional arguments, or standard input when there
  /// are none (or the only one is `-`).
  Future<String> readText({String what = 'text'}) async {
    final rest = args.rest;
    final String text;
    if (rest.isEmpty || (rest.length == 1 && rest.single == '-')) {
      if (console.stdinHasTerminal) {
        throw CliException.usage(
          'No $what given.',
          hint:
              'Pass it as an argument or pipe it in, e.g. '
              'echo "Bonjour" | mozhi $name',
        );
      }
      text = await console.readStdin();
    } else {
      text = rest.join(' ');
    }
    if (text.trim().isEmpty) {
      throw CliException.usage('The $what is empty.');
    }
    return text;
  }

  /// Prints [value] as indented JSON on standard output.
  void printJson(Object? value) => logger.info(encodeJson(value));

  /// Prints a dimmed side note on standard error (never mixed into piped
  /// output).
  void note(String message) =>
      logger.err(message, style: (m) => darkGray.wrap(m));

  /// Whether to show interactive extras (notes, progress spinners).
  bool get interactive =>
      console.stdoutHasTerminal || logger.level.index <= Level.debug.index;

  /// Bold when the terminal supports it.
  String bold(String text) =>
      console.supportsAnsiEscapes ? styleBold.wrap(text)! : text;
}
