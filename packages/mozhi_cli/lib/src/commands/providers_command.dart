import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/format.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:translation_repository/translation_repository.dart';

/// Protocol names accepted by `--protocol`.
const protocolNames = <String, LlmProvider>{
  'openai': LlmProvider.openAiCompatible,
  'anthropic': LlmProvider.anthropic,
  'gemini': LlmProvider.gemini,
  'ollama': LlmProvider.ollama,
};

String protocolName(LlmProvider provider) => protocolNames.entries
    .firstWhere((entry) => entry.value == provider)
    .key;

/// A table of the providers in [config]; the default engine is starred.
String providersTable(
  CliConfig config, {
  String Function(String)? styleHeader,
}) => renderTable(
  ['ID', 'NAME', 'PROTOCOL', 'MODEL', 'BASE URL', 'KEY'],
  [
    for (final entry in config.providers)
      [
        '${entry.id}${config.engine == 'ai:${entry.id}' ? ' *' : ''}'
            '${entry.config.enabled ? '' : ' (disabled)'}',
        entry.name,
        protocolName(entry.config.provider),
        entry.config.model,
        entry.config.baseUrl,
        entry.keySource,
      ],
  ],
  styleHeader: styleHeader,
);

/// `mozhi config providers`: manage AI providers.
class ProvidersCommand extends Command<int> {
  new(CliContext context) {
    addSubcommand(ProvidersAddCommand(context));
    addSubcommand(ProvidersListCommand(context));
    addSubcommand(ProvidersRemoveCommand(context));
    addSubcommand(ProvidersTestCommand(context));
    addSubcommand(ProvidersModelsCommand(context));
  }

  @override
  String get name => 'providers';

  @override
  List<String> get aliases => ['provider', 'ai'];

  @override
  String get description =>
      'Manage AI providers (OpenAI-compatible, Anthropic, Gemini, Ollama).';
}

/// Common lookup of the provider named by the first positional argument.
mixin _ProviderArgument on MozhiCommand {
  ProviderEntry get provider {
    if (args.rest.length != 1) {
      throw CliException.usage(
        'Expected the id or name of one provider.',
        hint: 'Usage: $invocation',
      );
    }
    return config.findProvider(args.rest.single) ??
        (throw CliException.usage(
          'Unknown AI provider "${args.rest.single}".',
          hint: config.providers.isEmpty
              ? 'No providers are configured.'
              : 'Configured: ${config.providers.map((p) => p.id).join(', ')}',
        ));
  }

  @override
  String get invocation => 'mozhi config providers $name <id|name>';
}

