import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_server.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:mozhi/platform/lan_address.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where sharing on the local network stands.
enum ConversationShareStatus {
  /// Not shared.
  idle,

  /// Looking for the network and starting the server.
  starting,

  /// Guests can join ([ConversationShareState.url]).
  live,

  /// The phone has no private address (no Wi-Fi, no hotspot).
  noNetwork,

  /// The server could not start.
  failed,
}

class ConversationShareState extends Equatable {
  const new({
    this.status = ConversationShareStatus.idle,
    this.url,
    this.pin,
    this.guests = const [],
    this.languages = const [],
    this.repliesAllowed = true,
    this.locked = false,
    this.engineName,
    this.maxExtraLanguages = ShareRoom.defaultMaxExtraLanguages,
  });

  final ConversationShareStatus status;

  /// The guests' link (while [isLive]).
  final Uri? url;

  /// The PIN guests enter, if one is asked for.
  final String? pin;

  /// The guests, in the order they joined.
  final List<ShareGuest> guests;

  /// The guests' languages that are not one of the conversation's two.
  final List<ShareLanguageState> languages;

  /// Whether guests may reply.
  final bool repliesAllowed;

  /// Too many wrong PINs: nobody new can join (a new PIN lifts it).
  final bool locked;

  /// The host's engine, which translates the guests' other languages.
  final String? engineName;

  /// The most [languages] guests may read at a time
  /// ([ShareRoom.maxExtraLanguages]).
  final int maxExtraLanguages;

  bool get isLive => status == ConversationShareStatus.live;

  /// Starting or live: the sharing has to be stopped.
  bool get isActive =>
      status == ConversationShareStatus.live ||
      status == ConversationShareStatus.starting;

  @override
  List<Object?> get props => [
    status,
    url,
    pin,
    guests,
    languages,
    repliesAllowed,
    locked,
    engineName,
    maxExtraLanguages,
  ];
}

/// Shares a conversation ([ConversationCubit]) on the local network: the
/// phone serves a small page at a link (and QR code) that guests on the
/// same Wi-Fi (or the phone's hotspot) open in their browser to follow
/// the conversation in their own language and reply ([ShareRoom], served
/// by [startShareServer]; Android only).
///
/// * Guests see the turns said after [start] (not what was said before),
///   in their language: the conversation's own translation, or one more
///   translation per extra language by the host's engine under the host's
///   privacy settings ([ShareTranslations]).
/// * A guest's reply becomes a turn of the conversation
///   ([ConversationCubit.submitGuest]).
/// * The link holds a random 128-bit token; with a PIN ([start] `pin`,
///   [setPinRequired]) guests also enter four digits.
/// * The screen stays on while shared ([ScreenAwake]).
/// * Sharing stops with [stop], when no screen of the conversation is
///   shown for [leaveGrace] ([setVisible]: another tab, another page),
///   when the app stays in the background (the phone locked) for
///   [hiddenLimit] ([appHidden]), and in [close]. Guests then see "The
///   conversation ended".
class ConversationShareCubit extends Cubit<ConversationShareState> {
  new({
    required this._conversation,
    required this._repository,
    required this._engine,
    required this._engines,
    required this._languages,
    this._options,
    this._usageTracker,
    Future<List<String>> Function()? addresses,
    ShareServerFactory? server,
    ShareStrings? strings,
    ShareSecrets? secrets,
    ScreenAwake? screenAwake,
    Timer Function(Duration, void Function())? timer,
    DateTime Function()? clock,
    this.leaveGrace = defaultLeaveGrace,
    this.hiddenLimit = defaultHiddenLimit,
  }) : _addresses = addresses ?? localNetworkAddresses,
       _serverFactory = server ?? startShareServer,
       _strings = strings ?? shareStrings,
       _secrets = secrets ?? ShareSecrets(),
       _screenAwake = screenAwake ?? ScreenAwake(),
       _timer = timer ?? Timer.new,
       _clock = clock ?? DateTime.now,
       super(const ConversationShareState());

