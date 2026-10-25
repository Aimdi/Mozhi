import 'package:equatable/equatable.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';

/// Something the settings tell the user once (a snackbar).
enum ScreenTranslateNotice {
  tileAdded,
  tileAlreadyAdded,
  tileFailed,

  /// "Display over other apps" was not allowed: no bubble.
  overlayDenied,

  /// The bubble is on, but its notification (with Stop) can't be shown.
  notificationsDenied,
  bubbleFailed,
}

class ScreenTranslateSettingsState extends Equatable {
  const new({
    this.support = const ScreenTranslateSupport(),
    this.loaded = false,
    this.busy = false,
    this.notice,
    this.noticeSerial = 0,
  });

  /// What the platform said last.
  final ScreenTranslateSupport support;

  /// Whether [support] was read at least once.
  final bool loaded;

  /// Turning the bubble on or off, or offering the tile.
  final bool busy;

  /// The last notice; [noticeSerial] tells a repeated one apart.
  final ScreenTranslateNotice? notice;
  final int noticeSerial;

  bool get bubbleOn => support.bubbleRunning;

  ScreenTranslateSettingsState copyWith({
    ScreenTranslateSupport? support,
    bool? loaded,
    bool? busy,
  }) => ScreenTranslateSettingsState(
    support: support ?? this.support,
    loaded: loaded ?? this.loaded,
    busy: busy ?? this.busy,
    notice: notice,
    noticeSerial: noticeSerial,
  );

  /// This state with [notice] to tell (once).
  ScreenTranslateSettingsState withNotice(ScreenTranslateNotice notice) =>
      ScreenTranslateSettingsState(
        support: support,
        loaded: loaded,
        busy: busy,
        notice: notice,
        noticeSerial: noticeSerial + 1,
      );

  @override
  List<Object?> get props => [support, loaded, busy, notice, noticeSerial];
}
