import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/quick_translate/cubit/quick_translate_state.dart';
import 'package:mozhi/quick_translate/models/quick_languages.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

export 'quick_translate_state.dart';

/// Translates one piece of text handed to the app by another app (Android
/// `PROCESS_TEXT` / share) or a desktop hotkey, independently of the main
/// translate screen.
///
/// * [start] loads the engines and the target languages of the selected
///   engine, then translates right away (auto-detected source).
/// * The engine is the one selected in settings (`engineId`), else
///   `mozhi:google`, else the first available engine. The target defaults
///   to the settings target.
/// * [setTarget] / [selectEngine] re-translate and are remembered in
///   settings (target + recent languages / engine), like the translate
///   screen does.
/// * When the detected language equals the target and the user did not
///   pick the target here, it switches once to the most recent other
///   language (or English) without persisting that switch.
/// * AI engines stream partial results; each new translation cancels the
///   previous one. Completed translations are added to [HistoryCubit] when
///   one is given and `saveHistory` is on.
class QuickTranslateCubit extends Cubit<QuickTranslateState> {
  /// [target] overrides the initial target (default: settings target).
  new({
    required this._repository,
    required SettingsCubit settings,
    required String text,
    this._history,
    Language? target,
  }) : _settings = settings,
       super(
         QuickTranslateState(
           text: text,
           target: target ?? settings.state.target,
         ),
       );

  static const _english = Language(code: 'en', name: 'English');
  static const _defaultEngineId = 'mozhi:google';

  final TranslationRepository _repository;
  final SettingsCubit _settings;
  final HistoryCubit? _history;

  int _loadRequest = 0;
  StreamSubscription<TranslationResult>? _translation;
  Completer<void>? _translationDone;
  int _translationRequest = 0;

  /// The user chose the target in this session: no automatic switching.
  bool _targetPicked = false;

