import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// How a turn reads in a guest's language.
enum ShareTextStatus {
  /// The guest's language is the one it was said in: the original.
  original,

  /// Being translated (the text grows while an AI engine streams).
  translating,

  /// Translated.
  translated,

  /// Not translated (the host did not allow the destination, no engine can
  /// translate it, or the translation failed): the original is shown.
  untranslated,
}

/// A turn's text in one guest language.
typedef ShareText = ({String text, ShareTextStatus status});

/// How the turns reach the guests reading one language that is not one of
/// the conversation's two (those read the conversation's own
/// translations).
enum ShareLanguageMode {
  /// Translated by the host's engine.
  engine,

  /// Translated on the host's device (the offline engine), because the
  /// host's engine may not be sent this language pair.
  onDevice,

  /// The host has not allowed sending text for this language to the
  /// engine's destination ([ShareLanguageState.consent]); nothing was
  /// sent.
  needsConsent,

  /// No engine can translate it.
  unavailable,
}

/// What the host sees about one extra guest language.
class ShareLanguageState extends Equatable {
  const new({
    required this.language,
    required this.mode,
    this.consent,
    this.waiting = 0,
  });

  final Language language;
  final ShareLanguageMode mode;

  /// What the host would allow ([ShareLanguageMode.needsConsent]).
  final ConsentRequiredException? consent;

  /// Turns waiting for that consent.
  final int waiting;

  @override
  List<Object?> get props => [language, mode, consent, waiting];
}

/// Translates a shared conversation's turns into the guests' languages
/// that are not one of the conversation's two, once per language, with
/// the host's engines and under the host's privacy rules:
///
/// * The host's engine (`engine`) only translates a pair it may already
///   send without asking (`TranslationRepository.needsConsent`, which
///   ignores one-off approvals, so a guest never uses up or relies on an
///   approval the host gave for something else). Offline only mode
///   therefore never sends anything.
/// * Otherwise the device's offline engine translates it when there is
///   one (it may not have the pair installed).
/// * Otherwise nothing is sent: the language waits for the host's consent
///   ([ShareLanguageMode.needsConsent]; [retry] after it) and the guests
///   read the original.
///
/// Answered translations by bring-your-own-key providers are counted with
/// the `usageTracker` like the conversation's own. At most
/// [maxConcurrent] translations run at a time.
class ShareTranslations {
  new({
    required this._repository,
    required this._engine,
    required this._engines,
    this._options,
    this._usageTracker,
    this.maxConcurrent = 2,
  });

  final TranslationRepository _repository;
  final TranslationEngine? Function() _engine;
  final List<TranslationEngine> Function() _engines;
  final TranslationOptions Function()? _options;
  final UsageTracker? _usageTracker;

  /// Translations running at the same time.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxConcurrent;

  final Map<(int, String), _Job> _jobs = {};
  final List<_Job> _queue = [];
  int _running = 0;
  bool _disposed = false;
  final _changes = StreamController<void>.broadcast();

  /// Something was translated (or failed, or needs consent).
  Stream<void> get changes => _changes.stream;

  /// Whether [a] and [b] are the same language for the guests (variants
  /// of one language are not: `pt-BR` and `pt-PT` read differently).
  static bool sameLanguage(Language a, Language b) =>
      LanguageMatcher.normalize(a.code).toLowerCase() ==
      LanguageMatcher.normalize(b.code).toLowerCase();

  /// [turn] as guests reading [language] see it.
  ShareText textOf(ConversationTurn turn, Language language) {
    if (sameLanguage(language, turn.source)) {
      return (text: turn.original, status: ShareTextStatus.original);
    }
    if (sameLanguage(language, turn.target)) {
      return switch (turn.status) {
        ConversationTurnStatus.translating => (
          text: turn.translation,
          status: ShareTextStatus.translating,
        ),
        ConversationTurnStatus.complete when turn.translation.isNotEmpty => (
          text: turn.translation,
          status: ShareTextStatus.translated,
        ),
        _ => (text: turn.original, status: ShareTextStatus.untranslated),
      };
    }
    final job = _jobs[_key(turn.id, language)];
    if (job == null) {
      return (text: '', status: ShareTextStatus.translating);
    }
    return switch (job.status) {
      _JobStatus.queued || _JobStatus.running => (
        text: job.text,
        status: ShareTextStatus.translating,
      ),
      _JobStatus.done => (text: job.text, status: ShareTextStatus.translated),
      _JobStatus.consent || _JobStatus.failed => (
        text: turn.original,
        status: ShareTextStatus.untranslated,
      ),
    };
  }

