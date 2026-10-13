import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi proofread [text]`: grammar, spelling and style fixes by an AI
/// provider.
class ProofreadCommand extends MozhiCommand {
  new(super.context) {
    addEngineOption(
      help:
          'AI provider to use (ai or ai:<provider>). Default: the default '
          'engine when it is an AI provider, else the first provider.',
    );
    argParser
      ..addOption(
        'style',
        allowed: [for (final value in WritingStyle.values) value.name],
        defaultsTo: WritingStyle.general.name,
        help: 'Kind of text.',
      )
      ..addOption(
        'level',
        allowed: [for (final value in CorrectionLevel.values) value.name],
        defaultsTo: CorrectionLevel.standard.name,
        allowedHelp: {
          'light': 'Only clear errors.',
          'standard': 'Errors and awkward phrasing.',
          'comprehensive': 'Also style, clarity and flow.',
        },
        help: 'How much to change.',
      )
      ..addOption(
        'formality',
        valueHelp: 'level',
        allowed: [for (final value in Formality.values) kebabCase(value.name)],
        help: 'Adjust the formality.',
      )
      ..addOption(
        'context',
        valueHelp: 'text',
        help: 'What the text is for, e.g. "cover letter".',
      )
      ..addFlag(
        'text-only',
        abbr: 'q',
        negatable: false,
        help: 'Print only the corrected text.',
      );
    addJsonFlag();
  }

  @override
  String get name => 'proofread';

  @override
  List<String> get aliases => ['proof'];

  @override
  String get description =>
      'Fix grammar, spelling and style with an AI provider.';

  @override
  String get invocation => 'mozhi proofread [arguments] [text]';

  @override
  Future<int> run() async {
    final text = await readText();
    final engine = _engine();
    final formality = option('formality');
    final result = await withRepository(
      (repository) => repository.proofread(
        engine,
        text,
        style: parseChoice('style', option('style')!, WritingStyle.values),
        level: parseChoice('level', option('level')!, CorrectionLevel.values),
        formality: formality == null
            ? Formality.automatic
            : parseChoice('formality', formality, Formality.values),
        context: option('context') ?? '',
      ),
    );
    if (jsonOutput) {
      printJson(proofreadJson(result));
      return ExitCode.success.code;
    }
    logger.info(result.correctedText);
    if (flag('text-only')) return ExitCode.success.code;
    logger.info('');
    if (result.edits.isEmpty) {
      logger.info(green.wrap('No changes needed.'));
    } else {
      logger.info(
        bold(
          '${result.edits.length} '
          '${result.edits.length == 1 ? 'change' : 'changes'}:',
        ),
      );
      for (final edit in result.edits) {
        final change = edit.replacement.isEmpty
            ? '${red.wrap('- ${edit.original}')}'
            : '${red.wrap(edit.original)} → ${green.wrap(edit.replacement)}';
        logger.info(
          '  • $change ${darkGray.wrap('(${edit.category.replaceAll('_', ' ')})')}'
          '${edit.explanation.isEmpty ? '' : '\n    ${edit.explanation}'}',
        );
      }
    }
    if (result.summary.isNotEmpty) {
      logger
        ..info('')
        ..info(result.summary);
    }
    return ExitCode.success.code;
  }

  TranslationEngine _engine() {
    final spec = option('engine');
    if (spec != null) {
      final engine = resolveEngine(spec, providers);
      if (!engine.isAi) {
        throw CliException.usage(
          'Proofreading needs an AI provider, not ${engine.name}.',
          hint: 'Use --engine ai or --engine ai:<provider>.',
        );
      }
      return engine;
    }
    final configured = config.engine;
    if (configured != null) {
      final engine = resolveEngine(configured, providers);
      if (engine.isAi) return engine;
    }
    final first = providers.firstOrNull;
    if (first == null) {
      throw const CliException.usage(
        'Proofreading needs an AI provider and none is configured.',
        hint:
            'Add one, e.g.: mozhi config providers add --preset ollama '
            '--model gemma3',
      );
    }
    return aiEngine(first);
  }
}
