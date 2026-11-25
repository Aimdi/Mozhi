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
    argParser.addOption(
      'formality',
      valueHelp: 'level',
      allowed: [for (final value in Formality.values) kebabCase(value.name)],
      help: 'Initial formality level (AI / DeepL).',
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
    String Function(String)? bold,
    this.showPrompt = false,
  }) : _bold = bold ?? _identity;

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
  String? lastDetectedSource;

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
            'Glossary: ${config.glossary.length} saved '
            '${config.glossary.length == 1 ? 'term' : 'terms'}',
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

        default:
          output.writeln('Unknown command "$cmd". Type /help for commands.');
          return true;
      }
    } on Object catch (error) {
      output.writeln('Error: ${describeError(error).message}');
      return true;
    }
  }

  TranslationEngine _aiEngineFor(String feature) => engine.isAi
      ? engine
      : resolveAiEngine(null, config, providers, feature: feature);

  Future<void> _translateLine(String text) async {
    try {
      final options = engine.isAi || engine.isMt
          ? TranslationOptions(formality: formality, glossary: config.glossary)
          : config.glossary.isEmpty
          ? const TranslationOptions()
          : TranslationOptions(glossary: config.glossary);
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