/// `mozhi config providers add`.
class ProvidersAddCommand extends MozhiCommand {
  new(super.context) {
    argParser
      ..addOption(
        'preset',
        abbr: 'p',
        allowed: [for (final preset in AiProviderPreset.all) preset.id],
        allowedHelp: {
          for (final preset in AiProviderPreset.all)
            preset.id: '${preset.name}: ${preset.description}',
        },
        help: 'Start from a ready-made provider.',
      )
      ..addOption('name', abbr: 'n', help: 'Display name (default: preset).')
      ..addOption(
        'id',
        help: 'Stable id used in --engine ai:<id> (default: from the name).',
      )
      ..addOption(
        'protocol',
        allowed: protocolNames.keys,
        help: 'Wire protocol (required without --preset).',
      )
      ..addOption('base-url', valueHelp: 'url', help: 'API base URL.')
      ..addOption('model', abbr: 'm', help: 'Model id.')
      ..addSeparator('API key (stored in the config file, mode 0600):')
      ..addOption(
        'api-key',
        help:
            'The API key. Prefer --api-key-env or --api-key-stdin: '
            'arguments end up in the shell history.',
      )
      ..addOption(
        'api-key-env',
        valueHelp: 'VARIABLE',
        help: 'Read the key from this environment variable at run time.',
      )
      ..addFlag(
        'api-key-stdin',
        negatable: false,
        help: 'Read the key from standard input.',
      )
      ..addSeparator('Other options:')
      ..addOption(
        'effort',
        help: 'Reasoning effort hint (e.g. low, medium, high).',
      )
      ..addOption('temperature', help: 'Sampling temperature.')
      ..addMultiOption(
        'header',
        valueHelp: 'Name: value',
        splitCommas: false,
        help: 'Extra HTTP header (repeatable).',
      )
      ..addFlag(
        'vision',
        negatable: false,
        help: 'The model accepts images.',
      )
      ..addFlag(
        'default',
        negatable: false,
        help: 'Make it the default engine.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace a provider with the same id.',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add an AI provider.';

  @override
  String get invocation => 'mozhi config providers add [arguments]';

  @override
  Future<int> run() async {
    final preset = switch (option('preset')) {
      final id? => AiProviderPreset.byId(id),
      null => null,
    };
    final protocol = option('protocol');
    if (preset == null && protocol == null) {
      throw const CliException.usage(
        'Pass --preset or --protocol.',
        hint:
            'e.g. mozhi config providers add --preset anthropic '
            '--api-key-env ANTHROPIC_API_KEY',
      );
    }
    final name = option('name') ?? preset?.name;
    if (name == null) {
      throw const CliException.usage('Pass --name for a custom provider.');
    }
    final id = option('id') ?? _slug(name);
    if (id.isEmpty) throw const CliException.usage('The id must not be empty.');
    final existing = config.providers.where((p) => p.id == id).firstOrNull;
    if (existing != null && !flag('force')) {
      throw CliException.usage(
        'A provider with the id "$id" already exists.',
        hint: 'Pass --force to replace it, or choose another --id.',
      );
    }
    final baseUrl = option('base-url') ?? preset?.baseUrl ?? '';
    if (baseUrl.isEmpty) {
      throw const CliException.usage('Pass --base-url for this provider.');
    }
    final apiKey = await _apiKey(preset);
    final temperature = switch (option('temperature')) {
      final value? =>
        double.tryParse(value) ??
            (throw CliException.usage('Invalid --temperature "$value".')),
      null => null,
    };

    var provider = AiProviderConfig(
      id: id,
      name: name,
      provider: protocol != null
          ? protocolNames[protocol]!
          : preset!.provider,
      baseUrl: baseUrl,
      model: option('model') ?? preset?.defaultModel ?? '',
      apiKey: apiKey,
      presetId: preset?.id,
      effort: option('effort') ?? preset?.defaultEffort,
      temperature: temperature,
      headers: {...?preset?.headers, ..._headers()},
      supportsVision: flag('vision'),
    );
    final apiKeyEnv = option('api-key-env');
    if (provider.model.isEmpty) {
      provider = provider.copyWith(
        model: await _pickModel(
          apiKeyEnv == null
              ? provider
              : ProviderEntry(provider, apiKeyEnv: apiKeyEnv).resolve(
                  console.environment,
                ),
        ),
      );
    }

    final entry = ProviderEntry(provider, apiKeyEnv: apiKeyEnv);
    var updated = config.withProviders([
      for (final other in config.providers)
        if (other.id != id) other,
      entry,
    ]);
    if (flag('default')) {
      updated = updated.withValue(ConfigKey.engine, 'ai:$id');
    }
    saveConfig(updated);
    logger.success(
      '${existing == null ? 'Added' : 'Replaced'} $name '
      '(${provider.model}). Use it with: mozhi translate --engine ai:$id',
    );
    if (apiKey == null &&
        apiKeyEnv == null &&
        (preset?.requiresApiKey ?? false)) {
      logger.warn(
        '$name usually needs an API key; add one with --api-key-env or '
        '--api-key-stdin (and --force).',
      );
    }
    if (apiKeyEnv != null && !console.environment.containsKey(apiKeyEnv)) {
      logger.warn('\$$apiKeyEnv is not set in this shell.');
    }
    return ExitCode.success.code;
  }

  Future<String?> _apiKey(AiProviderPreset? preset) async {
    final given = option('api-key');
    if (given != null) return given;
    if (flag('api-key-stdin')) {
      final key = (await console.readStdin()).trim();
      if (key.isEmpty) {
        throw const CliException.usage('No API key on standard input.');
      }
      return key;
    }
    if (option('api-key-env') == null &&
        (preset?.requiresApiKey ?? false) &&
        console.stdinHasTerminal) {
      final key = logger
          .prompt(
            'API key for ${preset!.name} '
            '${preset.apiKeyUrl == null ? '' : '(${preset.apiKeyUrl}) '}'
            '- leave empty to skip:',
            hidden: true,
          )
          .trim();
      return key.isEmpty ? null : key;
    }
    return null;
  }

  Map<String, String> _headers() {
    final headers = <String, String>{};
    for (final header in multiOption('header')) {
      final colon = header.indexOf(':');
      final key = colon > 0 ? header.substring(0, colon).trim() : '';
      if (key.isEmpty) {
        throw CliException.usage(
          'Invalid --header "$header".',
          hint: 'Use "Name: value".',
        );
      }
      headers[key] = header.substring(colon + 1).trim();
    }
    return headers;
  }

  /// Asks the server for its models and takes the first one.
  Future<String> _pickModel(AiProviderConfig provider) async {
    final repository = context.repositoryFactory();
    final List<LlmModel> models;
    try {
      models = await repository.listModels(provider);
    } on Object catch (error) {
      throw CliException.usage(
        'Pass --model: the model list of ${provider.name} could not be '
        'loaded (${describeError(error).message}).',
      );
    } finally {
      repository.dispose();
    }
    if (models.isEmpty) {
      throw CliException.usage(
        'Pass --model: ${provider.name} did not report any models.',
      );
    }
    logger.info(
      'Using model ${models.first.id} '
      '(${models.length} available; pick another with --model --force).',
    );
    return models.first.id;
  }

  static String _slug(String name) => name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

/// `mozhi config providers list`.
class ProvidersListCommand extends MozhiCommand {
  new(super.context) {
    addJsonFlag();
  }

  @override
  String get name => 'list';

  @override
  List<String> get aliases => ['ls'];

  @override
  String get description => 'List the configured AI providers.';

  @override
  Future<int> run() async {
    if (jsonOutput) {
      printJson([
        for (final entry in config.providers)
          {
            ...entry.config.toJson(),
            'apiKeySource': entry.keySource,
            'local': entry.config.isLocal,
          },
      ]);
      return ExitCode.success.code;
    }
    if (config.providers.isEmpty) {
      logger.info(
        'No AI providers. Add one, e.g.:\n'
        '  mozhi config providers add --preset ollama --model gemma3\n'
        '  mozhi config providers add --preset anthropic '
        '--api-key-env ANTHROPIC_API_KEY',
      );
      return ExitCode.success.code;
    }
    logger.info(providersTable(config, styleHeader: bold));
    return ExitCode.success.code;
  }
}

/// `mozhi config providers remove <id|name>`.
class ProvidersRemoveCommand extends MozhiCommand with _ProviderArgument {
  new(super.context);

  @override
  String get name => 'remove';

  @override
  List<String> get aliases => ['rm'];

  @override
  String get description => 'Remove an AI provider (and its stored key).';

  @override
  Future<int> run() async {
    final removed = provider;
    var updated = config.withProviders([
      for (final other in config.providers)
        if (other.id != removed.id) other,
    ]);
    final wasDefault = config.engine == 'ai:${removed.id}';
    if (wasDefault) updated = updated.withValue(ConfigKey.engine, null);
    saveConfig(updated);
    logger.success('Removed ${removed.name}.');
    if (wasDefault) {
      logger.info(
        'It was the default engine; the default is now '
        '${CliConfig.defaultEngine}.',
      );
    }
    return ExitCode.success.code;
  }
}

/// `mozhi config providers test <id|name>`.
class ProvidersTestCommand extends MozhiCommand with _ProviderArgument {
  new(super.context);

  @override
  String get name => 'test';

  @override
  String get description =>
      'Send a short test translation to an AI provider.';

  @override
  Future<int> run() async {
    final entry = provider;
    final repository = context.repositoryFactory();
    final stopwatch = Stopwatch()..start();
    try {
      final output = await repository.testProvider(
        entry.resolve(console.environment),
      );
      logger.success(
        '${entry.name} works (${formatDuration(stopwatch.elapsed)}): '
        '"Hello, world!" -> "$output"',
      );
      return ExitCode.success.code;
    } finally {
      repository.dispose();
    }
  }
}

/// `mozhi config providers models <id|name>`.
class ProvidersModelsCommand extends MozhiCommand with _ProviderArgument {
  new(super.context) {
    addJsonFlag();
  }

  @override
  String get name => 'models';

  @override
  String get description => 'List the models an AI provider offers.';

  @override
  Future<int> run() async {
    final entry = provider;
    final repository = context.repositoryFactory();
    try {
      final models = await repository.listModels(
        entry.resolve(console.environment),
      );
      if (jsonOutput) {
        printJson([
          for (final model in models)
            {
              'id': model.id,
              'name': ?model.displayName,
              'contextWindow': ?model.contextWindow,
            },
        ]);
      } else if (models.isEmpty) {
        logger.info('${entry.name} did not report any models.');
      } else {
        logger.info(
          renderTable(
            ['MODEL', 'NAME'],
            [
              for (final model in models)
                [
                  '${model.id}${model.id == entry.config.model ? ' *' : ''}',
                  model.displayName ?? '',
                ],
            ],
            styleHeader: bold,
          ),
        );
      }
      return ExitCode.success.code;
    } finally {
      repository.dispose();
    }
  }
}