  /// Starts the translations [turns] still need for [languages] (the
  /// guests' languages); forgets those of turns that are gone.
  void ensure(List<ConversationTurn> turns, Iterable<Language> languages) {
    if (_disposed) return;
    final ids = {for (final turn in turns) turn.id};
    final gone = [
      for (final key in _jobs.keys)
        if (!ids.contains(key.$1)) key,
    ];
    for (final key in gone) {
      unawaited(_jobs.remove(key)?.cancel());
    }
    _queue.removeWhere((job) => job.cancelled);
    for (final turn in turns) {
      for (final language in languages) {
        if (sameLanguage(language, turn.source) ||
            sameLanguage(language, turn.target)) {
          continue;
        }
        final key = _key(turn.id, language);
        if (_jobs.containsKey(key)) continue;
        final job = _jobs[key] = _Job(turn, language);
        _queue.add(job);
      }
    }
    _pump();
  }

  /// The state of each extra language of [languages] for the host, in
  /// that order (languages without translations yet are left out).
  List<ShareLanguageState> languageStates(Iterable<Language> languages) => [
    for (final language in languages) ?_stateOf(language),
  ];

  ShareLanguageState? _stateOf(Language language) {
    final jobs = [
      for (final job in _jobs.values)
        if (sameLanguage(job.language, language)) job,
    ];
    if (jobs.isEmpty) return null;
    final waiting = [
      for (final job in jobs)
        if (job.status == _JobStatus.consent) job,
    ];
    if (waiting.isNotEmpty) {
      return ShareLanguageState(
        language: language,
        mode: ShareLanguageMode.needsConsent,
        consent: waiting.last.consent,
        waiting: waiting.length,
      );
    }
    final finished = [
      for (final job in jobs)
        if (job.status == _JobStatus.done || job.status == _JobStatus.failed)
          job,
    ];
    if (finished.isEmpty) {
      return ShareLanguageState(
        language: language,
        mode: ShareLanguageMode.engine,
      );
    }
    final last = finished.last;
    return ShareLanguageState(
      language: language,
      mode: last.status == _JobStatus.failed
          ? ShareLanguageMode.unavailable
          : last.onDevice
          ? ShareLanguageMode.onDevice
          : ShareLanguageMode.engine,
    );
  }

  /// Translates again the turns of [language] that waited for the host's
  /// consent, which the host just gave (the repository lets through what
  /// the consent covers; turns it does not cover wait again).
  void retry(Language language) {
    if (_disposed) return;
    for (final job in _jobs.values) {
      if (job.status == _JobStatus.consent &&
          sameLanguage(job.language, language)) {
        job
          ..status = _JobStatus.queued
          ..forced = true
          ..consent = null;
        _queue.add(job);
      }
    }
    _notify();
    _pump();
  }

  /// Stops every translation.
  Future<void> dispose() async {
    _disposed = true;
    _queue.clear();
    final jobs = _jobs.values.toList();
    _jobs.clear();
    await Future.wait([for (final job in jobs) job.cancel()]);
    await _changes.close();
  }

  static (int, String) _key(int turnId, Language language) =>
      (turnId, LanguageMatcher.normalize(language.code).toLowerCase());

  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  void _pump() {
    while (!_disposed && _running < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (job.cancelled || job.status != _JobStatus.queued) continue;
      _start(job);
    }
  }

  void _start(_Job job) {
    final source = job.turn.source;
    final target = job.language;
    final engine = _engine();
    final offline = _offlineEngine();
    final forced = job.forced;
    job.forced = false;
    if (engine != null &&
        (forced ||
            !_repository.needsConsent(
              engine,
              source: source,
              target: target,
            ))) {
      _run(job, engine, fallback: engine.id == offline?.id ? null : offline);
    } else if (offline != null) {
      _run(job, offline, denied: engine);
    } else if (engine != null) {
      _waitForConsent(job, _consentFor(engine, source, target));
    } else {
      job.status = _JobStatus.failed;
      _notify();
    }
  }

