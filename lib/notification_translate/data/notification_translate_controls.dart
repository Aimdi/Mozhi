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
  const new({
    this.hasAccess = false,
    this.enabled = false,
    this.notificationsAllowed = true,
    this.mutedPackages = const [],
    this.targetLanguage,
  });

  final bool hasAccess;
  final bool enabled;
  final bool notificationsAllowed;
  final List<String> mutedPackages;
  final String? targetLanguage;

  bool get isActive => hasAccess && enabled;

  @override
  List<Object?> get props => [
    hasAccess,
    enabled,
    notificationsAllowed,
    mutedPackages,
    targetLanguage,
  ];
}

/// Platform contract for opt-in offline notification translation.
abstract interface class NotificationTranslateControls {
  /// Whether this platform supports listening to notifications (Android only).
  bool get isSupported;

  /// Reads notification access, opt-in toggle, posting permission, muted apps
  /// and optional dedicated target language from Android.
  Future<NotificationTranslateStatus> status();

  /// Turns notification translation on or off.
  Future<void> setEnabled({required bool enabled});

  /// Opens Android's Notification Access settings screen.
  Future<bool> openAccessSettings();

  /// Requests Android 13+ `POST_NOTIFICATIONS` permission so translated
  /// notifications can be shown; true when already granted or not needed.
  Future<bool> requestNotificationPermission();

  /// Lists packages currently muted from notification translation.
  Future<List<String>> mutedPackages();

  /// Adds or removes [packageName] from the muted packages set.
  Future<void> setPackageMuted(String packageName, {required bool muted});

  /// Sets an optional dedicated target language code (null/empty to follow
  /// the Translate tab target language).
  Future<void> setTargetLanguage(String? code);

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
      final rawMuted = raw?['mutedPackages'];
      final muted = <String>[
        if (rawMuted is List)
          for (final item in rawMuted)
            if (item is String && item.isNotEmpty) item,
      ];
      final rawTarget = raw?['targetLanguage'];
      final target = rawTarget is String && rawTarget.trim().isNotEmpty
          ? rawTarget.trim()
          : null;
      return NotificationTranslateStatus(
        hasAccess: raw?['hasAccess'] == true,
        enabled: raw?['enabled'] == true,
        notificationsAllowed: raw?['notificationsAllowed'] != false,
        mutedPackages: List.unmodifiable(muted),
        targetLanguage: target,
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
  Future<bool> requestNotificationPermission() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<String>> mutedPackages() async {
    if (!_supported) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('mutedPackages');
      return List.unmodifiable([
        if (raw != null)
          for (final item in raw)
            if (item is String && item.isNotEmpty) item,
      ]);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> setPackageMuted(
    String packageName, {
    required bool muted,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setPackageMuted', {
        'packageName': packageName,
        'muted': muted,
      });
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Ignore best-effort mute errors.
    }
  }

  @override
  Future<void> setTargetLanguage(String? code) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setTargetLanguage', {'code': code});
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Ignore best-effort target language errors.
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
