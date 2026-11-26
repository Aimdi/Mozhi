import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi dictionary <word>`: look up a word or phrase with an AI provider.
class DictionaryCommand extends MozhiCommand {
  new(super.context) {
    argParser
      ..addOption(
        'from',
        abbr: 'f',
        valueHelp: 'language',
        help:
            'Language of the word. Default: the configured source, else auto.',
      )
      ..addOption(
        'to',
        abbr: 't',
        valueHelp: 'language',
        help:
            'Target language for translations. Default: the configured '
            'target, else en.',
      );
    addEngineOption(
      help:
          'AI provider to use (ai or ai:<provider>). Default: the default '
          'engine when it is an AI provider, else the first AI provider.',
    );
    argParser
      ..addOption(
        'verbosity',
        allowed: const ['concise', 'standard', 'detailed', 'comprehensive'],
        defaultsTo: 'standard',
        allowedHelp: const {
          'concise': 'Fewest common senses, one example, minimal notes.',
          'standard': 'Main senses with a couple of examples.',
          'detailed': 'Many senses, several examples, etymology and notes.',
          'comprehensive': 'Alias for detailed.',
        },
        help: 'How detailed the dictionary entry should be.',
      )
      ..addOption(
        'context',
        valueHelp: 'text',
        help: 'Sentence or situation where the word appeared.',
      );
    addJsonFlag();
  }

  @override
  String get name => 'dictionary';

  @override
  List<String> get aliases => ['dict', 'd'];

  @override
  String get description =>
      'Look up a word or phrase in the AI dictionary (definitions, '
      'translations, examples, etymology).';

  @override
  String get invocation => 'mozhi dictionary [arguments] <word>';

  @override
  Future<int> run() async {
    final word = (await readText(what: 'word')).trim();
    final engine = resolveAiEngine(
      option('engine'),
      config,
      providers,
      feature: 'Dictionary lookup',
    );
    final source = resolveLanguage(
      option('from') ?? config.source ?? 'auto',
      allowAuto: true,
    );
    final target = resolveLanguage(
      option('to') ?? config.target ?? CliConfig.defaultTarget,
      allowCustom: true,
    );
    final verbosity = parseChoice(
      'verbosity',
      option('verbosity')!,
      DictionaryVerbosity.values,
      aliases: const {'detailed': DictionaryVerbosity.comprehensive},
    );
    final entry = await withRepository(
      (repository) => repository.lookUp(
        engine,
        word,
        source: source,
        target: target,
        context: option('context') ?? '',
        verbosity: verbosity,
      ),
    );
    if (jsonOutput) {
      printJson(dictionaryJson(entry));
      return ExitCode.success.code;
    }
    formatDictionaryEntry(entry, bold: bold).forEach(logger.info);
    return ExitCode.success.code;
  }
}

/// Formats [entry] as clean terminal lines.
List<String> formatDictionaryEntry(
  DictionaryEntry entry, {
  required String Function(String) bold,
}) {
  final lines = <String>[];
  if (entry.didYouMean case final suggestion?) {
    lines.add('${darkGray.wrap('Did you mean:')} ${bold(suggestion)}?');
  }
  final headerParts = [
    bold(entry.word),
    if (entry.pronunciation.isNotEmpty) darkGray.wrap(entry.pronunciation)!,
    if (entry.partsOfSpeech.isNotEmpty)
      cyan.wrap('(${entry.partsOfSpeech.join(', ')})')!,
  ];
  lines.add(headerParts.join('  '));

  if (entry.senses.isNotEmpty) {
    lines.add('');
    for (var i = 0; i < entry.senses.length; i++) {
      final sense = entry.senses[i];
      final tags = [
        if (sense.partOfSpeech.isNotEmpty) sense.partOfSpeech,
        if (sense.usage.isNotEmpty) sense.usage,
      ];
      final tag = tags.isEmpty
          ? ''
          : '${darkGray.wrap('[${tags.join(', ')}]')} ';
      lines.add('${i + 1}. $tag${sense.definition}');
      if (sense.translations.isNotEmpty) {
        lines.add('   → ${sense.translations.join(', ')}');
      }
    }
  }

  if (entry.examples.isNotEmpty) {
    lines
      ..add('')
      ..add(bold('Examples:'));
    for (final ex in entry.examples) {
      lines.add('  • ${ex.source}');
      if (ex.translation.isNotEmpty) {
        lines.add('    ${darkGray.wrap('→ ${ex.translation}')}');
      }
    }
  }

  if (entry.synonyms.isNotEmpty) {
    lines
      ..add('')
      ..add('${bold('Synonyms:')} ${entry.synonyms.join(', ')}');
  }
  if (entry.relatedWords.isNotEmpty) {
    lines.add('${bold('Related:')} ${entry.relatedWords.join(', ')}');
  }
  if (entry.etymology.isNotEmpty) {
    lines
      ..add('')
      ..add('${bold('Etymology:')} ${entry.etymology}');
  }
  if (entry.notes.isNotEmpty) {
    lines
      ..add('')
      ..add('${bold('Notes:')} ${entry.notes}');
  }
  return lines;
}