  TranslationEngine? _offlineEngine() {
    for (final engine in _engines()) {
      if (engine.kind == EngineKind.offline) return engine;
    }
    return null;
  }

  /// Translates [job] with [engine]; when that fails, with [fallback] (the
  /// offline engine). [denied] is the host's engine that needs consent
  /// (the job then waits for it when the offline engine cannot help).
  void _run(
    _Job job,
    TranslationEngine engine, {
    TranslationEngine? fallback,
    TranslationEngine? denied,
  }) {
    _running++;
    job
      ..status = _JobStatus.running
      ..text = ''
      ..onDevice = engine.kind == EngineKind.offline;
    final request = TranslationRequest(
      text: job.turn.original,
      source: job.turn.source,
      target: job.language,
      options: (_options?.call() ?? const TranslationOptions()).copyWith(
        instructions: '',
        context: '',
      ),
    );
    TranslationResult? last;
    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      _running--;
      _pump();
    }

    job.onStop = finish;

    job.subscription = _repository
        .translate(engine, request)
        .listen(
          (result) {
            last = result;
            job.text = result.text;
            _notify();
          },
          onError: (Object error) {
            finish();
            if (job.cancelled) return;
            if (error is ConsentRequiredException) {
              // Nothing was sent (a once approval was used up meanwhile).
              _waitForConsent(job, error);
            } else if (fallback != null) {
              _run(job, fallback);
            } else if (denied != null) {
              _waitForConsent(
                job,
                _consentFor(denied, job.turn.source, job.language),
              );
            } else {
              job.status = _JobStatus.failed;
              _notify();
            }
          },
          onDone: () {
            finish();
            if (job.cancelled) return;
            final answer = last;
            if (answer == null || answer.text.trim().isEmpty) {
              job.status = _JobStatus.failed;
            } else {
              job.status = _JobStatus.done;
              _recordUsage(engine, request, answer);
            }
            _notify();
          },
          cancelOnError: true,
        );
  }

  void _waitForConsent(_Job job, ConsentRequiredException consent) {
    job
      ..status = _JobStatus.consent
      ..consent = consent
      ..text = '';
    _notify();
  }

  /// The consent [engine] needs for [source] > [target], as the repository
  /// would report it (nothing is asked or sent).
  ConsentRequiredException _consentFor(
    TranslationEngine engine,
    Language source,
    Language target,
  ) {
    DataDestination destination;
    try {
      destination = _repository.destinationOf(engine.id);
      // The repository's documented answer for an engine whose provider is
      // no longer configured.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      destination = const PublicInstanceDestination('');
    }
    final provider = TranslationRepository.providerIdOf(engine.id);
    final kind = _repository.privacyMode == PrivacyMode.offlineOnly
        ? ConsentKind.offlineOnly
        : destination is CloudProviderDestination &&
              !_repository.consentedProviders.contains(provider)
        ? ConsentKind.cloudProvider
        : ConsentKind.pair;
    return ConsentRequiredException(
      kind: kind,
      destination: destination,
      engineId: engine.id,
      source: source.code,
      target: target.code,
    );
  }

  /// Counts an answered translation by a bring-your-own-key provider (as
  /// the conversation does). Never throws.
  void _recordUsage(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    if (!result.isComplete || result.fromCache) return;
    try {
      unawaited(
        tracker
            .recordText(providerId, input: request.text, output: result.text)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break the sharing.
    }
  }
}

enum _JobStatus { queued, running, done, consent, failed }

/// The translation of one turn into one guest language.
class _Job {
  new(this.turn, this.language);

  final ConversationTurn turn;
  final Language language;
  _JobStatus status = _JobStatus.queued;
  String text = '';
  bool onDevice = false;

  /// Run once without the consent check (the host just consented).
  bool forced = false;
  ConsentRequiredException? consent;
  bool cancelled = false;
  StreamSubscription<TranslationResult>? subscription;

  /// Frees the translation's place in the queue (once).
  void Function()? onStop;

  Future<void> cancel() async {
    cancelled = true;
    final stop = onStop;
    onStop = null;
    stop?.call();
    await subscription?.cancel();
  }
}
