import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:mozhi_cli/src/web/web_page_reader.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi web <url>`: fetch, extract readable text, and translate a web page.
class WebCommand extends MozhiCommand {
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
        help: 'Write the translated Markdown to this file instead of stdout.',
      )
      ..addOption(
        'concurrency',
        abbr: 'j',
        valueHelp: 'n',
        defaultsTo: '2',
        help: 'Maximum blocks to translate in parallel (1–8).',
      )
      ..addFlag(
        'bilingual',
        negatable: false,
        help: 'Show each original block above its translation.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Fetch and extract readable blocks without calling a translation '
            'engine.',
      )
      ..addMultiOption(
        'glossary',
        abbr: 'g',
        valueHelp: 'term=translation',
        splitCommas: false,
        help: 'Required translation of a term (repeatable).',
      )
      ..addSeparator('AI options (ignored by Mozhi engines):')
      ..addOption(
        'formality',
        valueHelp: 'level',
        allowed: [for (final value in Formality.values) kebabCase(value.name)],
        help: 'How formal the translation should be.',
      )
      ..addOption(
        'style',
        allowed: [
          for (final value in TranslationStyle.values) kebabCase(value.name),
        ],
        help: 'Natural (fluent) or literal translation.',
      )
      ..addOption(
        'context',
        valueHelp: 'text',
        help: 'Extra context for the translation.',
      );
    addJsonFlag();
  }

  @override
  String get name => 'web';

  @override
  List<String> get aliases => ['page', 'url'];

  @override
  String get description =>
      'Fetch a web page, extract its readable content, and translate it to '
      'Markdown or JSON.';

  @override
  String get invocation => 'mozhi web [arguments] <url>';

  @override
  Future<int> run() async {
    if (args.rest.length != 1) {
      throw CliException.usage(
        'Expected one URL to translate.',
        hint: 'Usage: $invocation',
      );
    }
    final rawUrl = args.rest.single.trim();
    final uri = Uri.tryParse(
      rawUrl.contains('://') ? rawUrl : 'https://$rawUrl',
    );
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw CliException.usage('Invalid URL "$rawUrl".');
    }

    final concurrencyRaw = option('concurrency') ?? '2';
    final concurrency = int.tryParse(concurrencyRaw);
    if (concurrency == null || concurrency < 1 || concurrency > 8) {
      throw CliException.usage(
        'Invalid --concurrency "$concurrencyRaw". Expected an integer from '
        '1 to 8.',
      );
    }

    final engine = selectedEngine();
    var source = resolveLanguage(
      option('from') ?? config.source ?? 'auto',
      allowAuto: true,
    );
    var target = resolveLanguage(
      option('to') ?? config.target ?? CliConfig.defaultTarget,
      allowCustom: engine.isAi,
    );
    final glossary = {
      ...config.glossary,
      ...parseGlossary(multiOption('glossary')),
    };
    final options = _options(engine, glossary);
    final dryRun = flag('dry-run');
    final bilingual = flag('bilingual');
    final outputPath = option('output');

    final page = await context.webPageFetcher(uri);
    final article = extractReadableArticle(page);
    if (article.blocks.isEmpty && article.title == null) {
      throw CliException(
        'No readable text found at ${page.url}.',
        exitCode: ExitCode.data,
      );
    }

    final textsToTranslate = <String>[
      ?article.title,
      for (final block in article.blocks) block.text,
    ];

    if (dryRun) {
      if (jsonOutput) {
        printJson({
          'url': page.url.toString(),
          'engine': engine.id,
          'source': source.code,
          'target': target.code,
          'dryRun': true,
          'title': ?article.title,
          'blocks': [
            for (final block in article.blocks)
              {
                'kind': block.kind.name,
                if (block.level > 0) 'level': block.level,
                'text': block.text,
              },
          ],
        });
        return ExitCode.success.code;
      }
      logger.info(
        'Dry run: ${textsToTranslate.length} readable '
        '${textsToTranslate.length == 1 ? 'block' : 'blocks'} '
        'from ${page.url} (${source.code} → ${target.code}).',
      );
      if (article.title case final title?) {
        logger.info('  [title] $title');
      }
      for (var i = 0; i < article.blocks.length; i++) {
        final b = article.blocks[i];
        logger.info('  [${b.kind.name}:${i + 1}] ${b.text}');
      }
      return ExitCode.success.code;
    }

    final translated = List<String>.filled(textsToTranslate.length, '');
    await withRepository((repository) async {
      if (engine.isMozhi) {
        final supported = await Future.wait([
          _supported(repository, engine, source, isSource: true),
          _supported(repository, engine, target, isSource: false),
        ]);
        source = supported.first;
        target = supported.last;
      }
      final total = textsToTranslate.length;
      final progress = interactive && !jsonOutput && total > 0
          ? logger.progress('Translating 0/$total blocks')
          : null;
      var nextIdx = 0;
      var completed = 0;
      try {
        Future<void> worker() async {
          while (true) {
            if (nextIdx >= total) return;
            final idx = nextIdx++;
            final request = TranslationRequest(
              text: textsToTranslate[idx],
              source: source,
              target: target,
              options: options,
            );
            final result = await repository
                .translate(engine, request)
                .lastWhere((r) => r.isComplete);
            translated[idx] = result.text;
            progress?.update('Translating ${++completed}/$total blocks');
          }
        }

        final workerCount = concurrency < total ? concurrency : total;
        await Future.wait([for (var w = 0; w < workerCount; w++) worker()]);
        progress?.complete('Translated $total blocks');
      } on Object {
        progress?.fail();
        rethrow;
      }
    });

    final hasTitle = article.title != null;
    final translatedTitle = hasTitle ? translated.first : null;
    final blockTranslations = hasTitle ? translated.sublist(1) : translated;

    final markdown = _renderMarkdown(
      url: page.url,
      title: article.title,
      translatedTitle: translatedTitle,
      blocks: article.blocks,
      translations: blockTranslations,
      bilingual: bilingual,
    );

    if (outputPath != null) {
      try {
        final file = io.File(outputPath);
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        file.writeAsStringSync(markdown);
      } on io.FileSystemException catch (error) {
        throw CliException(
          'Cannot write $outputPath: ${error.message}',
          exitCode: ExitCode.cantCreate,
        );
      }
    }

    if (jsonOutput) {
      printJson({
        'url': page.url.toString(),
        'engine': engine.id,
        'source': source.code,
        'target': target.code,
        'title': ?article.title,
        'translatedTitle': ?translatedTitle,
        'outputFile': ?outputPath,
        'blocks': [
          for (var i = 0; i < article.blocks.length; i++)
            {
              'kind': article.blocks[i].kind.name,
              if (article.blocks[i].level > 0) 'level': article.blocks[i].level,
              'source': article.blocks[i].text,
              'translation': blockTranslations[i],
            },
        ],
      });
      return ExitCode.success.code;
    }

    if (outputPath != null) {
      logger.success(
        'Translated ${textsToTranslate.length} '
        '${textsToTranslate.length == 1 ? 'block' : 'blocks'} → $outputPath',
      );
    } else {
      logger.write(markdown);
    }
    return ExitCode.success.code;
  }

  String _renderMarkdown({
    required Uri url,
    required String? title,
    required String? translatedTitle,
    required List<ReadableBlock> blocks,
    required List<String> translations,
    required bool bilingual,
  }) {
    final parts = <String>[];
    if (translatedTitle != null) {
      if (bilingual && title != null) {
        parts.add('# $translatedTitle\n\n*$title*');
      } else {
        parts.add('# $translatedTitle');
      }
    }
    parts.add('Source: $url');
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final tr = translations[i];
      if (bilingual) {
        parts.add(
          '${block.formatMarkdown(block.text)}\n\n${block.formatMarkdown(tr)}',
        );
      } else {
        parts.add(block.formatMarkdown(tr));
      }
    }
    return '${parts.join('\n\n')}\n';
  }

  TranslationOptions _options(
    TranslationEngine engine,
    Map<String, String> glossary,
  ) {
    T? choice<T extends Enum>(String name, List<T> values) {
      final value = option(name);
      return value == null ? null : parseChoice(name, value, values);
    }

    final full = TranslationOptions(
      style:
          choice('style', TranslationStyle.values) ?? TranslationStyle.natural,
      formality: choice('formality', Formality.values) ?? Formality.automatic,
      context: option('context') ?? '',
      glossary: glossary,
    );
    if (engine.isAi || engine.isMt) return full;
    return glossary.isEmpty
        ? const TranslationOptions()
        : TranslationOptions(glossary: glossary);
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
}
