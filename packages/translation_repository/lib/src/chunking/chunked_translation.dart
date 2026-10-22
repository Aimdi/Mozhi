import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:llm_api/llm_api.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';

/// What one part of a long text is translated with besides its own text
/// (see [chunkedTranslation]). Everything in it is untrusted data, like the
/// text itself (see `TranslationPrompts.translate`).
@immutable
class ChunkContext {
  const new({
    this.index = 0,
    this.count = 1,
    this.precedingText = '',
    this.precedingTranslation = '',
    this.terms = const {},
  });

  /// The position of the part (0 for the first) among [count] parts.
  final int index;

  /// How many parts the text has.
  final int count;

  /// The end of the previous part's source text (see [precedingTextTail]);
  /// empty for the first part.
  final String precedingText;

  /// The end of the translation of the latest finished part before this
  /// one (see [precedingTextTail]); empty when none had finished when this
  /// part started.
  final String precedingTranslation;

  /// The running term map when this part started: source term ->
  /// rendering, for glossary terms that occurred in finished parts and
  /// capitalised names the finished translations rendered recognisably
  /// (see [ChunkTermMap]). Meant as soft glossary entries.
  final Map<String, String> terms;

  @override
  bool operator ==(Object other) =>
      other is ChunkContext &&
      other.index == index &&
      other.count == count &&
      other.precedingText == precedingText &&
      other.precedingTranslation == precedingTranslation &&
      const MapEquality<String, String>().equals(other.terms, terms);

  @override
  int get hashCode => Object.hash(
    index,
    count,
    precedingText,
    precedingTranslation,
    const MapEquality<String, String>().hash(terms),
  );

  @override
  String toString() =>
      'ChunkContext(${index + 1}/$count, preceding: ${precedingText.length} '
      'chars, translation: ${precedingTranslation.length} chars, '
      '${terms.length} terms)';
}

/// Identifies the translation of one part of a long text in a
/// [ChunkCache]: the engine, the part's request (its text, languages and
/// options; the source is the one the first part pinned when the text's
/// source is auto) and a hash of the part's preceding source text, so a
/// part is only reused where it follows the same text.
///
/// The preceding translation and the running term map are not part of the
/// key: they depend on which parts happened to finish first, so including
/// them would make unchanged parts miss.
@immutable
class ChunkCacheKey {
  const new({
    required this.engineId,
    required this.request,
    required this.precedingHash,
  });

  /// The [ChunkContext.precedingText] of a part as [precedingHash].
  static int hashPreceding(String precedingText) => precedingText.hashCode;

  final String engineId;
  final TranslationRequest request;
  final int precedingHash;

  @override
  bool operator ==(Object other) =>
      other is ChunkCacheKey &&
      other.engineId == engineId &&
      other.request == request &&
      other.precedingHash == precedingHash;

  @override
  int get hashCode => Object.hash(engineId, request, precedingHash);
}

/// Keeps the translations of finished parts of long texts, so that
/// changing one paragraph of a long text does not send (and bill) every
/// other part again. See [chunkedTranslation]'s `cache`.
abstract interface class ChunkCache {
  /// The stored translation of the part [key] identifies, or null.
  TranslationResult? lookup(ChunkCacheKey key);

  /// Remembers [result], the complete translation of the part [key]
  /// identifies.
  void store(ChunkCacheKey key, TranslationResult result);
}

/// A [ChunkCache] in memory (nothing is written to disk): at most
/// [maxEntries] parts (0 disables it), least recently used first out, each
/// for at most [ttl]. Only complete, non-blank results are stored.
class MemoryChunkCache implements ChunkCache {
  /// [clock] defaults to [DateTime.now].
  new({
    this.maxEntries = defaultMaxEntries,
    this.ttl = defaultTtl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    RangeError.checkNotNegative(maxEntries, 'maxEntries');
  }

  /// Default value of [maxEntries].
  static const defaultMaxEntries = 500;

  /// Default value of [ttl] (that of `TranslationCache`).
  static const defaultTtl = Duration(hours: 24);

  final int maxEntries;
  final Duration ttl;
  final DateTime Function() _clock;

  /// Insertion order doubles as recency order.
  final LinkedHashMap<ChunkCacheKey, (TranslationResult, DateTime)> _entries =
      LinkedHashMap();

  /// Number of stored parts, including expired ones not yet looked up.
  int get length => _entries.length;

  @override
  TranslationResult? lookup(ChunkCacheKey key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_clock().difference(entry.$2) > ttl) return null;
    _entries[key] = entry;
    return entry.$1;
  }

