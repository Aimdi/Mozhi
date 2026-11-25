import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/format.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/output/streaming_printer.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi translate [text]`: translates text from the arguments or stdin.
class TranslateCommand extends MozhiCommand {
  new(super.context) {
    argParser
      ..addOption(
        'to',
        abbr: 't',
        valueHelp: 'language',
        help:
            'Target language code or English name (fr, pt-BR, Japanese). '
            'AI engines also accept free-form targets such as '
            '"Pirate speak". Default: the configured target, else en.',
      )
      ..addOption(
        'from',
        abbr: 'f',
        valueHelp: 'language',
        help: 'Source language. Default: the configured source, else auto.',
      )
      ..addMultiOption(
        'engine',
        abbr: 'e',
        valueHelp: 'engine',
        help:
            'Translation engine: a Mozhi engine (google, deepl, yandex, '
            'reverso, libre, mymemory, duckduckgo or mozhi:<id>), or '
            'ai / ai:<provider> for a configured AI provider. Several '
            'engines can be given with --compare. Default: the configured '
            'engine, else mozhi:google.',
      )
      ..addFlag(
        'compare',
        abbr: 'c',
        negatable: false,
        help:
            'Translate with several engines at once: every Mozhi engine of '
            'the instance, or the engines given with --engine.',
      );
    addInstanceOption();
    argParser
      ..addFlag(
        'stream',
        defaultsTo: true,
        help: 'Show AI translations while they are generated (terminals only).',
      )
      ..addFlag(
        'json',
        negatable: false,
        help:
            'Print the result (with transliterations, synonyms, ...) as JSON.',
      )
      ..addSeparator('AI options (ignored by Mozhi engines):')
      ..addOption(
        'formality',
        valueHelp: 'level',
        allowed: [for (final value in Formality.values) kebabCase(value.name)],
        help: 'How formal the translation should be.',
      )
      ..addOption(
        'formality-context',
        valueHelp: 'text',
        help:
            'Extra tone notes for --formality, e.g. '
            '"my boss, but we are on first-name terms".',
      )
      ..addOption(
        'style',
        allowed: [
          for (final value in TranslationStyle.values) kebabCase(value.name),
        ],
        help: 'Natural (fluent) or literal (close to the source) translation.',
      )
      ..addOption(
        'reading-level',
        valueHelp: 'level',
        allowed: [for (final value in ReadingLevel.values) value.name],
        help: 'CEFR reading level of the output (a1 = simplest).',
      )
      ..addOption(
        'speaker-gender',
        valueHelp: 'gender',
        allowed: [for (final value in Gender.values) kebabCase(value.name)],
        help: 'Grammatical gender of the speaker.',
      )
      ..addOption(
        'addressee-gender',
        valueHelp: 'gender',
        allowed: [for (final value in Gender.values) kebabCase(value.name)],
        help: 'Grammatical gender of the person addressed.',
      )
      ..addOption(
        'context',
        valueHelp: 'text',
        help:
            'What the text is about or who it is for, e.g. '
            '"message to my landlord".',
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
        'instructions',
        valueHelp: 'text',
        help: 'Extra instruction for the model, e.g. "Keep it short".',
      )
      ..addSeparator('AI extras (require an AI provider):')
      ..addFlag(
        'alternatives',
        negatable: false,
        help: 'Show alternative translations and how they differ.',
      )
      ..addFlag(
        'explain',
        negatable: false,
        help: 'Explain the translation choices.',
      )
      ..addFlag(
        'insights',
        negatable: false,
        help: 'Show notable words, idioms and cultural nuances.',
      )
      ..addFlag(
        'romanize',
        negatable: false,
        help: 'Show Latin-script romanization of the translation.',
      );
  }

  @override
  String get name => 'translate';

  @override
  List<String> get aliases => ['t'];

  @override
  String get description =>
      'Translate text with a Mozhi engine or an AI provider.';

  @override
  String get invocation => 'mozhi translate [arguments] [text]';

  bool get _hasExtras =>
      flag('alternatives') ||
      flag('explain') ||
      flag('insights') ||
      flag('romanize');

  @override
  Future<int> run() async {
    final text = await readText();
    final specs = multiOption('engine');
    final compare = flag('compare');
    if (!compare && specs.length > 1) {
      throw const CliException.usage(
        'Only one --engine can be used without --compare.',
      );
    }
    if (compare && _hasExtras) {
      throw const CliException.usage(
        'AI extras (--alternatives, --explain, --insights, --romanize) '
        'cannot be used with --compare.',
      );
    }
    final options = _options();
    final sourceInput = option('from') ?? config.source ?? 'auto';
    final targetInput =
        option('to') ?? config.target ?? CliConfig.defaultTarget;
    return await withRepository(
      (repository) => compare
          ? _compare(repository, specs, text, sourceInput, targetInput, options)
          : _translate(
              repository,
              resolveEngine(
                specs.firstOrNull ?? config.engine ?? CliConfig.defaultEngine,
                providers,
              ),
              text,
              sourceInput,
              targetInput,
              options,
            ),
    );
  }

  Future<int> _translate(
    TranslationRepository repository,
    TranslationEngine engine,
    String text,
    String sourceInput,
    String targetInput,
    TranslationOptions options,
  ) async {
    if (_hasExtras && !engine.isAi) {
      throw CliException.usage(
        'AI extras (--alternatives, --explain, --insights, --romanize) '
        'require an AI provider, not ${engine.name}.',
        hint: 'Use --engine ai or --engine ai:<provider>.',
      );
    }
    final hasNonGlossaryOptions =
        options.copyWith(glossary: const {}) != const TranslationOptions();
    if (engine.isMozhi && hasNonGlossaryOptions) {
      logger.warn('AI options are ignored by Mozhi engines.');
    }
    var source = resolveLanguage(sourceInput, allowAuto: true);
    var target = resolveLanguage(targetInput, allowCustom: engine.isAi);
    if (engine.isMozhi) {
      final supported = await Future.wait([
        _supported(repository, engine, source, isSource: true),
        _supported(repository, engine, target, isSource: false),
      ]);
      source = supported.first;
      target = supported.last;
    }
    final requestOptions = engine.isAi || engine.isMt
        ? options
        : options.glossary.isEmpty
        ? const TranslationOptions()
        : TranslationOptions(glossary: options.glossary);
    final request = TranslationRequest(
      text: text,
      source: source,
      target: target,
      options: requestOptions,
    );
    final stream = repository.translate(engine, request);
    final streaming =
        engine.isAi &&
        !jsonOutput &&
        flag('stream') &&
        console.supportsAnsiEscapes;
    final result = streaming
        ? await _printStreaming(stream)
        : await stream.lastWhere((result) => result.isComplete);

    final alternatives = flag('alternatives')
        ? await repository.getAlternatives(engine, request, result.text)
        : null;
    final insights = flag('insights')
        ? await repository.getInsights(engine, request, result.text)
        : null;
    final explanation = flag('explain')
        ? await repository.explain(engine, request, result.text).join()
        : null;
    final romanization = flag('romanize')
        ? await repository.romanize(engine, text: result.text, language: target)
        : null;

    if (jsonOutput) {
      printJson(
        translationJson(
          result,
          source: source,
          target: target,
          instance: engine.isMozhi ? repository.activeInstance?.url : null,
          alternatives: alternatives,
          insights: insights,
          explanation: explanation,
          romanization: romanization,
        ),
      );
      return ExitCode.success.code;
    }
    if (!streaming) logger.info(result.text);
    _printExtras(
      alternatives: alternatives,
      insights: insights,
      explanation: explanation,
      romanization: romanization,
    );
    if (interactive) {
      if (result.targetTransliteration.isNotEmpty) {
        note(result.targetTransliteration);
      }
      note(_summary(engine, repository, source, target, result));
    }
    return ExitCode.success.code;
  }

  void _printExtras({
    AlternativeTranslations? alternatives,
    List<WordInsight>? insights,
    String? explanation,
    String? romanization,
  }) {
    if (romanization != null && romanization.trim().isNotEmpty) {
      logger
        ..info('')
        ..info(bold('Romanization:'))
        ..info('  $romanization');
    }
    if (alternatives != null) {
      logger
        ..info('')
        ..info(bold('Alternatives:'));
      if (alternatives.description.isNotEmpty) {
        logger.info('  ${darkGray.wrap(alternatives.description)}');
      }
      if (alternatives.alternatives.isEmpty) {
        logger.info('  None.');
      } else {
        for (final alt in alternatives.alternatives) {
          final reason = alt.explanation.isEmpty
              ? ''
              : ' ${darkGray.wrap('— ${alt.explanation}')}';
          logger.info('  • ${alt.text}$reason');
        }
      }
    }
    if (insights != null) {
      logger
        ..info('')
        ..info(bold('Insights:'));
      if (insights.isEmpty) {
        logger.info('  None.');
      } else {
        for (final insight in insights) {
          final header = insight.sourceText.isEmpty
              ? bold(insight.targetText)
              : '${insight.sourceText} → ${bold(insight.targetText)}';
          final detail = insight.explanation.isEmpty
              ? ''
              : '\n    ${insight.explanation}';
          logger.info(
            '  • $header ${darkGray.wrap('(${insight.type})')}$detail',
          );
          for (final variation in insight.variations) {
            final desc = variation.explanation.isEmpty
                ? ''
                : ' — ${variation.explanation}';
            logger.info('    ↳ ${variation.text}$desc');
          }
        }
      }
    }
    if (explanation != null && explanation.trim().isNotEmpty) {
      logger
        ..info('')
        ..info(bold('Explanation:'))
        ..info(explanation.trim());
    }
  }

  /// Prints snapshots as they arrive; returns the final result.
  Future<TranslationResult> _printStreaming(
    Stream<TranslationResult> stream,
  ) async {
    final printer = StreamingPrinter(
      write: logger.write,
      columns: console.terminalColumns,
      lines: console.terminalLines,
    );
    TranslationResult? last;
    try {
      await for (final result in stream) {
        if (result.isComplete) {
          printer.finish(result.text);
          last = result;
        } else {
          printer.update(result.text);
        }
      }
    } on Object {
      printer.abort();
      rethrow;
    }
    if (last == null) {
      throw const CliException.unavailable('The model returned no output.');
    }
    return last;
  }

  /// Maps [language] onto the list of the Mozhi [engine] (codes differ
  /// between engines, e.g. `he` vs `iw`).
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
                'mozhi languages --engine $id\n'
                'Free-form targets need an AI engine (--engine ai).',
    );
  }

  String _summary(
    TranslationEngine engine,
    TranslationRepository repository,
    Language source,
    Language target,
    TranslationResult result,
  ) {
    final detected = result.detectedSource == null
        ? null
        : LanguageCatalog.nameOf(result.detectedSource!);
    final from = source.isAuto
        ? (detected == null ? 'Auto' : 'Detected $detected')
        : source.name;
    final via = engine.isMozhi
        ? switch (repository.activeInstance?.url) {
            final url? => Uri.parse(url).host,
            null => null,
          }
        : engine.subtitle;
    final elapsed = result.elapsed;
    return [
      '$from → ${target.name}',
      if (via == null || via.isEmpty) engine.name else '${engine.name} ($via)',
      if (elapsed != null) formatDuration(elapsed),
    ].join(' · ');
  }

  Future<int> _compare(
    TranslationRepository repository,
    List<String> specs,
    String text,
    String sourceInput,
    String targetInput,
    TranslationOptions options,
  ) async {
    final engines = specs.isEmpty
        ? (await repository.getEngines()).where((e) => e.isMozhi).toList()
        : [for (final spec in specs) resolveEngine(spec, providers)];
    if (engines.isEmpty) {
      throw const CliException.unavailable(
        'The Mozhi instance did not report any engines.',
        hint: 'Try another instance with --instance <url>.',
      );
    }
    final request = TranslationRequest(
      text: text,
      source: resolveLanguage(sourceInput, allowAuto: true),
      target: resolveLanguage(
        targetInput,
        allowCustom: engines.any((e) => e.isAi),
      ),
      options: options,
    );
    final entries = <String, CompareEntry>{};
    await for (final entry in repository.compare(engines, request)) {
      entries[entry.id] = entry;
      if (!jsonOutput) _printEntry(entry);
    }
    if (jsonOutput) {
      printJson([
        for (final engine in engines)
          if (entries[engine.id] case final entry?) compareJson(entry),
      ]);
    }
    if (entries.values.any((entry) => entry.isSuccess)) {
      return ExitCode.success.code;
    }
    logger.err('Every engine failed.');
    return ExitCode.unavailable.code;
  }

  void _printEntry(CompareEntry entry) {
    final result = entry.result;
    if (result == null) {
      logger.info(
        '${red.wrap('✗')} ${bold(entry.name)}  '
        '${describeError(entry.error!).message}\n',
      );
      return;
    }
    final elapsed = result.elapsed;
    logger.info(
      '${bold(entry.name)}'
      '${elapsed == null ? '' : '  ${darkGray.wrap(formatDuration(elapsed))}'}'
      '\n${result.text}\n',
    );
  }

  TranslationOptions _options() {
    T? choice<T extends Enum>(String name, List<T> values) {
      final value = option(name);
      return value == null ? null : parseChoice(name, value, values);
    }

    return TranslationOptions(
      style:
          choice('style', TranslationStyle.values) ?? TranslationStyle.natural,
      formality: choice('formality', Formality.values) ?? Formality.automatic,
      formalityContext: option('formality-context') ?? '',
      readingLevel:
          choice('reading-level', ReadingLevel.values) ?? ReadingLevel.standard,
      speakerGender: choice('speaker-gender', Gender.values) ?? Gender.unknown,
      addresseeGender:
          choice('addressee-gender', Gender.values) ?? Gender.unknown,
      context: option('context') ?? '',
      glossary: {
        ...config.glossary,
        ..._glossaryFile(),
        ...parseGlossary(multiOption('glossary')),
      },
      instructions: option('instructions') ?? '',
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
