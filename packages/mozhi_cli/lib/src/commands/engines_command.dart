import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi engines`: the engines of the Mozhi instance and the configured
/// AI providers.
class EnginesCommand extends MozhiCommand {
  new(super.context) {
    addInstanceOption();
    addJsonFlag();
  }

  @override
  String get name => 'engines';

  @override
  String get description =>
      'List the engines of the Mozhi instance and the configured AI '
      'providers.';

  @override
  Future<int> run() => withRepository((repository) async {
    final engines = await repository.getEngines();
    if (!engines.any((engine) => engine.isMozhi)) {
      logger.warn(
        'No Mozhi instance could be reached; only AI engines are listed.',
      );
    }
    if (jsonOutput) {
      printJson([for (final engine in engines) engineJson(engine)]);
      return ExitCode.success.code;
    }
    final defaultId = _defaultEngineId();
    logger.info(
      renderTable(
        ['ID', 'NAME', 'DETAILS'],
        [
          for (final engine in engines)
            [
              '${engine.id}${engine.id == defaultId ? ' *' : ''}',
              engine.name,
              _details(engine),
            ],
        ],
        styleHeader: bold,
      ),
    );
    if (interactive && defaultId != null) {
      note('* default engine (change it with: mozhi config set engine <id>)');
    }
    return ExitCode.success.code;
  });

  String? _defaultEngineId() {
    try {
      return resolveEngine(
        config.engine ?? CliConfig.defaultEngine,
        providers,
      ).id;
    } on Exception {
      return null;
    }
  }

  static String _details(TranslationEngine engine) => [
    if (engine.isMozhi && engine.subtitle != null) 'via ${engine.subtitle}',
    if (engine.isAi && (engine.subtitle?.isNotEmpty ?? false)) engine.subtitle!,
    if (engine.isAi) engine.isLocal ? 'local' : 'cloud',
  ].join(' · ');
}