  /// Loads engines + target languages, then translates. Safe to call again
  /// (e.g. to retry); [refresh] refetches the engine list.
  Future<void> start({bool refresh = false}) async {
    final request = ++_loadRequest;
    _cancelTranslation();
    final loading = state.copyWith(
      status: QuickTranslateStatus.loading,
      result: () => null,
      error: () => null,
    );
    if (loading != state) emit(loading);
    try {
      final engines = await _repository.getEngines(refresh: refresh);
      if (!_isCurrentLoad(request)) return;
      if (engines.isEmpty) {
        emit(
          state.copyWith(
            status: QuickTranslateStatus.noEngines,
            engines: const [],
            engine: () => null,
            targetLanguages: const [],
          ),
        );
        return;
      }
      final engine = _pickEngine(engines);
      final targets = await _repository.getTargetLanguages(engine);
      if (!_isCurrentLoad(request)) return;
      emit(
        state.copyWith(
          engines: engines,
          engine: () => engine,
          targetLanguages: targets,
          target: _mapTarget(state.target, engine, targets),
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentLoad(request)) return;
      emit(
        state.copyWith(
          status: QuickTranslateStatus.failure,
          error: () => error,
        ),
      );
      return;
    }
    await translate();
  }

  /// Retries whatever failed: loading the engines, or the translation.
  Future<void> retry() {
    if (state.engine == null) return start(refresh: true);
    return translate();
  }

  /// Translates the text with the current engine and target. The future
  /// completes when the translation finished, failed or was superseded.
  Future<void> translate() => _translate(smartSwap: !_targetPicked);

  /// Switches the target (persisted in settings) and re-translates.
  Future<void> setTarget(Language language) {
    if (language.isAuto) return Future.value();
    final engine = state.engine;
    if (language.isCustom &&
        (engine == null || !engine.supportsCustomLanguages)) {
      return Future.value();
    }
    _targetPicked = true;
    _settings
      ..setLanguages(target: language)
      ..addRecentLanguage(language);
    if (language == state.target &&
        state.status != QuickTranslateStatus.failure) {
      return Future.value();
    }
    emit(state.copyWith(target: language));
    return translate();
  }

  /// Switches the engine (persisted in settings), re-maps the target onto
  /// its languages and re-translates.
  Future<void> selectEngine(TranslationEngine engine) async {
    if (engine.id == state.engine?.id &&
        state.status != QuickTranslateStatus.failure) {
      return;
    }
    final request = ++_loadRequest;
    _cancelTranslation();
    _settings.setEngine(engine.id);
    emit(
      state.copyWith(
        engine: () => engine,
        status: QuickTranslateStatus.loading,
        result: () => null,
        error: () => null,
      ),
    );
    try {
      final targets = await _repository.getTargetLanguages(engine);
      if (!_isCurrentLoad(request)) return;
      emit(
        state.copyWith(
          targetLanguages: targets,
          target: _mapTarget(state.target, engine, targets),
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentLoad(request)) return;
      emit(
        state.copyWith(
          status: QuickTranslateStatus.failure,
          error: () => error,
        ),
      );
      return;
    }
    await translate();
  }

  /// Languages for the compact target picker: pinned + recent languages
  /// from settings, then [preferredCodes] (e.g. device languages) and
  /// common languages, all mapped onto the engine's targets.
  QuickLanguages pickerLanguages({List<String> preferredCodes = const []}) {
    final settings = _settings.state;
    return QuickLanguages.build(
      available: state.targetLanguages,
      recent: settings.recentLanguages,
      pinned: settings.pinnedLanguages,
      preferredCodes: preferredCodes,
      allowCustom: state.allowsCustomTarget,
    );
  }

  // ---------------------------------------------------------------------

  Future<void> _translate({required bool smartSwap}) {
    final engine = state.engine;
    if (engine == null || isClosed) return Future.value();
    _cancelTranslation();
    if (state.text.trim().isEmpty) {
      emit(
        state.copyWith(
          status: QuickTranslateStatus.success,
          result: () => null,
          error: () => null,
        ),
      );
      return Future.value();
    }
    final id = _translationRequest;
    final done = _translationDone = Completer<void>();
    final request = TranslationRequest(
      text: state.text,
      source: Language.auto,
      target: state.target,
      options: _settings.state.options,
    );
    emit(
      state.copyWith(
        status: QuickTranslateStatus.translating,
        result: () => null,
        error: () => null,
      ),
    );

    void fail(Object error) {
      _translation = null;
      emit(
        state.copyWith(
          status: QuickTranslateStatus.failure,
          result: () => null,
          error: () => error,
        ),
      );
      _complete(done);
    }

    final Stream<TranslationResult> stream;
    try {
      stream = _repository.translate(engine, request);
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    _translation = stream.listen(
      (result) {
        if (!_isCurrentTranslation(id)) return;
        _onResult(engine, request, result, smartSwap: smartSwap);
      },
      onError: (Object error) {
        if (_isCurrentTranslation(id)) fail(error);
      },
      onDone: () {
        if (!_isCurrentTranslation(id)) return;
        _translation = null;
        if (state.status == QuickTranslateStatus.translating) {
          final partial = state.result;
          emit(
            state.copyWith(
              status: QuickTranslateStatus.success,
              result: () => partial?.copyWith(isComplete: true),
            ),
          );
          final completed = state.result;
          if (completed != null) _record(engine, request, completed);
        }
        _complete(done);
      },
      cancelOnError: true,
    );
    return done.future;
  }

  void _onResult(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result, {
    required bool smartSwap,
  }) {
    if (!result.isComplete) {
      emit(state.copyWith(result: () => result));
      return;
    }
    final swapTo = smartSwap ? _smartSwapTarget(request, result) : null;
    if (swapTo != null) {
      // Hand the caller's future over to the re-translation.
      final done = _translationDone;
      _translationDone = null;
      emit(state.copyWith(target: swapTo, result: () => null));
      final next = _translate(smartSwap: false);
      if (done != null && !done.isCompleted) done.complete(next);
      return;
    }
    emit(
      state.copyWith(
        status: QuickTranslateStatus.success,
        result: () => result,
      ),
    );
    _record(engine, request, result);
  }

  /// The language to switch to when the detected source equals the
  /// target, else null.
  Language? _smartSwapTarget(
    TranslationRequest request,
    TranslationResult result,
  ) {
    final detected = result.detectedSource;
    if (request.target.isCustom || detected == null || detected.isEmpty) {
      return null;
    }
    final detectedCode = LanguageMatcher.normalize(detected);
    if (detectedCode != LanguageMatcher.normalize(request.target.code)) {
      return null;
    }
    final targets = state.targetLanguages;
    bool differs(Language language) =>
        !language.isAuto &&
        !language.isCustom &&
        LanguageMatcher.normalize(language.code) != detectedCode;
    Language? available(Language language) =>
        targets.isEmpty ? language : LanguageMatcher.match(language, targets);

    for (final recent in _settings.state.recentLanguages) {
      if (!differs(recent)) continue;
      final match = available(recent);
      if (match != null && differs(match)) return match;
    }
    final english = available(_english);
    if (english != null && differs(english)) return english;
    for (final language in targets) {
      if (differs(language)) return language;
    }
    return null;
  }

  TranslationEngine _pickEngine(List<TranslationEngine> engines) {
    TranslationEngine? byId(String? id) {
      if (id == null) return null;
      for (final engine in engines) {
        if (engine.id == id) return engine;
      }
      return null;
    }

    return byId(state.engine?.id) ??
        byId(_settings.state.engineId) ??
        byId(_defaultEngineId) ??
        engines.first;
  }

  /// Maps [wanted] onto [targets] (custom targets survive on AI engines),
  /// falling back to English / the first target.
  static Language _mapTarget(
    Language wanted,
    TranslationEngine engine,
    List<Language> targets,
  ) {
    if (targets.isEmpty) {
      return wanted.isCustom && !engine.supportsCustomLanguages
          ? _english
          : wanted;
    }
    final allowCustom = engine.supportsCustomLanguages;
    final match = wanted.isCustom && !allowCustom
        ? null
        : LanguageMatcher.match(wanted, targets, allowCustom: allowCustom);
    return match ?? LanguageMatcher.match(_english, targets) ?? targets.first;
  }

  void _record(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) {
    final history = _history;
    if (history == null ||
        !_settings.state.saveHistory ||
        result.text.trim().isEmpty) {
      return;
    }
    final now = DateTime.now();
    final entry = HistoryEntry(
      id: now.microsecondsSinceEpoch.toString(),
      text: request.text,
      translation: result.text,
      source: request.source,
      target: request.target,
      engineId: engine.id,
      engineName: engine.name,
      createdAt: now,
      detectedSource: result.detectedSource,
    );
    unawaited(history.add(entry).catchError(addError));
  }

  bool _isCurrentLoad(int request) => !isClosed && request == _loadRequest;

  bool _isCurrentTranslation(int id) => !isClosed && id == _translationRequest;

  void _cancelTranslation() {
    _translationRequest++;
    unawaited(_translation?.cancel());
    _translation = null;
    final done = _translationDone;
    _translationDone = null;
    if (done != null) _complete(done);
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  @override
  Future<void> close() {
    _loadRequest++;
    _cancelTranslation();
    return super.close();
  }
}
