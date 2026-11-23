import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';

/// An incoming notification forwarded from Android's
/// `NotificationTranslateService`.
@immutable
final class IncomingNotification extends Equatable {
  const new({
    required this.id,
    required this.packageName,
    required this.title,
    required this.text,
  });

  factory fromMap(Map<Object?, Object?> map) => IncomingNotification(
    id: (map['id'] as num?)?.toInt() ?? 0,
    packageName: '${map['packageName'] ?? ''}',
    title: '${map['title'] ?? ''}',
    text: '${map['text'] ?? ''}',
  );

  final int id;
  final String packageName;
  final String title;
  final String text;

  @override
  List<Object?> get props => [id, packageName, title, text];
}

/// Platform status of Android's opt-in offline notification translation.
@immutable
final class NotificationTranslateStatus extends Equatable {
  const new({this.hasAccess = false, this.enabled = false});

  final bool hasAccess;
  final bool enabled;

  bool get isActive => hasAccess && enabled;

  @override
  List<Object?> get props => [hasAccess, enabled];
}

/// Platform contract for opt-in offline notification translation.
abstract interface class NotificationTranslateControls {
  /// Whether this platform supports listening to notifications (Android only).
  bool get isSupported;

  /// Reads whether notification access is granted and the opt-in toggle is on.
  Future<NotificationTranslateStatus> status();

  /// Turns notification translation on or off.
  Future<void> setEnabled({required bool enabled});

  /// Opens Android's Notification Access settings screen.
  Future<bool> openAccessSettings();

  /// Posts a local-only translated notification back to Android.
  Future<void> postTranslation({
    required int id,
    required String title,
    required String translation,
  });

  /// Stream of incoming notifications posted while enabled.
  Stream<IncomingNotification> get notifications;
}

/// MethodChannel + EventChannel bridge to `NotificationTranslatePlugin.kt`.
final class MethodChannelNotificationTranslateControls
    implements NotificationTranslateControls {
  new({MethodChannel? channel, EventChannel? events, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      _events = events ?? const EventChannel(eventsChannelName),
      _supported = supported ?? runsOnAndroid;

  static const channelName = 'io.github.aimdi.mozhi/notification_translate';
  static const eventsChannelName =
      'io.github.aimdi.mozhi/notification_translate/events';

  static final MethodChannelNotificationTranslateControls instance =
      MethodChannelNotificationTranslateControls();

  final MethodChannel _channel;
  final EventChannel _events;
  final bool _supported;

  @override
  bool get isSupported => _supported;

  @override
  Future<NotificationTranslateStatus> status() async {
    if (!_supported) return const NotificationTranslateStatus();
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('status');
      return NotificationTranslateStatus(
        hasAccess: raw?['hasAccess'] == true,
        enabled: raw?['enabled'] == true,
      );
    } on MissingPluginException {
      return const NotificationTranslateStatus();
    } on PlatformException {
      return const NotificationTranslateStatus();
    }
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Ignore best-effort toggle errors.
    }
  }

  @override
  Future<bool> openAccessSettings() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAccessSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> postTranslation({
    required int id,
    required String title,
    required String translation,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('postTranslation', {
        'id': id,
        'title': title,
        'translation': translation,
      });
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Ignore notification posting failure.
    }
  }

  @override
  Stream<IncomingNotification> get notifications {
    if (!_supported) return const Stream.empty();
    return _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => IncomingNotification.fromMap(event as Map));
  }
}
