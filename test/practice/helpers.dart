import 'dart:async';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/data/practice_speech.dart';
import 'package:translation_repository/translation_repository.dart';

const english = Language(code: 'en', name: 'English');
const portuguese = Language(code: 'pt', name: 'Portuguese');

/// 2026-10-22 09:00 local time.
final practiceStart = DateTime(2026, 10, 22, 9);

/// A history favourite [id] (`text <id>` → `tradução <id>`).
HistoryEntry favorite(
  String id, {
  String? text,
  String? translation,
  Language source = english,
  Language target = portuguese,
  DateTime? createdAt,
}) => HistoryEntry(
  id: id,
  text: text ?? 'text $id',
  translation: translation ?? 'tradução $id',
  source: source,
  target: target,
  engineId: 'offline',
  engineName: 'Offline',
  createdAt: createdAt ?? practiceStart,
  isFavorite: true,
);

/// [PhrasebookFavorites] holding [entries] in memory.
class MemoryFavorites implements PhrasebookFavorites {
  new([List<HistoryEntry>? entries]) : entries = [...?entries];

  List<HistoryEntry> entries;
  final StreamController<void> _changes = StreamController.broadcast();

  /// Replaces the favourites and says so.
  void set(List<HistoryEntry> next) {
    entries = [...next];
    _changes.add(null);
  }

  @override
  Future<List<HistoryEntry>> favorites() async => List.unmodifiable(entries);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> remove(String historyId) async => set([
    for (final e in entries)
      if (e.id != historyId) e,
  ]);

  @override
  Future<void> restore(String historyId) async {}
}

/// A clock the test moves.
class TestClock {
  new([DateTime? start]) : now = start ?? practiceStart;

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

/// A phrasebook and practice on memory stores, with [favorites].
class PracticeFixture {
  new({List<HistoryEntry> favorites = const [], TestClock? clock})
    : clock = clock ?? TestClock(),
      favorites = MemoryFavorites(favorites) {
    phrasebook = PhrasebookRepository(
      store: store,
      keyStore: keyStore,
      favorites: this.favorites,
      clock: this.clock.call,
    );
    practice = newPractice();
  }

  final TestClock clock;
  final MemoryFavorites favorites;
  final store = FailingStore();
  final keyStore = MemoryStore();
  late final PhrasebookRepository phrasebook;
  late PracticeRepository practice;

  /// Another repository on the same stores (a restart).
  PracticeRepository newPractice() => PracticeRepository(
    phrasebook: phrasebook,
    store: store,
    keyStore: keyStore,
    clock: clock.call,
  );

  /// A collection [name] with phrases `texts` (each `<text>` →
  /// `<text> (pt)`).
  Future<PhraseCollection> collection(
    String name,
    List<String> texts, {
    String source = 'en',
    String target = 'pt',
  }) async {
    final collection = await phrasebook.createCollection(name);
    for (final text in texts) {
      await phrasebook.addPhrase(
        PhraseDraft(
          text: text,
          translation: '$text (pt)',
          sourceCode: source,
          targetCode: target,
        ),
        collection.id,
      );
      clock.advance(const Duration(seconds: 1));
    }
    return (await phrasebook.collection(collection.id))!;
  }
}

/// A recogniser the test drives: [listen] waits for [answer] or [fail].
class FakeRecognizer implements PracticeRecognizer {
  new({this.available = PracticeSpeechAvailability.ready});

  PracticeSpeechAvailability available;
  Completer<String>? _pending;
  void Function(double level)? onLevel;
  void Function()? onTranscribing;
  String? language;
  int stops = 0;
  int cancels = 0;
  bool disposed = false;

  @override
  Future<PracticeSpeechAvailability> availability() async => available;

  @override
  bool supportsLanguage(String code) => code != 'yue';

  @override
  Future<String> listen(
    String code, {
    void Function(double level)? onLevel,
    void Function()? onTranscribing,
  }) {
    language = code;
    this.onLevel = onLevel;
    this.onTranscribing = onTranscribing;
    return (_pending = Completer<String>()).future;
  }

  void answer(String text) {
    if (_pending case final pending? when !pending.isCompleted) {
      pending.complete(text);
    }
  }

  void fail(Object error) => _pending?.completeError(error);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async {
    cancels++;
    if (_pending case final pending? when !pending.isCompleted) {
      pending.completeError(
        const PracticeSpeechException(PracticeSpeechFailure.cancelled),
      );
    }
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// A [MemoryStore] whose writes fail while [failWrites].
class FailingStore extends MemoryStore {
  bool failWrites = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('full');
    await super.write(key, value);
  }
}
