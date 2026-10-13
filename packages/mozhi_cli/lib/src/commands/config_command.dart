import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/commands/providers_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi config`: show and change the configuration file.
class ConfigCommand extends Command<int> {
  new(CliContext context) {
    addSubcommand(ConfigShowCommand(context));
    addSubcommand(ConfigSetCommand(context));
    addSubcommand(ConfigUnsetCommand(context));
    addSubcommand(ConfigPathCommand(context));
    addSubcommand(ProvidersCommand(context));
  }

  @override
  String get name => 'config';

  @override
  String get description =>
      'Show or change defaults (instance, engine, languages) and AI '
      'providers.';
}

String _keyHelp() => [
  for (final key in ConfigKey.values)
    '  ${key.name.padRight(10)}${key.description}',
].join('\n');

/// `mozhi config show`.
class ConfigShowCommand extends MozhiCommand {
  new(super.context) {
    addJsonFlag();
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show the configuration (API keys are hidden).';

  @override
  Future<int> run() async {
    final config = this.config;
    if (jsonOutput) {
      printJson({
        'path': configStore.path,
        ...config.toJson(),
        if (config.providers.isNotEmpty)
          'providers': [
            for (final provider in config.providers)
              {
                ...provider.toJson(),
                if (provider.config.apiKey?.isNotEmpty ?? false)
                  'apiKey': '********',
              },
          ],
      });
      return ExitCode.success.code;
    }
    String value(ConfigKey key, String fallback) =>
        config.valueOf(key) ?? darkGray.wrap(fallback)!;
    logger
      ..info('${bold('Config file')}  ${configStore.path}'
          '${configStore.exists ? '' : darkGray.wrap(' (not created yet)')}')
      ..info('')
      ..info(
        renderTable(
          ['SETTING', 'VALUE'],
          [
            [
              'instance',
              value(ConfigKey.instance, 'public instances, with failover'),
            ],
            ['engine', value(ConfigKey.engine, CliConfig.defaultEngine)],
            ['source', value(ConfigKey.source, 'auto')],
            ['target', value(ConfigKey.target, CliConfig.defaultTarget)],
          ],
          styleHeader: bold,
        ),
      )
      ..info('');
    if (config.providers.isEmpty) {
      logger.info(
        'No AI providers. Add one with: mozhi config providers add --help',
      );
    } else {
      logger.info(providersTable(config, styleHeader: bold));
    }
    if (configStore.isExposed) {
      logger.warn(
        '${configStore.path} is readable by other users. '
        'Fix it with: chmod 600 ${configStore.path}',
      );
    }
    return ExitCode.success.code;
  }
}

/// `mozhi config set <key> <value>`.
class ConfigSetCommand extends MozhiCommand {
  new(super.context);

  @override
  String get name => 'set';

  @override
  String get description => 'Set a default.\n\nKeys:\n${_keyHelp()}';

  @override
  String get invocation => 'mozhi config set <key> <value>';

  @override
  Future<int> run() async {
    if (args.rest.length < 2) {
      throw CliException.usage(
        'Expected a key and a value.',
        hint: 'Usage: $invocation\nKeys:\n${_keyHelp()}',
      );
    }
    final key = _parseKey(args.rest.first);
    final input = args.rest.skip(1).join(' ').trim();
    final (value, label) = switch (key) {
      ConfigKey.instance => _same(MozhiCommand.normalizeInstanceUrl(input)),
      ConfigKey.engine => _engine(input),
      ConfigKey.source => _language(
        resolveLanguage(input, allowAuto: true),
      ),
      ConfigKey.target => _language(
        resolveLanguage(input, allowCustom: true),
      ),
    };
    saveConfig(config.withValue(key, value));
    logger.success('Set ${key.name} to $label.');
    return ExitCode.success.code;
  }

  static (String, String) _same(String value) => (value, value);

  (String, String) _engine(String input) {
    final engine = resolveEngine(input, providers);
    return (engine.id, '${engine.id} (${engine.name})');
  }

  static (String, String) _language(Language language) => (
    language.code,
    language.isCustom || language.code == language.name
        ? language.code
        : '${language.code} (${language.name})',
  );
}

/// `mozhi config unset <key>`.
class ConfigUnsetCommand extends MozhiCommand {
  new(super.context);

  @override
  String get name => 'unset';

  @override
  String get description => 'Reset a default.\n\nKeys:\n${_keyHelp()}';

  @override
  String get invocation => 'mozhi config unset <key>';

  @override
  Future<int> run() async {
    if (args.rest.length != 1) {
      throw CliException.usage('Expected one key.', hint: 'Usage: $invocation');
    }
    final key = _parseKey(args.rest.single);
    saveConfig(config.withValue(key, null));
    logger.success('Reset ${key.name} to its default.');
    return ExitCode.success.code;
  }
}

/// `mozhi config path`.
class ConfigPathCommand extends MozhiCommand {
  new(super.context);

  @override
  String get name => 'path';

  @override
  String get description => 'Print the location of the configuration file.';

  @override
  Future<int> run() async {
    logger.info(configStore.path);
    return ExitCode.success.code;
  }
}

ConfigKey _parseKey(String input) =>
    ConfigKey.tryParse(input) ??
    (throw CliException.usage(
      'Unknown setting "$input".',
      hint: 'Keys:\n${_keyHelp()}',
    ));