  @override
  void store(ChunkCacheKey key, TranslationResult result) {
    if (maxEntries == 0 || !result.isComplete || result.text.trim().isEmpty) {
      return;
    }
    _entries
      ..remove(key)
      ..[key] = (result, _clock());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Forgets every part.
  void clear() => _entries.clear();
}

/// The running term map of a long text translated in parts: as parts
/// finish ([addPart]), the glossary terms that occurred in them (with the
/// glossary's renderings) and capitalised names their translations
/// rendered recognisably (see [nameRenderings]), at most [maxTerms],
/// glossary terms first and otherwise in the order they were found. A term
/// keeps its first rendering.
class ChunkTermMap {
  /// `glossary` is the text's `TranslationOptions.glossary`.
  new({
    this.maxTerms = TranslationPrompts.maxEarlierTerms,
    this._glossary = const {},
  });

  /// Most terms kept.
  final int maxTerms;

  final Map<String, String> _glossary;
  final Map<String, String> _glossaryTerms = {};
  final Map<String, String> _names = {};
  final Set<String> _seen = {};

  /// Adds the terms of a finished part: its [source] text and its
  /// [translation].
  void addPart(String source, String translation) {
    if (maxTerms < 1) return;
    TranslationPrompts.glossaryMatches(_glossary, source).forEach((term, to) {
      if (_seen.add(term.toLowerCase())) _glossaryTerms[term] = to;
    });
    if (_names.length >= maxTerms) return;
    final names = nameRenderings(source, translation, max: maxTerms);
    for (final MapEntry(key: name, value: rendering) in names.entries) {
      if (_names.length >= maxTerms) break;
      if (_seen.add(name.toLowerCase())) _names[name] = rendering;
    }
  }

