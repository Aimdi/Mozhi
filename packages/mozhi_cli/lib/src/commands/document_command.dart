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
      ..addOption(
        'output-dir',
        valueHelp: 'dir',
        help:
            'Write translated documents into this directory, keeping each '
            'input filename (supports multiple input files).',
      )
      ..addFlag(
        'in-place',
        abbr: 'i',
        negatable: false,
        help: 'Overwrite the input file(s) with the translation.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Parse the document(s) and report translatable segments without '
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
            '(txt, md, html, json, arb, srt, vtt, po, properties, yaml, toml, '
            'xml, strings, xliff, tmx, csv, tsv).',
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
      '(.txt, .md, .html, .json, .arb, .srt, .vtt, .po, .properties, '
      '.yml/.yaml, .toml, .xml, .strings, .xliff, .tmx, .csv/.tsv) while '
      'preserving keys, timestamps and structure.';

  @override
  String get invocation => 'mozhi document [arguments] <file>...';

  @override
  Future<int> run() async {
    if (args.rest.isEmpty) {
      throw CliException.usage(
        'Expected at least one input file path.',
        hint: 'Usage: $invocation',
      );
    }
    final inputPaths = args.rest;
    final isBatch = inputPaths.length > 1;
    final outputPath = option('output');
    final outputDir = option('output-dir');
    final inPlace = flag('in-place');
    final dryRun = flag('dry-run');

    final outputModeCount =
        (outputPath != null ? 1 : 0) +
        (outputDir != null ? 1 : 0) +
        (inPlace ? 1 : 0);
    if (outputModeCount > 1) {
      throw const CliException.usage(
        'Cannot combine --output (-o), --output-dir, and --in-place (-i).',
      );
    }
    if (isBatch && outputPath != null) {
      throw const CliException.usage(
        'Cannot use --output (-o) with multiple input files.',
        hint: 'Use --output-dir <dir> or --in-place (-i) instead.',
      );
    }
    if (isBatch && !dryRun && outputDir == null && !inPlace) {
      throw const CliException.usage(
        'Multiple input files require --output-dir <dir>, --in-place (-i), '
        'or --dry-run.',
      );
    }

    final destinations = <String?>[];
    if (outputDir != null) {
      final seenNames = <String>{};
      final cleanDir = outputDir.replaceFirst(RegExp(r'[/\\]+$'), '');
      for (final path in inputPaths) {
        final name = _basenameOf(path);
        if (!seenNames.add(name)) {
          throw CliException.usage(
            'Multiple input files share the filename "$name" for --output-dir.',
            hint: 'Translate colliding files separately or use --in-place.',
          );
        }
        destinations.add('$cleanDir${io.Platform.pathSeparator}$name');
      }
    } else if (inPlace) {
      destinations.addAll(inputPaths);
    } else {
      destinations.add(outputPath);
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

    final parsedFiles = <({String path, ParsedDocument doc})>[];
    for (final inputPath in inputPaths) {
      final String content;
      try {
        content = io.File(inputPath).readAsStringSync();
      } on io.FileSystemException catch (error) {
        throw CliException(
          'Cannot read document $inputPath: ${error.message}',
          exitCode: ExitCode.noInput,
        );
      }
      parsedFiles.add((
        path: inputPath,
        doc: DocumentHandlers.parse(
          inputPath,
          content,
          formatOverride: option('format'),
          targetLanguage: target.code,
        ),
      ));
    }

    if (dryRun) {
      if (!isBatch) {
        final (:path, :doc) = parsedFiles.single;
        if (jsonOutput) {
          printJson({
            'file': path,
            'format': doc.format,
            'engine': engine.id,
            'source': source.code,
            'target': target.code,
            'dryRun': true,
            'segments': doc.segments.length,
            'translated': 0,
            'entries': [
              for (final seg in doc.segments) {'id': seg.id, 'text': seg.text},
            ],
          });
          return ExitCode.success.code;
        }
        logger.info(
          'Dry run: ${doc.segments.length} translatable '
          '${doc.segments.length == 1 ? 'segment' : 'segments'} '
          'in $path (${doc.format}) using ${engine.id} '
          '(${source.code} → ${target.code}).',
        );
        for (final seg in doc.segments) {
          final preview = seg.text.replaceAll('\n', r'\n');
          logger.info('  [${seg.id}] $preview');
        }
        return ExitCode.success.code;
      }

      final totalSegments = parsedFiles.fold<int>(
        0,
        (sum, entry) => sum + entry.doc.segments.length,
      );
      if (jsonOutput) {
        printJson({
          'dryRun': true,
          'engine': engine.id,
          'source': source.code,
          'target': target.code,
          'totalSegments': totalSegments,
          'files': [
            for (final (:path, :doc) in parsedFiles)
              {
                'file': path,
                'format': doc.format,
                'segments': doc.segments.length,
                'translated': 0,
                'entries': [
                  for (final seg in doc.segments)
                    {'id': seg.id, 'text': seg.text},
                ],
              },
          ],
        });
        return ExitCode.success.code;
      }
      logger.info(
        'Dry run: ${parsedFiles.length} files, $totalSegments translatable '
        '${totalSegments == 1 ? 'segment' : 'segments'} using ${engine.id} '
        '(${source.code} → ${target.code}).',
      );
      for (final (:path, :doc) in parsedFiles) {
        logger.info(
          '  $path (${doc.format}): ${doc.segments.length} '
          '${doc.segments.length == 1 ? 'segment' : 'segments'}',
        );
      }
      return ExitCode.success.code;
    }

    final options = glossary.isEmpty
        ? const TranslationOptions()
        : TranslationOptions(glossary: glossary);
    final allTranslations = <List<String>>[
      for (var i = 0; i < parsedFiles.length; i++) <String>[],
    ];
    final totalSegments = parsedFiles.fold<int>(
      0,
      (sum, entry) => sum + entry.doc.segments.length,
    );

    await withRepository((repository) async {
      if (engine.isMozhi) {
        final supported = await Future.wait([
          _supported(repository, engine, source, isSource: true),
          _supported(repository, engine, target, isSource: false),
        ]);
        source = supported.first;
        target = supported.last;
      }
      final progress = interactive && !jsonOutput && totalSegments > 0
          ? logger.progress('Translating 0/$totalSegments segments')
          : null;
      var completed = 0;
      try {
        for (var fileIdx = 0; fileIdx < parsedFiles.length; fileIdx++) {
          final doc = parsedFiles[fileIdx].doc;
          final out = allTranslations[fileIdx];
          for (final segment in doc.segments) {
            progress?.update(
              'Translating ${++completed}/$totalSegments segments',
            );
            final request = TranslationRequest(
              text: segment.text,
              source: source,
              target: target,
              options: options,
            );
            final result = await repository
                .translate(engine, request)
                .lastWhere((r) => r.isComplete);
            out.add(result.text);
          }
        }
        progress?.complete('Translated $totalSegments segments');
      } on Object {
        progress?.fail();
        rethrow;
      }
    });

    final rebuiltFiles = <String>[];
    for (var i = 0; i < parsedFiles.length; i++) {
      final rebuilt = parsedFiles[i].doc.rebuild(allTranslations[i]);
      rebuiltFiles.add(rebuilt);
      final destination = destinations[i];
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
    }

    if (!isBatch) {
      final (:path, :doc) = parsedFiles.single;
      final translations = allTranslations.single;
      final rebuilt = rebuiltFiles.single;
      final destination = destinations.single;
      if (jsonOutput) {
        printJson({
          'file': path,
          'format': doc.format,
          'engine': engine.id,
          'source': source.code,
          'target': target.code,
          'dryRun': false,
          'segments': doc.segments.length,
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
          '(${doc.format}) → $destination',
        );
      } else {
        logger.write(rebuilt);
      }
      return ExitCode.success.code;
    }

    if (jsonOutput) {
      printJson({
        'dryRun': false,
        'engine': engine.id,
        'source': source.code,
        'target': target.code,
        'totalSegments': totalSegments,
        'totalTranslated': totalSegments,
        'files': [
          for (var i = 0; i < parsedFiles.length; i++)
            {
              'file': parsedFiles[i].path,
              'format': parsedFiles[i].doc.format,
              'segments': parsedFiles[i].doc.segments.length,
              'translated': allTranslations[i].length,
              'outputFile': ?destinations[i],
            },
        ],
      });
      return ExitCode.success.code;
    }

    for (var i = 0; i < parsedFiles.length; i++) {
      final doc = parsedFiles[i].doc;
      final count = allTranslations[i].length;
      logger.success(
        'Translated $count ${count == 1 ? 'segment' : 'segments'} '
        '(${doc.format}) → ${destinations[i]}',
      );
    }
    return ExitCode.success.code;
  }

  static String _basenameOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
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
