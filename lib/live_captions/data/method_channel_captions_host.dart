import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/platform/android_device.dart';

/// The Android API level from which captions run: 29 (Android 10, the
/// first with `AudioPlaybackCaptureConfiguration`).
const liveCaptionsMinSdk = 29;

/// [CaptionsHost] over `LiveCaptionsPlugin.kt`: the method channel
/// [channelName] (`start`, `show`, `stop`) and the event channels
/// [audioChannelName] (float blocks) and [eventsChannelName] (the bar's
/// taps and the capture's end, lock and unlock).
///
/// Supported on Android (`isAndroid`, default [runsOnAndroid]) from API
/// level [liveCaptionsMinSdk] ([sdkInt], see [platformCaptionsHost]); off
/// it nothing is called. Platform errors count as a failed start, and
/// `show` and `stop` never throw.
class MethodChannelCaptionsHost implements CaptionsHost {
  new({
    required this.sdkInt,
    MethodChannel? channel,
    EventChannel? audioChannel,
    EventChannel? eventsChannel,
    bool? isAndroid,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _audioChannel = audioChannel ?? const EventChannel(audioChannelName),
       _eventsChannel = eventsChannel ?? const EventChannel(eventsChannelName),
       _isAndroid = isAndroid ?? runsOnAndroid;

  static const channelName = 'io.github.aimdi.mozhi/live_captions';
  static const audioChannelName = 'io.github.aimdi.mozhi/live_captions/audio';
  static const eventsChannelName = 'io.github.aimdi.mozhi/live_captions/events';

  /// The Android API level (null: not known, unsupported).
  final int? sdkInt;
  final MethodChannel _channel;
  final EventChannel _audioChannel;
  final EventChannel _eventsChannel;
  final bool _isAndroid;

  @override
  bool get isSupported =>
      !kIsWeb && _isAndroid && (sdkInt ?? 0) >= liveCaptionsMinSdk;

  @override
  late final Stream<Float32List> audio = isSupported
      ? _audioChannel
            .receiveBroadcastStream()
            .map(_samplesOf)
            .where((samples) => samples.isNotEmpty)
      : const Stream.empty();

  @override
  late final Stream<CaptionBarEvent> events = isSupported
      ? _eventsChannel
            .receiveBroadcastStream()
            .map(CaptionBarEvent.parse)
            .where((event) => event != null)
            .cast<CaptionBarEvent>()
      : const Stream.empty();

  @override
  Future<CaptureStart> start() async {
    if (!isSupported) return const CaptureFailed(CaptureFailure.unsupported);
    final Map<String, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<String, Object?>('start');
    } on MissingPluginException {
      return const CaptureFailed(CaptureFailure.unsupported);
    } on PlatformException {
      return const CaptureFailed(CaptureFailure.unknown);
    }
    return switch (answer?['status']) {
      'started' => CaptureStarted(captionBar: answer?['captionBar'] == true),
      'declined' => const CaptureDeclined(),
      _ => CaptureFailed(CaptureFailure.parse(answer?['reason'] as String?)),
    };
  }

  @override
  Future<void> show(CaptionLine line) => _call('show', {
    'translation': line.translation,
    'original': line.original,
    'final': line.isFinal,
  });

  @override
  Future<void> stop() => _call('stop');

  Future<void> _call(String method, [Object? arguments]) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No captions to show or stop.
    } on PlatformException {
      // No captions to show or stop.
    }
  }

  /// A block of samples: a `Float32List` from Android (`FloatArray`); a
  /// list of numbers is taken too; anything else is empty.
  static Float32List _samplesOf(Object? block) => switch (block) {
    final Float32List samples => samples,
    final List<Object?> values => Float32List.fromList([
      for (final value in values)
        if (value is num) value.toDouble(),
    ]),
    _ => Float32List(0),
  };
}

/// [CaptionsHost] where captions cannot run (the web app, Android before
/// 10, tests): unsupported, and every start fails as such.
class UnsupportedCaptionsHost implements CaptionsHost {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<CaptureStart> start() async =>
      const CaptureFailed(CaptureFailure.unsupported);

  @override
  Stream<Float32List> get audio => const Stream.empty();

  @override
  Future<void> show(CaptionLine line) async {}

  @override
  Stream<CaptionBarEvent> get events => const Stream.empty();

  @override
  Future<void> stop() async {}
}

/// The captions host of this platform: [MethodChannelCaptionsHost] on
/// Android 10 and later, [UnsupportedCaptionsHost] everywhere else (the
/// API level is asked once from `MainActivity.kt`, see [androidSdkInt]).
Future<CaptionsHost> platformCaptionsHost({
  MethodChannel? privacyChannel,
  bool? isAndroid,
}) async {
  if (kIsWeb || !(isAndroid ?? runsOnAndroid)) {
    return const UnsupportedCaptionsHost();
  }
  final sdk = await androidSdkInt(channel: privacyChannel, isAndroid: true);
  if ((sdk ?? 0) < liveCaptionsMinSdk) return const UnsupportedCaptionsHost();
  return MethodChannelCaptionsHost(sdkInt: sdk, isAndroid: true);
}
