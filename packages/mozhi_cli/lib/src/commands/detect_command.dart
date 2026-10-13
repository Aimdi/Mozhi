import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi detect [text]`: detects the language of a text.
class DetectCommand extends MozhiCommand {
  new(super.context) {
    addEngineOption(
      help:
          'Use an AI provider (ai or ai:<provider>) instead of Google via '
          'the Mozhi instance.',
    );
    addInstanceOption();
    addJsonFlag();
  }

  @override
  String get name => 'detect';

  @override
  String get description => 'Detect the language of a text.';

  @override
  String get invocation => 'mozhi detect [arguments] [text]';

  @override
  Future<int> run() async {
    final text = await readText();
    final spec = option('engine');
    final engine = spec == null ? null : resolveEngine(spec, providers);
    final detected = await withRepository(
      (repository) => repository.detectLanguage(
        text,
        engine: engine != null && engine.isAi ? engine : null,
      ),
    );
    final name = LanguageCatalog.nameOf(detected.code);
    if (jsonOutput) {
      printJson({
        'code': detected.code,
        'name': name,
        if (detected.isUncertain) 'uncertain': true,
        if (detected.isMixed) 'mixed': true,
        if (detected.alternatives.isNotEmpty)
          'alternatives': detected.alternatives,
      });
      return ExitCode.success.code;
    }
    logger.info(
      '${detected.code}\t$name'
      '${detected.isUncertain ? ' (uncertain)' : ''}'
      '${detected.isMixed ? ' (mixed)' : ''}',
    );
    return ExitCode.success.code;
  }
}