  /// The terms so far (source term -> rendering), at most [maxTerms].
  Map<String, String> get terms => Map.unmodifiable(
    Map.fromEntries(
      _glossaryTerms.entries.followedBy(_names.entries).take(maxTerms),
    ),
  );
}

/// Capitalised names in [source] with the form [translation] gives them,
/// at most [max], in the order they occur. Meant for the running term map
/// of a long text ([ChunkTermMap]), so "within reason":
///
/// * Candidates are words that start with a capital letter (at least two
///   letters) and do not start a sentence or line, unless the same word
///   occurs capitalised elsewhere, and whose lower-case form does not occur
///   in [source] (so "The", "Will"); and runs of up to four such words
///   separated by single spaces ("New York"), which may start a sentence.
/// * A candidate is kept when [translation] has it as is, or a capitalised
///   word (run) that is the same up to case and accents (`Zurich`:
///   `Zürich`), or, for single words of 5+ letters, a capitalised word
///   that begins with all but its last one or two letters and is at most
///   four letters longer (`Kowalski`: `Kowalskiego`); the rendering is that
///   form of [translation]. A run that is not found is tried word by word.
///
/// Scripts without capitals (Chinese, Japanese, Arabic, ...) have no
/// names to find, and neither do translations into another script.
Map<String, String> nameRenderings(
  String source,
  String translation, {
  int max = TranslationPrompts.maxEarlierTerms,
}) {
  final found = <String, String>{};
  if (max < 1) return found;
  final words = _words(source);
  if (words.isEmpty) return found;
  final target = _Rendering(translation);
  if (target.isEmpty) return found;
  final lowerCase = {
    for (final word in words)
      if (!_isCapitalised(word.text)) word.text.toLowerCase(),
  };
  final starts = [
    for (var i = 0; i < words.length; i++)
      i == 0 ||
          _startsSentence(source.substring(words[i - 1].end, words[i].start)),
  ];
  final midSentence = {
    for (var i = 0; i < words.length; i++)
      if (!starts[i] && _isCapitalised(words[i].text)) words[i].text,
  };

  bool isName(int i) {
    final text = words[i].text;
    return _isCapitalised(text) &&
        (!starts[i] || midSentence.contains(text)) &&
        !lowerCase.contains(text.toLowerCase());
  }

  void add(String name, String rendering) {
    if (found.length < max) found.putIfAbsent(name, () => rendering);
  }

  var i = 0;
  while (i < words.length && found.length < max) {
    if (!_isCapitalised(words[i].text)) {
      i++;
      continue;
    }
    // The longest run of capitalised words joined by single spaces.
    var end = i + 1;
    while (end < words.length &&
        end - i < 4 &&
        _isCapitalised(words[end].text) &&
        _isRunGap(source.substring(words[end - 1].end, words[end].start))) {
      end++;
    }
    final run = [for (var k = i; k < end; k++) words[k].text];
    if (run.length > 1) {
      if (target.find(run) case final rendering?) {
        add(run.join(' '), rendering);
        i = end;
        continue;
      }
    }
    for (var k = i; k < end; k++) {
      if (!isName(k)) continue;
      final word = words[k].text;
      if (target.find([word]) case final rendering?) {
        add(word, rendering);
      }
    }
    i = end;
  }
  return found;
}

typedef _Word = ({String text, int start, int end});

final _wordPattern = RegExp(
  r'[\p{L}\p{M}\p{N}]+(?:-[\p{L}\p{M}\p{N}]+)*',
  unicode: true,
);
final _capitalised = RegExp(r'^[\p{Lu}\p{Lt}]', unicode: true);
final _letter = RegExp(r'\p{L}', unicode: true);
final _sentenceEnd = RegExp('[.!?…:\n\r。！？]');

List<_Word> _words(String text) => [
  for (final match in _wordPattern.allMatches(text))
    (text: match[0]!, start: match.start, end: match.end),
];

bool _isCapitalised(String word) =>
    _capitalised.hasMatch(word) && _letter.allMatches(word).take(2).length == 2;

bool _startsSentence(String gap) => _sentenceEnd.hasMatch(gap);

bool _isRunGap(String gap) => gap == ' ' || gap == ' ';

/// The words of a translation, to look names up in (see [nameRenderings]).
final class _Rendering {
  new(this.text) : words = _words(text) {
    for (final word in words) {
      if (_isCapitalised(word.text)) {
        _folded.putIfAbsent(
          TranslationPrompts.foldForMatching(word.text),
          () => word.text,
        );
      }
    }
  }

  final String text;
  final List<_Word> words;

  /// Capitalised words by their folded form (the first occurrence).
  final Map<String, String> _folded = {};

  bool get isEmpty => words.isEmpty;

