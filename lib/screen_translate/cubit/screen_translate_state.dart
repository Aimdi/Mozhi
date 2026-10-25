import 'package:equatable/equatable.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';

/// Where the screen-translate window is.
enum ScreenTranslateStatus {
  /// Waiting for the user's consent and the screenshot: the window draws
  /// nothing (it is in the frame being taken).
  capturing,

  /// Mozhi is locked and the system prompt is open: still nothing drawn.
  unlocking,

  /// Mozhi is locked (the prompt was cancelled, or it locked again): the
  /// screenshot is hidden behind a lock card.
  locked,

  /// The screenshot is shown and translated.
  ready,

  /// The screenshot came out black (the app on screen blocks capture).
  blank,

  /// No screenshot could be taken.
  failed,
}

class ScreenTranslateState extends Equatable {
  const new({
    this.status = ScreenTranslateStatus.capturing,
    this.screenshot,
    this.failure,
  });

  final ScreenTranslateStatus status;

  /// The screenshot as an image to translate (kept while locked, shown
  /// only when [status] is [ScreenTranslateStatus.ready]).
  final PickedImage? screenshot;

  /// The platform's reason when [ScreenTranslateStatus.failed].
  final String? failure;

  /// Whether the window draws nothing at all (capture, system prompt).
  bool get isInvisible =>
      status == ScreenTranslateStatus.capturing ||
      status == ScreenTranslateStatus.unlocking;

  ScreenTranslateState copyWith({
    ScreenTranslateStatus? status,
    PickedImage? screenshot,
    String? failure,
  }) => ScreenTranslateState(
    status: status ?? this.status,
    screenshot: screenshot ?? this.screenshot,
    failure: failure ?? this.failure,
  );

  @override
  List<Object?> get props => [status, screenshot, failure];
}
