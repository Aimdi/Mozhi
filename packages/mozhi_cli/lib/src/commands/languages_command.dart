import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi languages`: the languages an engine supports.
class LanguagesCommand extends MozhiCommand {
  new(super.context) {
    addEngineOption();
    addInstanceOption();
    argParser.addFlag(
      'source',
      abbr: 's',
      negatable: false,
      help: 'List source languages instead of target languages.',
    );
    addJsonFlag();
  }

  @override
  String get name => 'languages';

  @override
  List<String> get aliases => ['langs'];

  @override
  String get description =>
      'List the languages an engine supports (optionally filtered).';

  @override
  String get invocation => 'mozhi languages [arguments] [filter]';

  @override
  Future<int> run() => withRepository((repository) async {
    final engine = selectedEngine();
    final source = flag('source');
    final all = source
        ? await repository.getSourceLanguages(engine)
        : await repository.getTargetLanguages(engine);
    final filter = args.rest.join(' ').trim().toLowerCase();
    final languages = [
      for (final language in all)
        if (filter.isEmpty || _matches(language, filter)) language,
    ];
    if (jsonOutput) {
      printJson([for (final language in languages) languageJson(language)]);
      return ExitCode.success.code;
    }
    if (languages.isEmpty) {
      logger.info('No ${engine.name} language matches "$filter".');
      return ExitCode.success.code;
    }
    logger.info(
      renderTable(
        ['CODE', 'NAME', 'NATIVE NAME'],
        [
          for (final language in languages)
            [language.code, language.name, language.nativeName ?? ''],
        ],
        styleHeader: bold,
      ),
    );
    if (interactive) {
      note(
        '${languages.length} ${source ? 'source' : 'target'} languages '
        '(${engine.name})'
        '${engine.isAi && !source ? '; AI engines also accept free-form '
                  'targets such as "Pirate speak"' : ''}.',
      );
    }
    return ExitCode.success.code;
  });

  static bool _matches(Language language, String filter) =>
      language.code.toLowerCase() == filter ||
      language.name.toLowerCase().contains(filter) ||
      (language.nativeName?.toLowerCase().contains(filter) ?? false);
}