  /// Shares [conversation] with the engine, languages and options of the
  /// app-wide [translate] screen (as the conversation translates).
  factory withTranslate({
    required ConversationCubit conversation,
    required TranslateCubit translate,
    required TranslationRepository repository,
    UsageTracker? usageTracker,
    Future<List<String>> Function()? addresses,
    ShareServerFactory? server,
  }) => ConversationShareCubit(
    conversation: conversation,
    repository: repository,
    engine: () => translate.state.engine,
    engines: () => translate.state.engines,
    languages: () => translate.state.targetLanguages,
    options: () => translate.state.options,
    usageTracker: usageTracker,
    addresses: addresses,
    server: server,
  );

  /// See [leaveGrace].
  static const defaultLeaveGrace = Duration(seconds: 3);

  /// See [hiddenLimit].
  static const defaultHiddenLimit = Duration(minutes: 2);

  final ConversationCubit _conversation;
  final TranslationRepository _repository;
  final TranslationEngine? Function() _engine;
  final List<TranslationEngine> Function() _engines;
  final List<Language> Function() _languages;
  final TranslationOptions Function()? _options;
  final UsageTracker? _usageTracker;
  final Future<List<String>> Function() _addresses;
  final ShareServerFactory _serverFactory;
  final ShareStrings _strings;
  final ShareSecrets _secrets;
  final ScreenAwake _screenAwake;
  final Timer Function(Duration, void Function()) _timer;
  final DateTime Function() _clock;

  /// How long sharing goes on while no screen of the conversation is
  /// shown (moving between the conversation and the sharing page).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration leaveGrace;

  /// How long sharing goes on while the app is in the background.
  // ignore: avoid_public_fields
  final Duration hiddenLimit;

  ShareRoom? _room;
  ShareServer? _server;
  StreamSubscription<List<ConversationTurn>>? _turns;
  StreamSubscription<void>? _changes;

  /// Turns said before the sharing started (not shared).
  Set<int> _before = const {};

  /// Bumped by every start and stop.
  int _generation = 0;

  /// [close] was called (stopping emits nothing more).
  bool _closing = false;

  final Set<Object> _visible = {};
  Timer? _leaveTimer;
  Timer? _hiddenTimer;
  DateTime? _hiddenSince;

  /// Starts sharing (asking for a [pin] unless false). Does nothing while
  /// sharing.
  Future<void> start({bool pin = true}) async {
    if (isClosed || state.isActive) return;
    final generation = ++_generation;
    emit(
      const ConversationShareState(status: ConversationShareStatus.starting),
    );
    final addresses = await _addresses();
    if (isClosed || generation != _generation) return;
    if (addresses.isEmpty) {
      emit(
        const ConversationShareState(status: ConversationShareStatus.noNetwork),
      );
      return;
    }
    final room = ShareRoom(
      token: _secrets.token(),
      languages: _guestLanguages(),
      translations: ShareTranslations(
        repository: _repository,
        engine: _engine,
        engines: _engines,
        options: _options,
        usageTracker: _usageTracker,
      ),
      onReply: _onReply,
      conversationLanguages: () => [
        _conversation.state.languageA,
        _conversation.state.languageB,
      ],
      pin: pin ? _secrets.pin() : null,
      secrets: _secrets,
      clock: _clock,
      timer: _timer,
    );
    final ShareServer server;
    try {
      server = await _serverFactory(
        address: addresses.first,
        room: room,
        strings: _strings,
      );
    } on Object {
      await room.end();
      if (!isClosed && generation == _generation) {
        emit(
          const ConversationShareState(status: ConversationShareStatus.failed),
        );
      }
      return;
    }
    if (isClosed || generation != _generation) {
      await room.end();
      await server.close();
      return;
    }
    _room = room;
    _server = server;
    _before = {for (final turn in _conversation.state.turns) turn.id};
    room.update(_shared(_conversation.state.turns));
    // Only when the turns change (not the hands-free session's partials).
    _turns = _conversation.stream
        .map((conversation) => conversation.turns)
        .distinct()
        .listen((turns) => room.update(_shared(turns)));
    _changes = room.changes.listen((_) => _emitLive());
    unawaited(_screenAwake.setEnabled(enabled: true));
    _emitLive();
    _checkVisible();
  }

