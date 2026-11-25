import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/resolvers.dart';

/// `mozhi config glossary`: manage saved default glossary pairs.
class GlossaryCommand extends Command<int> {
  new(CliContext context) {
    addSubcommand(GlossaryListCommand(context));
    addSubcommand(GlossaryAddCommand(context));
    addSubcommand(GlossaryRemoveCommand(context));
  }

  @override
  String get name => 'glossary';

  @override
  List<String> get aliases => ['glossaries'];

  @override
  String get description =>
      'Manage saved default glossary terms merged into translations.';
}

/// `mozhi config glossary list`.
class GlossaryListCommand extends MozhiCommand {
  new(super.context) {
    addJsonFlag();
  }

  @override
  String get name => 'list';

  @override
  List<String> get aliases => ['ls'];

  @override
  String get description => 'List the saved glossary pairs.';

  @override
  Future<int> run() async {
    final entries = config.glossary;
    if (jsonOutput) {
      printJson(entries);
      return ExitCode.success.code;
    }
    if (entries.isEmpty) {
      logger.info(
        'No saved glossary entries. Add one with: '
        'mozhi config glossary add "cloud=nuage"',
      );
      return ExitCode.success.code;
    }
    logger.info(
      renderTable(
        ['TERM', 'TRANSLATION'],
        [
          for (final MapEntry(:key, :value) in entries.entries) [key, value],
        ],
        styleHeader: bold,
      ),
    );
    return ExitCode.success.code;
  }
}

/// `mozhi config glossary add <term=translation>...`.
class GlossaryAddCommand extends MozhiCommand {
  new(super.context);

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add or update saved glossary entries ("term=translation" or '
      '"<term> <translation>").';

  @override
  String get invocation =>
      'mozhi config glossary add <term=translation> [more...]';

  @override
  Future<int> run() async {
    final rest = args.rest;
    if (rest.isEmpty) {
      throw const CliException.usage(
        'Expected at least one glossary entry.',
        hint: 'Example: mozhi config glossary add "cloud=nuage"',
      );
    }
    final Map<String, String> parsed;
    if (rest.length == 2 &&
        !rest.first.contains('=') &&
        !rest.first.contains(':') &&
        !rest.last.contains('=') &&
        !rest.last.contains(':')) {
      final term = rest.first.trim();
      final translation = rest.last.trim();
      if (term.isEmpty || translation.isEmpty) {
        throw const CliException.usage(
          'Glossary term and translation must not be empty.',
        );
      }
      parsed = {term: translation};
    } else {
      parsed = parseGlossary(rest);
    }
    final merged = {...config.glossary, ...parsed};
    saveConfig(config.withGlossary(merged));
    final count = parsed.length;
    logger.success(
      'Saved $count glossary ${count == 1 ? 'entry' : 'entries'} '
      '(${merged.length} total).',
    );
    return ExitCode.success.code;
  }
}

/// `mozhi config glossary remove <term>...`.
class GlossaryRemoveCommand extends MozhiCommand {
  new(super.context) {
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Remove every saved glossary entry.',
    );
  }

  @override
  String get name => 'remove';

  @override
  List<String> get aliases => ['rm'];

  @override
  String get description => 'Remove saved glossary entries by source term.';

  @override
  String get invocation => 'mozhi config glossary remove <term> [more...]';

  @override
  Future<int> run() async {
    if (flag('all')) {
      saveConfig(config.withGlossary(const {}));
      logger.success('Cleared all saved glossary entries.');
      return ExitCode.success.code;
    }
    final terms = args.rest;
    if (terms.isEmpty) {
      throw CliException.usage(
        'Expected at least one term to remove (or --all).',
        hint: 'Usage: $invocation',
      );
    }
    final updated = Map<String, String>.of(config.glossary);
    for (final raw in terms) {
      final key = raw.trim();
      if (updated.remove(key) != null) continue;
      final lower = key.toLowerCase();
      final match = updated.keys
          .where((k) => k.toLowerCase() == lower)
          .firstOrNull;
      if (match != null) {
        updated.remove(match);
        continue;
      }
      throw CliException.usage(
        'Glossary term "$key" is not saved.',
        hint: updated.isEmpty
            ? 'No glossary entries are saved.'
            : 'Saved terms: ${updated.keys.join(', ')}.',
      );
    }
    saveConfig(config.withGlossary(updated));
    logger.success(
      'Removed ${terms.length} glossary '
      '${terms.length == 1 ? 'entry' : 'entries'}.',
    );
    return ExitCode.success.code;
  }
}
