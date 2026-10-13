import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/commands.dart';
import 'package:mozhi_cli/src/console.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/version.dart';

const executableName = 'mozhi';
const packageName = 'mozhi_cli';
const description =
    'Translate text with self-hosted Mozhi instances (Google, DeepL, Yandex, '
    'Reverso, LibreTranslate, MyMemory, DuckDuckGo) and AI providers '
    '(OpenAI-compatible, Anthropic, Gemini, Ollama).';

/// {@template mozhi_cli_command_runner}
/// The `mozhi` command-line translator.
///
/// ```bash
/// $ mozhi translate "Bonjour le monde" --to en
/// ```
/// {@endtemplate}
class MozhiCliCommandRunner extends CompletionCommandRunner<int> {
  /// {@macro mozhi_cli_command_runner}
  ///
  /// [console], [repositoryFactory] and [configStoreFactory] replace the
  /// real terminal, network and configuration file in tests.
  new({
    Logger? logger,
    Console? console,
    RepositoryFactory? repositoryFactory,
    ConfigStoreFactory? configStoreFactory,
  }) : _logger = logger ?? Logger(),
       super(executableName, description) {
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version.',
      )
      ..addFlag(
        'verbose',
        negatable: false,
        help: 'Print diagnostic details (and stack traces of internal errors).',
      )
      ..addOption(
        'config',
        valueHelp: 'file',
        help:
            'Configuration file to use instead of '
            r'$XDG_CONFIG_HOME/mozhi/config.json (or $MOZHI_CONFIG).',
      );

    final context = CliContext(
      logger: _logger,
      console: console,
      repositoryFactory: repositoryFactory,
      configStoreFactory: configStoreFactory,
    );
    addCommand(TranslateCommand(context));
    addCommand(ProofreadCommand(context));
    addCommand(DetectCommand(context));
    addCommand(EnginesCommand(context));
    addCommand(LanguagesCommand(context));
    addCommand(InstancesCommand(context));
    addCommand(ConfigCommand(context));
  }

  final Logger _logger;

  /// Completion files are only installed on request
  /// (`mozhi install-completion-files`); shell profiles are never modified
  /// behind the user's back.
  @override
  bool get enableAutoInstall => false;

  @override
  String get invocation => '$executableName <command> [arguments]';

  @override
  String get usageFooter => '''

Examples:
  mozhi translate "Bonjour le monde" --to en
  echo "Guten Morgen" | mozhi translate --to ja --engine deepl
  mozhi translate --compare --to es "How are you?"
  mozhi config providers add --preset ollama --model gemma3 --default
  mozhi translate --engine ai --formality more --to de "See you tomorrow"
  mozhi instances ping

Exit codes: 0 success, 64 usage error, 66 missing input file,
69 instance or provider unavailable, 70 internal error, 78 bad config.''';

  @override
  void printUsage() => _logger.info(usage);

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);
      if (topLevelResults['verbose'] == true) {
        _logger.level = Level.verbose;
      }
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on UsageException catch (e) {
      // Show the usage of the command that was misused.
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    } on Object catch (error, stackTrace) {
      final failure = describeError(error);
      _logger.err(failure.message);
      if (failure.hint case final hint?) {
        _logger.err(hint, style: (m) => m);
      }
      if (failure.exitCode == ExitCode.software) {
        _logger.detail('$stackTrace');
      }
      return failure.exitCode.code;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Fast track completion command
    if (topLevelResults.command?.name == 'completion') {
      await super.runCommand(topLevelResults);
      return ExitCode.success.code;
    }

    _logger
      ..detail('Argument information:')
      ..detail('  Top level options:');
    for (final option in topLevelResults.options) {
      if (topLevelResults.wasParsed(option)) {
        _logger.detail('  - $option: ${topLevelResults[option]}');
      }
    }
    for (
      var command = topLevelResults.command;
      command != null;
      command = command.command
    ) {
      _logger
        ..detail('  Command: ${command.name}')
        ..detail('    Command options:');
      for (final option in command.options) {
        if (command.wasParsed(option)) {
          // Never echo secrets into logs.
          final value = option == 'api-key' ? '********' : command[option];
          _logger.detail('    - $option: $value');
        }
      }
    }

    if (topLevelResults['version'] == true) {
      _logger.info(packageVersion);
      return ExitCode.success.code;
    }
    return await super.runCommand(topLevelResults);
  }
}