  /// Stops sharing: every guest sees "The conversation ended".
  Future<void> stop() async {
    _generation++;
    _leaveTimer?.cancel();
    _leaveTimer = null;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    final room = _room;
    final server = _server;
    final wasActive = state.isActive;
    _room = null;
    _server = null;
    await _turns?.cancel();
    _turns = null;
    await _changes?.cancel();
    _changes = null;
    if (!isClosed &&
        !_closing &&
        state.status != ConversationShareStatus.idle) {
      emit(const ConversationShareState());
    }
    if (room != null) await room.end();
    if (server != null) await server.close();
    if (wasActive && room != null) {
      await _screenAwake.setEnabled(enabled: false);
    }
  }

  /// Asks new guests for a (new) PIN, or for none. Guests who joined stay.
  void setPinRequired({required bool required}) {
    final room = _room;
    if (room == null) return;
    room.pin = required ? _secrets.pin() : null;
    _emitLive();
  }

  /// Whether guests may reply.
  void setRepliesAllowed({required bool allowed}) {
    final room = _room;
    if (room == null) return;
    room.repliesAllowed = allowed;
    _emitLive();
  }

  /// The host gave [consent] for [language]'s translations (from the
  /// sharing page's consent prompt, by default the one it showed): the
  /// turns that waited for it are translated, and what the consent would
  /// still let through afterwards is withdrawn.
  void retryLanguage(Language language, {ConsentRequiredException? consent}) =>
      _room?.retryLanguage(language, consent: consent);

  /// Whether a screen of the conversation ([owner]: the conversation, the
  /// sharing page, face-to-face mode) is shown. With none shown for
  /// [leaveGrace], sharing stops.
  void setVisible(Object owner, {required bool visible}) {
    if (visible) {
      _visible.add(owner);
    } else {
      _visible.remove(owner);
    }
    _checkVisible();
  }

  void _checkVisible() {
    if (_visible.isNotEmpty || !state.isActive) {
      _leaveTimer?.cancel();
      _leaveTimer = null;
      return;
    }
    _leaveTimer ??= _timer(leaveGrace, () {
      _leaveTimer = null;
      if (_visible.isEmpty) unawaited(stop());
    });
  }

  /// The app went to the background (the phone locked, another app):
  /// sharing stops after [hiddenLimit] unless [appShown] comes first.
  void appHidden() {
    if (!state.isActive || _hiddenSince != null) return;
    _hiddenSince = _clock();
    _hiddenTimer = _timer(hiddenLimit, () {
      _hiddenTimer = null;
      unawaited(stop());
    });
  }

  /// The app is in the foreground again. If it was away for
  /// [hiddenLimit] (a frozen app's timer may not have fired), sharing
  /// stops now.
  void appShown() {
    final since = _hiddenSince;
    _hiddenSince = null;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    if (since != null &&
        state.isActive &&
        _clock().difference(since) >= hiddenLimit) {
      unawaited(stop());
    }
  }

  /// What guests may pick: the host engine's languages (no "Detect
  /// language", no custom styles), with the conversation's two first when
  /// the engine does not list them.
  List<Language> _guestLanguages() {
    final conversation = _conversation.state;
    final result = <Language>[];
    void add(Language language) {
      if (language.isAuto || language.isCustom) return;
      if (result.any(
        (other) => ShareTranslations.sameLanguage(other, language),
      )) {
        return;
      }
      result.add(language);
    }

    add(conversation.languageA);
    add(conversation.languageB);
    ([
          ..._languages(),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())))
        .forEach(add);
    return result;
  }

  List<ConversationTurn> _shared(List<ConversationTurn> turns) => [
    for (final turn in turns)
      if (!_before.contains(turn.id)) turn,
  ];

  void _onReply(ShareGuest guest, String text) => unawaited(
    _conversation.submitGuest(
      text,
      language: guest.language,
      guest: guest.number,
    ),
  );

  void _emitLive() {
    final room = _room;
    final server = _server;
    if (isClosed || room == null || server == null) return;
    emit(
      ConversationShareState(
        status: ConversationShareStatus.live,
        url: server.url,
        pin: room.pin,
        guests: room.guests,
        languages: room.languageStates(),
        repliesAllowed: room.repliesAllowed,
        locked: room.locked,
        engineName: _engine()?.name,
        maxExtraLanguages: room.maxExtraLanguages,
      ),
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    await stop();
    await super.close();
  }
}
