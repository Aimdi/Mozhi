import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/core/privacy/egress/egress_entry.dart';

/// What went to one destination this session ([EgressLedger.summarize]).
class EgressDestinationSummary extends Equatable {
  const new({
    required this.destination,
    required this.requests,
    required this.contentRequests,
    required this.bytesSent,
    required this.bytesReceived,
    required this.purposes,
    required this.lastAt,
    this.viaProxy = false,
    this.unencrypted = false,
  });

  final EgressDestination destination;

  /// Requests that may have reached it (refused ones are not counted).
  final int requests;

  /// How many of them carried the user's text or a photo.
  final int contentRequests;
  final int bytesSent;
  final int bytesReceived;

  /// Why the app talked to it.
  final Set<EgressPurpose> purposes;

  /// When the last request started.
  final DateTime lastAt;

  /// Whether any request went through the proxy.
  final bool viaProxy;

  /// Whether any request used plain `http`.
  final bool unencrypted;

  /// Whether the user's text or a photo went there.
  bool get receivedContent => contentRequests > 0;

  @override
  List<Object?> get props => [
    destination,
    requests,
    contentRequests,
    bytesSent,
    bytesReceived,
    purposes,
    lastAt,
    viaProxy,
    unencrypted,
  ];
}

/// The requests the app made this session, newest last, in memory only.
///
/// Every request of the app's HTTP client is recorded here (see
/// `EgressRecordingClient` and `NetworkSession.ledger`) with its time,
/// method, destination, purpose, sizes and result, never with its body,
/// path, query or headers. Nothing is written to storage: the log ends with
/// the app (or [clear]). At most [capacity] entries are kept; older ones
/// are dropped and counted in [dropped].
class EgressLedger {
  new({this.capacity = defaultCapacity, DateTime Function()? clock})
    : assert(capacity > 0, 'capacity must be positive'),
      _clock = clock ?? DateTime.now {
    _since = _clock();
  }

  /// How many entries a ledger keeps by default.
  static const defaultCapacity = 500;

  final int capacity;
  final DateTime Function() _clock;
  final _entries = <EgressEntry>[];
  final _changes = StreamController<void>.broadcast(sync: true);
  late DateTime _since;
  var _nextId = 1;
  var _dropped = 0;

  /// The entries, oldest first.
  List<EgressEntry> get entries => List.unmodifiable(_entries);

  /// When this log started: the start of the session, or the last [clear].
  DateTime get since => _since;

  /// How many old entries were dropped because the log was full.
  int get dropped => _dropped;

  /// Whether nothing was recorded since [since].
  bool get isEmpty => _entries.isEmpty && _dropped == 0;

  /// Fires after every change (synchronously).
  Stream<void> get changes => _changes.stream;

  /// The current time of the ledger's clock.
  DateTime now() => _clock();

  /// Records a request that is being sent and returns it (with its id).
  EgressEntry begin({
    required String method,
    required String scheme,
    required EgressDestination destination,
    required EgressPurpose purpose,
    bool viaProxy = false,
    int? bytesSent,
  }) {
    final entry = EgressEntry(
      id: _nextId++,
      startedAt: _clock(),
      method: method,
      scheme: scheme,
      destination: destination,
      purpose: purpose,
      viaProxy: viaProxy,
      bytesSent: bytesSent,
    );
    _append(entry);
    return entry;
  }

  /// Adds an entry recorded elsewhere (another engine of this process),
  /// numbered by this ledger.
  void add(EgressEntry entry) => _append(entry.copyWith(id: _nextId++));

  /// Replaces the entry with [entry]'s id, unless it was dropped or
  /// cleared meanwhile.
  void update(EgressEntry entry) {
    if (_changes.isClosed) return;
    final index = _entries.lastIndexWhere((e) => e.id == entry.id);
    if (index < 0) return;
    _entries[index] = entry;
    _changes.add(null);
  }

  /// Forgets every entry and starts a new log now.
  void clear() {
    _entries.clear();
    _dropped = 0;
    _since = _clock();
    if (!_changes.isClosed) _changes.add(null);
  }

  /// One summary per destination that may have received a request, those
  /// that received the user's text or a photo first, then by number of
  /// requests (and name).
  List<EgressDestinationSummary> summarize() {
    final groups = <EgressDestination, List<EgressEntry>>{};
    for (final entry in _entries) {
      if (!entry.outcome.mayHaveLeftDevice) continue;
      (groups[entry.destination] ??= []).add(entry);
    }
    final summaries = [
      for (final MapEntry(key: destination, value: entries) in groups.entries)
        EgressDestinationSummary(
          destination: destination,
          requests: entries.length,
          contentRequests: entries.where((e) => e.carriedContent).length,
          bytesSent: entries.fold(0, (sum, e) => sum + (e.bytesSent ?? 0)),
          bytesReceived: entries.fold(0, (sum, e) => sum + e.bytesReceived),
          purposes: {for (final e in entries) e.purpose},
          lastAt: entries
              .map((e) => e.startedAt)
              .reduce((a, b) => a.isAfter(b) ? a : b),
          viaProxy: entries.any((e) => e.viaProxy),
          unencrypted: entries.any((e) => e.scheme == 'http'),
        ),
    ];
    return summaries..sort((a, b) {
      if (a.receivedContent != b.receivedContent) {
        return a.receivedContent ? -1 : 1;
      }
      final byCount = b.requests.compareTo(a.requests);
      if (byCount != 0) return byCount;
      return a.destination.authority.compareTo(b.destination.authority);
    });
  }

  /// Stops notifying [changes]; the entries stay readable.
  Future<void> dispose() => _changes.close();

  void _append(EgressEntry entry) {
    if (_changes.isClosed) return;
    _entries.add(entry);
    if (_entries.length > capacity) {
      final excess = _entries.length - capacity;
      _entries.removeRange(0, excess);
      _dropped += excess;
    }
    _changes.add(null);
  }
}
