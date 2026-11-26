import 'dart:io' as io;

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/resolvers.dart';

/// `mozhi config glossary`: manage saved default glossary pairs.
class GlossaryCommand extends Command<int> {
  new(CliContext context) {
    addSubcommand(GlossaryListCommand(context));
    addSubcommand(GlossaryAddCommand(context));
    addSubcommand(GlossaryRemoveCommand(context));
    addSubcommand(GlossaryImportCommand(context));
    addSubcommand(GlossaryExportCommand(context));
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

/// `mozhi config glossary import <file>`: import glossary pairs from a file.
class GlossaryImportCommand extends MozhiCommand {
  new(super.context) {
    argParser.addFlag(
      'replace',
      negatable: false,
      help: 'Replace existing saved glossary terms instead of merging.',
    );
  }

  @override
  String get name => 'import';

  @override
  String get description =>
      'Import saved glossary pairs from a key=value, TSV, or CSV file.';

  @override
  String get invocation => 'mozhi config glossary import [arguments] <file>';

  @override
  Future<int> run() async {
    if (args.rest.length != 1) {
      throw CliException.usage(
        'Expected one glossary file path.',
        hint: 'Usage: $invocation',
      );
    }
    final path = args.rest.single;
    final List<String> lines;
    try {
      lines = io.File(path).readAsLinesSync();
    } on io.FileSystemException catch (error) {
      throw CliException(
        'Cannot read glossary file $path: ${error.message}',
        exitCode: ExitCode.noInput,
      );
    }
    final isCsv = path.toLowerCase().endsWith('.csv');
    final entries = <String, String>{};
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (isCsv) {
        final cells = _splitCsvPair(line);
        if (cells == null) continue;
        final (term, translation) = cells;
        if (entries.isEmpty &&
            term.toLowerCase() == 'term' &&
            (translation.toLowerCase() == 'translation' ||
                translation.toLowerCase() == 'target')) {
          continue;
        }
        if (term.isNotEmpty && translation.isNotEmpty) {
          entries[term] = translation;
        }
      } else {
        final normalized = line.contains('\t') && !line.contains('=')
            ? line.replaceFirst('\t', '=')
            : line;
        entries.addAll(parseGlossary([normalized]));
      }
    }
    final next = flag('replace') ? entries : {...config.glossary, ...entries};
    saveConfig(config.withGlossary(next));
    logger.success(
      'Imported ${entries.length} glossary '
      '${entries.length == 1 ? 'entry' : 'entries'} (${next.length} total).',
    );
    return ExitCode.success.code;
  }

  static (String, String)? _splitCsvPair(String line) {
    final cells = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(ch);
        }
      } else if (ch == '"' && buf.isEmpty) {
        inQuotes = true;
      } else if (ch == ',') {
        cells.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString().trim());
    if (cells.length < 2) return null;
    return (cells[0], cells[1]);
  }
}

/// `mozhi config glossary export`: export saved glossary pairs.
class GlossaryExportCommand extends MozhiCommand {
  new(super.context) {
    argParser
      ..addOption(
        'format',
        allowed: const ['txt', 'tsv', 'csv', 'json'],
        defaultsTo: 'txt',
        help: 'Output format (txt = term=translation, tsv, csv, json).',
      )
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'file',
        help: 'Write the exported glossary to this file instead of stdout.',
      );
  }

  @override
  String get name => 'export';

  @override
  String get description => 'Export saved glossary pairs to stdout or a file.';

  @override
  Future<int> run() async {
    final entries = config.glossary;
    final format = option('format')!;
    final outputPath = option('output');
    final keys = entries.keys.toList()..sort();

    final String rendered;
    if (format == 'json') {
      if (outputPath == null) {
        printJson({for (final k in keys) k: entries[k]});
        return ExitCode.success.code;
      }
      rendered = '${encodeJson({for (final k in keys) k: entries[k]})}\n';
    } else if (format == 'tsv') {
      final body = [for (final k in keys) '$k\t${entries[k]}'].join('\n');
      rendered = keys.isEmpty ? '' : '$body\n';
    } else if (format == 'csv') {
      String q(String s) =>
          s.contains(',') || s.contains('"') || s.contains('\n')
          ? '"${s.replaceAll('"', '""')}"'
          : s;
      final body = [
        'term,translation',
        for (final k in keys) '${q(k)},${q(entries[k]!)}',
      ].join('\n');
      rendered = '$body\n';
    } else {
      final body = [for (final k in keys) '$k=${entries[k]}'].join('\n');
      rendered = keys.isEmpty ? '' : '$body\n';
    }

    if (outputPath != null) {
      try {
        final file = io.File(outputPath);
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        file.writeAsStringSync(rendered);
      } on io.FileSystemException catch (error) {
        throw CliException(
          'Cannot write glossary file $outputPath: ${error.message}',
          exitCode: ExitCode.cantCreate,
        );
      }
      logger.success(
        'Exported ${keys.length} glossary '
        '${keys.length == 1 ? 'entry' : 'entries'} → $outputPath',
      );
    } else {
      logger.write(rendered);
    }
    return ExitCode.success.code;
  }
}
