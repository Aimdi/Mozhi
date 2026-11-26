import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/commands/dictionary_command.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi repl`: interactive translation session with slash commands.
class ReplCommand extends MozhiCommand {
  new(super.context, {this._inputLines, this._outputSink}) {
    argParser
      ..addOption(
        'from',
        abbr: 'f',
        valueHelp: 'language',
        help: 'Initial source language. Default: configured source, else auto.',
      )
      ..addOption(
        'to',
        abbr: 't',
        valueHelp: 'language',
        help: 'Initial target language. Default: configured target, else en.',
      );
    addEngineOption();
    addInstanceOption();
    argParser
      ..addOption(
        'formality',
        valueHelp: 'level',
        allowed: [for (final value in Formality.values) kebabCase(value.name)],
        help: 'Initial formality level (AI / DeepL).',
      )
      ..addOption(
        'style',
        allowed: [
          for (final value in TranslationStyle.values) kebabCase(value.name),
        ],
        help: 'Initial translation style (natural or literal; AI only).',
      )
      ..addOption(
        'context',
        valueHelp: 'text',
        help: 'Initial translation context (AI only).',
      );
  }

  final Stream<String>? _inputLines;
  final StringSink? _outputSink;

  @override
  String get name => 'repl';

  @override
  List<String> get aliases => ['chat', 'interactive'];

  @override
  String get description =>
      'Start an interactive translation session with slash commands.';

  @override
  Future<int> run() async {
    final engine = selectedEngine();
    final source = resolveLanguage(
      option('from') ?? config.source ?? 'auto',
      allowAuto: true,
    );
    final target = resolveLanguage(
      option('to') ?? config.target ?? CliConfig.defaultTarget,
      allowCustom: engine.isAi,
    );
    final formalityOpt = option('formality');
    final formality = formalityOpt == null
        ? Formality.automatic
        : parseChoice('formality', formalityOpt, Formality.values);
    final styleOpt = option('style');
    final style = styleOpt == null
        ? TranslationStyle.natural
        : parseChoice('style', styleOpt, TranslationStyle.values);
    final contextText = option('context') ?? '';

    final sink = _outputSink ?? _LoggerSink(logger);
    final lines = _inputLines ?? console.readLines();
    final showPrompt =
        _outputSink == null &&
        console.stdinHasTerminal &&
        console.stdoutHasTerminal;

    return await withRepository((repository) async {
      final session = ReplSession(
        repository: repository,
        config: config,
        providers: providers,
        engine: engine,
        source: source,
        target: target,
        formality: formality,
        style: style,
        context: contextText,
        output: sink,
        bold: bold,
        showPrompt: showPrompt,
      );
      await session.run(lines);
      return ExitCode.success.code;
    });
  }
}

/// Interactive REPL state machine, directly testable with injected streams.
class ReplSession {
  new({
    required this.repository,
    required this.config,
    required this.providers,
    required this.engine,
    required this.source,
    required this.target,
    required this.output,
    this.formality = Formality.automatic,
    this.style = TranslationStyle.natural,
    this.context = '',
    String Function(String)? bold,
    this.showPrompt = false,
  }) : _bold = bold ?? _identity,
       glossary = Map<String, String>.of(config.glossary);

  final TranslationRepository repository;
  final CliConfig config;
  final List<AiProviderConfig> providers;
  final StringSink output;
  final String Function(String) _bold;
  final bool showPrompt;

  TranslationEngine engine;
  Language source;
  Language target;
  Formality formality;
  TranslationStyle style;
  String context;
  final Map<String, String> glossary;
  String? lastDetectedSource;
  TranslationRequest? lastRequest;
  String? lastTranslation;

  static String _identity(String s) => s;

  Future<void> run(Stream<String> inputLines) async {
    output.writeln(
      'Mozhi interactive session (${engine.name}: '
      '${source.code} → ${target.code}). Type /help for commands, /quit to exit.',
    );
    _writePrompt();
    await for (final rawLine in inputLines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        _writePrompt();
        continue;
      }
      if (line.startsWith('/')) {
        final keepGoing = await handleSlashCommand(line);
        if (!keepGoing) break;
      } else {
        await _translateLine(line);
      }
      _writePrompt();
    }
  }

  void _writePrompt() {
    if (showPrompt) {
      output.write('[${source.code}→${target.code}] > ');
    }
  }

  /// Processes one slash command; returns `false` to exit the session.
  Future<bool> handleSlashCommand(String line) async {
    final space = line.indexOf(RegExp(r'\s'));
    final cmd = (space < 0 ? line : line.substring(0, space)).toLowerCase();
    final arg = space < 0 ? '' : line.substring(space + 1).trim();

    try {
      switch (cmd) {
        case '/quit' || '/exit' || '/q':
          output.writeln('Bye.');
          return false;

        case '/help' || '/?':
          output.writeln(_helpText);
          return true;

        case '/status':
          output.writeln(
            'Engine: ${engine.id} (${engine.name})\n'
            'Languages: ${source.code} (${source.name}) → '
            '${target.code} (${target.name})\n'
            'Formality: ${kebabCase(formality.name)}\n'
            'Style: ${kebabCase(style.name)}\n'
            'Context: ${context.isEmpty ? '(none)' : context}\n'
            'Glossary: ${glossary.length} '
            '${glossary.length == 1 ? 'term' : 'terms'}',
          );
          return true;

        case '/from':
          if (arg.isEmpty) {
            output.writeln('Usage: /from <language-code-or-name>');
            return true;
          }
          source = resolveLanguage(arg, allowAuto: true);
          output.writeln(
            'Source language set to ${source.code} (${source.name}).',
          );
          return true;

        case '/to':
          if (arg.isEmpty) {
            output.writeln('Usage: /to <language-code-or-name>');
            return true;
          }
          target = resolveLanguage(arg, allowCustom: engine.isAi);
          output.writeln(
            'Target language set to ${target.code} (${target.name}).',
          );
          return true;

        case '/swap':
          if (source.isAuto) {
            if (lastDetectedSource case final detected?) {
              final nextTarget = resolveLanguage(detected);
              source = target;
              target = nextTarget;
              output.writeln(
                'Swapped languages: ${source.code} → ${target.code}.',
              );
            } else {
              output.writeln(
                'Cannot swap while source is "auto" (translate something first '
                'or set /from <code>).',
              );
            }
            return true;
          }
          final previousSource = source;
          source = target;
          target = previousSource;
          output.writeln('Swapped languages: ${source.code} → ${target.code}.');
          return true;

        case '/engine':
          if (arg.isEmpty) {
            output.writeln('Usage: /engine <id>');
            return true;
          }
          engine = resolveEngine(arg, providers);
          output.writeln('Engine set to ${engine.id} (${engine.name}).');
          return true;

        case '/formality':
          if (arg.isEmpty) {
            output.writeln(
              'Usage: /formality '
              '<${Formality.values.map((v) => kebabCase(v.name)).join('|')}>',
            );
            return true;
          }
          formality = parseChoice('formality', arg, Formality.values);
          output.writeln('Formality set to ${kebabCase(formality.name)}.');
          return true;

        case '/style':
          if (arg.isEmpty) {
            final allowed = TranslationStyle.values
                .map((v) => kebabCase(v.name))
                .join('|');
            output.writeln('Usage: /style <$allowed>');
            return true;
          }
          style = parseChoice('style', arg, TranslationStyle.values);
          output.writeln('Style set to ${kebabCase(style.name)}.');
          return true;

        case '/context':
          if (arg.isEmpty) {
            output.writeln(
              context.isEmpty
                  ? 'Context is empty. Usage: /context <text|clear>'
                  : 'Context: $context',
            );
            return true;
          }
          if (arg.toLowerCase() == 'clear') {
            context = '';
            output.writeln('Context cleared.');
            return true;
          }
          context = arg;
          output.writeln('Context set to "$context".');
          return true;

        case '/glossary':
          _handleGlossary(arg);
          return true;

        case '/proofread' || '/proof':
          if (arg.isEmpty) {
            output.writeln('Usage: /proofread <text>');
            return true;
          }
          final ai = _aiEngineFor('Proofreading');
          final result = await repository.proofread(
            ai,
            arg,
            formality: formality,
          );
          output.writeln(result.correctedText);
          if (result.edits.isEmpty) {
            output.writeln('No changes needed.');
          } else {
            for (final edit in result.edits) {
              output.writeln(
                '  • ${edit.original} → ${edit.replacement} '
                '(${edit.category.replaceAll('_', ' ')})',
              );
            }
          }
          return true;

        case '/dict' || '/dictionary':
          if (arg.isEmpty) {
            output.writeln('Usage: /dict <word>');
            return true;
          }
          final ai = _aiEngineFor('Dictionary lookup');
          final entry = await repository.lookUp(
            ai,
            arg,
            source: source,
            target: target,
          );
          formatDictionaryEntry(entry, bold: _bold).forEach(output.writeln);
          return true;

        case '/alt' || '/alternatives':
          await _runOnLast('Alternatives', (ai, req, tr) async {
            final alts = await repository.getAlternatives(ai, req, tr);
            if (alts.description.isNotEmpty) {
              output.writeln(alts.description);
            }
            if (alts.alternatives.isEmpty) {
              output.writeln('No alternatives suggested.');
            } else {
              for (final alt in alts.alternatives) {
                final reason = alt.explanation.isEmpty
                    ? ''
                    : ' — ${alt.explanation}';
                output.writeln('  • ${alt.text}$reason');
              }
            }
          });
          return true;

        case '/explain':
          await _runOnLast('Explanation', (ai, req, tr) async {
            final explanation = await repository.explain(ai, req, tr).join();
            output.writeln(explanation.trim());
          });
          return true;

        case '/insights':
          await _runOnLast('Word insights', (ai, req, tr) async {
            final insights = await repository.getInsights(ai, req, tr);
            if (insights.isEmpty) {
              output.writeln('No notable insights.');
              return;
            }
            for (final insight in insights) {
              final header = insight.sourceText.isEmpty
                  ? _bold(insight.targetText)
                  : '${insight.sourceText} → ${_bold(insight.targetText)}';
              output.writeln('  • $header (${insight.type})');
              if (insight.explanation.isNotEmpty) {
                output.writeln('    ${insight.explanation}');
              }
            }
          });
          return true;

        case '/romanize':
          await _runOnLast('Romanization', (ai, req, tr) async {
            final rom = await repository.romanize(
              ai,
              text: tr,
              language: req.target,
            );
            output.writeln(rom.trim());
          });
          return true;

        case '/check' || '/meaning':
          await _runOnLast('Meaning check', (ai, req, tr) async {
            final effectiveSource =
                lastDetectedSource != null && req.source.isAuto
                ? resolveLanguage(lastDetectedSource!)
                : req.source;
            final check = await repository.checkMeaning(
              ai,
              source: req.text,
              translation: tr,
              sourceLanguage: effectiveSource,
              targetLanguage: req.target,
            );
            final verdict = switch (check.verdict) {
              MeaningVerdict.same => 'Same meaning',
              MeaningVerdict.minor => 'Minor differences',
              MeaningVerdict.major => 'Meaning differs',
            };
            output.writeln('${_bold('Meaning check:')} $verdict');
            if (check.backTranslation.isNotEmpty) {
              output.writeln('  Back-translation: ${check.backTranslation}');
            }
            for (final issue in check.issues) {
              final type = issue.type.name.replaceAll('_', ' ');
              final suggestion = issue.suggestion.isEmpty
                  ? ''
                  : ' (suggestion: ${issue.suggestion})';
              output.writeln('  • [$type] ${issue.problem}$suggestion');
            }
          });
          return true;

        case '/compare' || '/cmp':
          await _handleCompare(arg);
          return true;

        default:
          output.writeln('Unknown command "$cmd". Type /help for commands.');
          return true;
      }
    } on Object catch (error) {
      output.writeln('Error: ${describeError(error).message}');
      return true;
    }
  }

  void _handleGlossary(String arg) {
    if (arg.isEmpty || arg.toLowerCase() == 'list') {
      if (glossary.isEmpty) {
        output.writeln('Glossary is empty.');
        return;
      }
      final keys = glossary.keys.toList()..sort();
      for (final key in keys) {
        output.writeln('  $key → ${glossary[key]}');
      }
      return;
    }
    final space = arg.indexOf(RegExp(r'\s'));
    final sub = (space < 0 ? arg : arg.substring(0, space)).toLowerCase();
    final rest = space < 0 ? '' : arg.substring(space + 1).trim();
    switch (sub) {
      case 'add' || 'set':
        if (rest.isEmpty) {
          output.writeln('Usage: /glossary add <term=translation>');
          return;
        }
        final parsed = parseGlossary([rest]);
        glossary.addAll(parsed);
        for (final MapEntry(:key, :value) in parsed.entries) {
          output.writeln('Glossary term set: $key → $value');
        }
      case 'remove' || 'rm' || 'delete':
        if (rest.isEmpty) {
          output.writeln('Usage: /glossary remove <term>');
          return;
        }
        if (glossary.remove(rest) != null) {
          output.writeln('Removed glossary term "$rest".');
        } else {
          output.writeln('Glossary term "$rest" not found.');
        }
      case 'clear':
        glossary.clear();
        output.writeln('Glossary cleared.');
      default:
        output.writeln(
          'Usage: /glossary <list|add term=translation|remove term|clear>',
        );
    }
  }

  Future<void> _handleCompare(String arg) async {
    final specs = <String>[];
    var text = arg;
    if (arg.isNotEmpty) {
      final space = arg.indexOf(RegExp(r'\s'));
      final first = space < 0 ? arg : arg.substring(0, space);
      if (first.contains(',')) {
        specs.addAll(
          first.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
        );
        text = space < 0 ? '' : arg.substring(space + 1).trim();
      }
    }
    if (text.isEmpty) {
      final previous = lastRequest?.text;
      if (previous == null) {
        output.writeln(
          'Translate something first or pass text: '
          '/compare [engine1,engine2] <text>',
        );
        return;
      }
      text = previous;
    }

    final engines = specs.isEmpty
        ? (await repository.getEngines()).where((e) => e.isMozhi).toList()
        : [for (final spec in specs) resolveEngine(spec, providers)];
    if (engines.isEmpty) {
      output.writeln('No engines available to compare.');
      return;
    }

    final options = engines.any((e) => e.isAi || e.isMt)
        ? TranslationOptions(
            style: style,
            formality: formality,
            context: context,
            glossary: Map<String, String>.unmodifiable(glossary),
          )
        : glossary.isEmpty
        ? const TranslationOptions()
        : TranslationOptions(
            glossary: Map<String, String>.unmodifiable(glossary),
          );
    final request = TranslationRequest(
      text: text,
      source: source,
      target: target,
      options: options,
    );

    TranslationResult? firstSuccess;
    await for (final entry in repository.compare(engines, request)) {
      final result = entry.result;
      if (result == null) {
        output.writeln(
          '  ✗ ${_bold(entry.name)}: ${describeError(entry.error!).message}',
        );
      } else {
        firstSuccess ??= result;
        output.writeln('  ${_bold(entry.name)}: ${result.text}');
      }
    }
    if (firstSuccess != null) {
      if (firstSuccess.detectedSource case final detected?) {
        lastDetectedSource = detected;
      }
      lastRequest = request;
      lastTranslation = firstSuccess.text;
    }
  }

  Future<void> _runOnLast(
    String feature,
    Future<void> Function(
      TranslationEngine ai,
      TranslationRequest req,
      String translation,
    )
    action,
  ) async {
    final req = lastRequest;
    final tr = lastTranslation;
    if (req == null || tr == null) {
      output.writeln('Translate something first before running $feature.');
      return;
    }
    final ai = _aiEngineFor(feature);
    await action(ai, req, tr);
  }

  TranslationEngine _aiEngineFor(String feature) => engine.isAi
      ? engine
      : resolveAiEngine(null, config, providers, feature: feature);

  Future<void> _translateLine(String text) async {
    try {
      final options = engine.isAi || engine.isMt
          ? TranslationOptions(
              style: style,
              formality: formality,
              context: context,
              glossary: Map<String, String>.unmodifiable(glossary),
            )
          : glossary.isEmpty
          ? const TranslationOptions()
          : TranslationOptions(
              glossary: Map<String, String>.unmodifiable(glossary),
            );
      final request = TranslationRequest(
        text: text,
        source: source,
        target: target,
        options: options,
      );
      final result = await repository
          .translate(engine, request)
          .lastWhere((r) => r.isComplete);
      if (result.detectedSource case final detected?) {
        lastDetectedSource = detected;
      }
      lastRequest = request;
      lastTranslation = result.text;
      output.writeln(result.text);
    } on Object catch (error) {
      output.writeln('Error: ${describeError(error).message}');
    }
  }

  static const _helpText = '''
Commands:
  /from <code>         Set source language (or "auto")
  /to <code>           Set target language
  /swap                Swap source and target languages
  /engine <id>         Switch engine (google, deepl, ai, ai:<id>, mt:<id>)
  /formality <level>   Set formality (automatic, more, less, prefer-more, prefer-less)
  /style <style>       Set translation style (natural, literal)
  /context <text|clear> Set or clear translation context (AI)
  /glossary <cmd>      Manage session glossary (list, add k=v, remove k, clear)
  /alt                 Show alternative translations for the last result (AI)
  /explain             Explain the last translation (AI)
  /insights            Show word insights for the last translation (AI)
  /romanize            Romanize the last translation (AI)
  /check               Back-translate and check meaning of the last result (AI)
  /compare [e1,e2] [text] Compare translations across engines
  /proofread <text>    Proofread text using an AI provider
  /dict <word>         Look up a word using an AI provider
  /status              Show current session settings
  /help                Show this help message
  /quit                Exit the session''';
}

class _LoggerSink implements StringSink {
  const new(this._logger);

  final Logger _logger;

  @override
  void write(Object? object) => _logger.write('$object');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _logger.write(objects.join(separator));

  @override
  void writeCharCode(int charCode) =>
      _logger.write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => _logger.info('$object');
}