  /// The form [name] (one or more words) has in the text, or null: as is,
  /// up to case and accents, or (for a single word of 5+ letters)
  /// inflected.
  String? find(List<String> name) {
    final joined = name.join(' ');
    if (name.length == 1) {
      if (words.any((word) => word.text == joined)) return joined;
      final folded = TranslationPrompts.foldForMatching(joined);
      if (_folded[folded] case final rendering?) return rendering;
      final letters = folded.runes.toList();
      if (letters.length < 5) return null;
      final prefix = String.fromCharCodes(
        letters.take(letters.length - (letters.length >= 7 ? 2 : 1)),
      );
      for (final MapEntry(key: form, value: rendering) in _folded.entries) {
        if (form.startsWith(prefix) &&
            form.runes.length <= letters.length + 4) {
          return rendering;
        }
      }
      return null;
    }
    final folded = name.map(TranslationPrompts.foldForMatching).toList();
    for (var i = 0; i + name.length <= words.length; i++) {
      if (!_isCapitalised(words[i].text)) continue;
      var same = true;
      for (var k = 0; k < name.length && same; k++) {
        same =
            TranslationPrompts.foldForMatching(words[i + k].text) ==
                folded[k] &&
            (k == 0 ||
                _isRunGap(
                  text.substring(words[i + k - 1].end, words[i + k].start),
                ));
      }
      if (same) {
        return [for (var k = 0; k < name.length; k++) words[i + k].text]
            .join(' ');
      }
    }
    return null;
  }
}

/// Translates a long [request] in [chunks] (from [ParagraphChunker.split]
/// of its text) with [translateInContext] (or the older [translate]: give
/// exactly one), which returns the stream of one chunk request (growing
/// snapshots and a final result, like a streaming AI translation).
///
/// * Chunks are translated in order, at most [concurrency] (at least 1) at
///   a time. When the source is auto, the first chunk is translated alone
///   and the language it detected becomes the source of the others, unless
///   it is the target language (same primary subtag, e.g. a reply below an
///   English e-mail translated into English): the others stay auto, so a
///   part in another language is still translated rather than polished as
///   if it were in the target language.
/// * Each chunk gets a [ChunkContext]: the end (about [contextChars]
///   characters, see [precedingTextTail]) of the previous chunk's text,
///   the end of the translation of the latest chunk before it that had
///   finished when it started, and the running term map ([ChunkTermMap],
///   at most [maxTerms] terms of `request.options.glossary` and capitalised
///   names from finished chunks). All empty for the first chunk.
///   [translate] gets only the preceding text. The context is for
///   reference only (consistent terms, tone and references) and must be
///   kept out of the system prompt: it is untrusted data like the chunk
///   itself (see `TranslationPrompts.translate`), and the user's own
///   `TranslationOptions.context` is passed on unchanged.
/// * Snapshots combine the chunks started so far (finished and in
///   progress, in order, joined with [ParagraphChunker.joiner]: the
///   original separators, and a space where a CJK sentence end meets text
///   in a script that uses spaces) and are `isComplete` only once every
///   chunk is done; `detectedSource` is that of the first chunk (of a later
///   one when the first reported none). The final result is `fromCache`
///   when every chunk came from [cache].
/// * A chunk that fails with a transient error (`LlmApiException
///   .isTransient`, see [retryPolicy]) is translated again, once by default
///   and after the policy's wait, while the other chunks go on; finished
///   chunks are never discarded. When a chunk still fails (or fails with
///   another error), the chunks in flight are cancelled, a last snapshot
///   with the finished chunks up to the first unfinished one is emitted
///   (when it has text and differs from the last snapshot) and then the
///   error, closing the stream. [LlmRetryPolicy.none] turns chunk retries
///   off.
/// * With a [cache], each chunk is first looked up by a [ChunkCacheKey]
///   (unless [refresh]), and the complete translation of every chunk that
///   was translated is stored, so that changing one part of a long text
///   only sends that part (and parts whose preceding text changed) again.
/// * Cancelling, pausing and resuming the returned stream are forwarded to
///   the chunks in flight; cancelling also stops pending retries.
Stream<TranslationResult> chunkedTranslation({
  required TranslationEngine engine,
  required TranslationRequest request,
  required List<TextChunk> chunks,
  required Language Function(String code) languageFor,
  Stream<TranslationResult> Function(
    TranslationRequest chunk,
    String precedingText,
  )?
  translate,
  Stream<TranslationResult> Function(
    TranslationRequest chunk,
    ChunkContext context,
  )?
  translateInContext,
  int concurrency = 2,
  int contextChars = 400,
  int maxTerms = TranslationPrompts.maxEarlierTerms,
  LlmRetryPolicy retryPolicy = LlmRetryPolicy.standard,
  ChunkCache? cache,
  bool refresh = false,
}) {
  if ((translate == null) == (translateInContext == null)) {
    throw ArgumentError('Give exactly one of translate and translateInContext');
  }
  if (chunks.isEmpty) return const Stream.empty();
  final count = chunks.length;
  final parallel = concurrency < 1 ? 1 : concurrency;
  final texts = List<String>.filled(count, '');
  final results = List<TranslationResult?>.filled(count, null);
  final detected = List<String?>.filled(count, null);
  final done = List<bool>.filled(count, false);
  final cached = List<bool>.filled(count, false);
  final attempts = List<int>.filled(count, 0);
  final running = <int, StreamSubscription<TranslationResult>>{};
  final waiting = <int, Timer>{};
  final terms = ChunkTermMap(
    maxTerms: maxTerms,
    glossary: request.options.glossary,
  );
  final elapsed = Stopwatch();
  late final StreamController<TranslationResult> controller;
  var source = request.source;
  var started = 0;
  var finished = 0;
  var stopped = false;
  ({String text, String? detected})? last;

  ChunkContext contextFor(int index) {
    if (index == 0) return ChunkContext(count: count);
    var latest = index - 1;
    while (latest >= 0 && !done[latest]) {
      latest--;
    }
    return ChunkContext(
      index: index,
      count: count,
      precedingText: precedingTextTail(
        chunks[index - 1].text,
        maxChars: contextChars,
      ),
      precedingTranslation: latest < 0
          ? ''
          : precedingTextTail(texts[latest], maxChars: contextChars),
      terms: terms.terms,
    );
  }

  String? detectedSource() {
    for (final code in detected) {
      if (code != null) return code;
    }
    return null;
  }

  /// The texts of the first [end] chunks, joined.
  String joined(int end) {
    final buffer = StringBuffer();
    for (var i = 0; i < end; i++) {
      if (i > 0) {
        buffer.write(
          ParagraphChunker.joiner(chunks[i - 1], texts[i - 1], texts[i]),
        );
      }
      buffer.write(texts[i]);
    }
    return buffer.toString();
  }

  TranslationResult resultOf(
    ({String text, String? detected}) snapshot, {
    required bool complete,
  }) => TranslationResult(
    engineId: engine.id,
    engineName: engine.name,
    text: snapshot.text,
    isComplete: complete,
    detectedSource: snapshot.detected,
    elapsed: elapsed.elapsed,
    fromCache: complete && cached.every((fromCache) => fromCache),
  );

  void cancelAll() {
    for (final timer in waiting.values) {
      timer.cancel();
    }
    waiting.clear();
    final subscriptions = running.values.toList();
    running.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  void stop(Object error, StackTrace stackTrace) {
    if (stopped) return;
    stopped = true;
    cancelAll();
    // Keep what is finished: the chunks up to the first unfinished one.
    var end = 0;
    while (end < count && done[end]) {
      end++;
    }
    final partial = (text: joined(end), detected: detectedSource());
    if (partial.text.isNotEmpty && partial != last) {
      controller.add(resultOf(partial, complete: false));
    }
    controller.addError(error, stackTrace);
    unawaited(controller.close());
  }

  void emit() {
    if (stopped) return;
    final complete = finished == count;
    // Chunks start in order, so the started ones are a prefix; in-progress
    // chunks at its end that have no text yet are left out.
    var end = started;
    while (end > 1 && !done[end - 1] && texts[end - 1].isEmpty) {
      end--;
    }
    final snapshot = (text: joined(end), detected: detectedSource());
    if (!complete && snapshot == last) return;
    last = snapshot;
    controller.add(resultOf(snapshot, complete: complete));
    if (complete) {
      stopped = true;
      unawaited(controller.close());
    }
  }

  late final void Function() startMore;
  late final void Function(int index) start;

  void failed(int index, Object error, StackTrace stackTrace) {
    if (stopped) return;
    final wait = error is LlmApiException
        ? retryPolicy.delayBefore(attempts[index] + 1, error)
        : null;
    if (wait == null) {
      stop(error, stackTrace);
      return;
    }
    attempts[index]++;
    waiting[index] = Timer(wait, () {
      waiting.remove(index);
      if (!stopped) start(index);
    });
  }

  start = (index) {
    final chunk = request.copyWith(text: chunks[index].text, source: source);
    final context = contextFor(index);
    final key = cache == null
        ? null
        : ChunkCacheKey(
            engineId: engine.id,
            request: chunk,
            precedingHash: ChunkCacheKey.hashPreceding(context.precedingText),
          );
    final hit = key == null || refresh ? null : cache!.lookup(key);
    final Stream<TranslationResult> stream;
    if (hit != null) {
      cached[index] = true;
      stream = Stream.value(hit);
    } else {
      try {
        stream = translateInContext != null
            ? translateInContext(chunk, context)
            : translate!(chunk, context.precedingText);
      } on Object catch (error, stackTrace) {
        failed(index, error, stackTrace);
        return;
      }
    }
    running[index] = stream.listen(
      (result) {
        results[index] = result;
        texts[index] = result.text;
        if (result.detectedSource case final code?) detected[index] = code;
        emit();
      },
      onError: (Object error, StackTrace stackTrace) {
        running.remove(index);
        failed(index, error, stackTrace);
      },
      onDone: () {
        running.remove(index);
        if (stopped) return;
        done[index] = true;
        finished++;
        if (results[index] case final result?
            when key != null && hit == null && result.isComplete) {
          cache!.store(key, result);
        }
        terms.addPart(chunks[index].text, texts[index]);
        final code = detected[0];
        if (index == 0 &&
            source.isAuto &&
            code != null &&
            !_isTarget(code, request.target)) {
          source = languageFor(code);
        }
        startMore();
        emit();
      },
      cancelOnError: true,
    );
    if (controller.isPaused) running[index]?.pause();
  };

  startMore = () {
    while (!stopped && started < count) {
      // An auto source is pinned by the first chunk before the others run.
      final limit = request.source.isAuto && !done[0] ? 1 : parallel;
      if (running.length + waiting.length >= limit) return;
      start(started++);
    }
  };

  controller = StreamController<TranslationResult>(
    onListen: () {
      elapsed.start();
      startMore();
    },
    onPause: () {
      for (final subscription in running.values) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in running.values) {
        subscription.resume();
      }
    },
    onCancel: () async {
      stopped = true;
      for (final timer in waiting.values) {
        timer.cancel();
      }
      waiting.clear();
      final subscriptions = running.values.toList();
      running.clear();
      await Future.wait([
        for (final subscription in subscriptions) subscription.cancel(),
      ]);
    },
  );
  return controller.stream;
}

/// The end of [preceding] (the text of the chunk before another one) to
/// show with that chunk: at most about [maxChars] characters, starting at a
/// word boundary and marked with a leading `…` when shortened.
String precedingTextTail(String preceding, {int maxChars = 400}) =>
    _tail(preceding.trim(), maxChars);

/// Whether the detected [code] is the language of [target] (same primary
/// subtag; never for a custom target).
bool _isTarget(String code, Language target) {
  if (target.isCustom || target.isAuto) return false;
  String primary(String c) =>
      LanguageMatcher.normalize(c).split('-').first.toLowerCase();
  return primary(code) == primary(target.code);
}

String _tail(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  if (maxChars < 1) return '';
  var start = text.length - maxChars;
  // Start at the next word when the cut falls inside one (unless the word
  // is very long, as in text without spaces).
  final previous = text.codeUnitAt(start - 1);
  if (!_isSpace(previous) && !_isSpace(text.codeUnitAt(start))) {
    final space = text.indexOf(RegExp(r'\s'), start);
    if (space >= 0 && space - start < maxChars ~/ 4) start = space + 1;
  }
  final unit = text.codeUnitAt(start);
  if (unit >= 0xDC00 && unit <= 0xDFFF) start++;
  return '…${text.substring(start).trimLeft()}';
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
