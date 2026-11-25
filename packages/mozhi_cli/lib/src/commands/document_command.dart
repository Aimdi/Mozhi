import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/documents/document_handler.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi document <file>`: translate structured text & localization files.
class DocumentCommand extends MozhiCommand {
  new(super.context) {
    argParser
      ..addOption(
        'from',
        abbr: 'f',
        valueHelp: 'language',
        help: 'Source language. Default: configured source, else auto.',
      )
      ..addOption(
        'to',
        abbr: 't',
        valueHelp: 'language',
        help: 'Target language. Default: configured target, else en.',
      );
    addEngineOption();
    addInstanceOption(withAbbr: false);
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'file',
        help: 'Write the translated document to this file instead of stdout.',
      )
      ..addFlag(
        'in-place',
        abbr: 'i',
        negatable: false,
        help: 'Overwrite the input file with the translation.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Parse the document and report translatable segments without '
            'calling a translation engine or writing files.',
      )
      ..addMultiOption(
        'glossary',
        abbr: 'g',
        valueHelp: 'term=translation',
        splitCommas: false,
        help:
            'Required translation of a term (repeatable; merged with saved '
            'config glossary).',
      )
      ..addOption(
        'glossary-file',
        valueHelp: 'file',
        help:
            'File with one "term=translation" (or tab-separated) entry per '
            'line; lines starting with # are ignored.',
      )
      ..addOption(
        'format',
        valueHelp: 'ext',
        help:
            'Override the format inferred from the file extension '
            '(txt, md, json, arb, srt, vtt, po, properties, yaml, csv, tsv).',
      );
    addJsonFlag();
  }

  @override
  String get name => 'document';

  @override
  List<String> get aliases => ['doc'];

  @override
  String get description =>
      'Translate structured text and localization files '
      '(.txt, .md, .json, .arb, .srt, .vtt, .po, .properties, .yml/.yaml, '
      '.toml, .tmx, .csv/.tsv) while preserving keys, timestamps and '
      'structure.';

  @override
  String get invocation => 'mozhi document [arguments] <file>';

  @override
  Future<int> run() async {
    if (args.rest.length != 1) {
      throw CliException.usage(
        'Expected one input file path.',
        hint: 'Usage: $invocation',
      );
    }
    final inputPath = args.rest.single;
    final outputPath = option('output');
    final inPlace = flag('in-place');
    final dryRun = flag('dry-run');
    if (outputPath != null && inPlace) {
      throw const CliException.usage(
        'Cannot combine --output (-o) and --in-place (-i).',
      );
    }

    final String content;
    try {
      content = io.File(inputPath).readAsStringSync();
    } on io.FileSystemException catch (error) {
      throw CliException(
        'Cannot read document $inputPath: ${error.message}',
        exitCode: ExitCode.noInput,
      );
    }

    final engine = selectedEngine();
    final sourceInput = option('from') ?? config.source ?? 'auto';
    final targetInput =
        option('to') ?? config.target ?? CliConfig.defaultTarget;
    final glossary = {
      ...config.glossary,
      ..._glossaryFile(),
      ...parseGlossary(multiOption('glossary')),
    };

    var source = resolveLanguage(sourceInput, allowAuto: true);
    var target = resolveLanguage(targetInput, allowCustom: engine.isAi);

    final parsed = DocumentHandlers.parse(
      inputPath,
      content,
      formatOverride: option('format'),
      targetLanguage: target.code,
    );

    if (dryRun) {
      if (jsonOutput) {
        printJson({
          'file': inputPath,
          'format': parsed.format,
          'engine': engine.id,
          'source': source.code,
          'target': target.code,
          'dryRun': true,
          'segments': parsed.segments.length,
          'translated': 0,
          'entries': [
            for (final seg in parsed.segments) {'id': seg.id, 'text': seg.text},
          ],
        });
        return ExitCode.success.code;
      }
      logger.info(
        'Dry run: ${parsed.segments.length} translatable '
        '${parsed.segments.length == 1 ? 'segment' : 'segments'} '
        'in $inputPath (${parsed.format}) using ${engine.id} '
        '(${source.code} → ${target.code}).',
      );
      for (final seg in parsed.segments) {
        final preview = seg.text.replaceAll('\n', r'\n');
        logger.info('  [${seg.id}] $preview');
      }
      return ExitCode.success.code;
    }

    final translations = <String>[];
    final options = glossary.isEmpty
        ? const TranslationOptions()
        : TranslationOptions(glossary: glossary);

    await withRepository((repository) async {
      if (engine.isMozhi) {
        final supported = await Future.wait([
          _supported(repository, engine, source, isSource: true),
          _supported(repository, engine, target, isSource: false),
        ]);
        source = supported.first;
        target = supported.last;
      }
      final total = parsed.segments.length;
      final progress = interactive && !jsonOutput && total > 0
          ? logger.progress('Translating 0/$total segments')
          : null;
      try {
        for (var i = 0; i < total; i++) {
          progress?.update('Translating ${i + 1}/$total segments');
          final segment = parsed.segments[i];
          final request = TranslationRequest(
            text: segment.text,
            source: source,
            target: target,
            options: options,
          );
          final result = await repository
              .translate(engine, request)
              .lastWhere((r) => r.isComplete);
          translations.add(result.text);
        }
        progress?.complete('Translated $total segments');
      } on Object {
        progress?.fail();
        rethrow;
      }
    });

    final rebuilt = parsed.rebuild(translations);
    final destination = inPlace ? inputPath : outputPath;
    if (destination != null) {
      try {
        final file = io.File(destination);
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        file.writeAsStringSync(rebuilt);
      } on io.FileSystemException catch (error) {
        throw CliException(
          'Cannot write translated document $destination: ${error.message}',
          exitCode: ExitCode.cantCreate,
        );
      }
    }

    if (jsonOutput) {
      printJson({
        'file': inputPath,
        'format': parsed.format,
        'engine': engine.id,
        'source': source.code,
        'target': target.code,
        'dryRun': false,
        'segments': parsed.segments.length,
        'translated': translations.length,
        'outputFile': ?destination,
        if (destination == null) 'text': rebuilt,
      });
      return ExitCode.success.code;
    }

    if (destination != null) {
      logger.success(
        'Translated ${translations.length} '
        '${translations.length == 1 ? 'segment' : 'segments'} '
        '(${parsed.format}) → $destination',
      );
    } else {
      logger.write(rebuilt);
    }
    return ExitCode.success.code;
  }

  Future<Language> _supported(
    TranslationRepository repository,
    TranslationEngine engine,
    Language language, {
    required bool isSource,
  }) async {
    if (language.isAuto) return language;
    final available = isSource
        ? await repository.getSourceLanguages(engine)
        : await repository.getTargetLanguages(engine);
    final match = LanguageMatcher.match(language, available);
    if (match != null) return match;
    final id = engine.mozhiEngine ?? engine.id;
    throw CliException.usage(
      '${engine.name} does not support "${language.name}"'
      '${isSource ? ' as a source language' : ''}.',
      hint: isSource
          ? 'See the supported languages with: '
                'mozhi languages --engine $id --source'
          : 'See the supported languages with: '
                'mozhi languages --engine $id',
    );
  }

  Map<String, String> _glossaryFile() {
    final path = option('glossary-file');
    if (path == null) return const {};
    final List<String> lines;
    try {
      lines = io.File(path).readAsLinesSync();
    } on io.FileSystemException catch (error) {
      throw CliException(
        'Cannot read the glossary file $path: ${error.message}',
        exitCode: ExitCode.noInput,
      );
    }
    return parseGlossary([
      for (final line in lines)
        if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
          if (line.contains('\t') && !line.contains('='))
            line.replaceFirst('\t', '=')
          else
            line,
    ]);
  }
}
