import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';

/// Platform bridge to Android's `ModelDownloadService` (`dataSync` foreground
/// service) that keeps large model downloads running when the user leaves the
/// app.
abstract interface class DownloadForegroundService {
  /// Starts or updates the foreground notification for active downloads.
  Future<void> start({required String title, int? progress});

  /// Updates the progress (0..100, or null for indeterminate).
  Future<void> update({required String title, int? progress});

  /// Stops the foreground service when no downloads remain.
  Future<void> stop();

  /// Stream firing whenever the user taps **Cancel** on the notification.
  Stream<void> get cancelRequests;
}

/// MethodChannel implementation on Android (`io.github.aimdi.mozhi/model_downloads`);
/// no-op on web and desktop platforms.
final class MethodChannelDownloadForegroundService
    implements DownloadForegroundService {
  new({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      _supported = supported ?? runsOnAndroid;

  static const channelName = 'io.github.aimdi.mozhi/model_downloads';

  final MethodChannel _channel;
  final bool _supported;
  final StreamController<void> _cancels = StreamController<void>.broadcast();
  var _handlerAttached = false;

  @override
  Stream<void> get cancelRequests {
    _ensureHandler();
    return _cancels.stream;
  }

  void _ensureHandler() {
    if (!_supported || _handlerAttached) return;
    _handlerAttached = true;
    try {
      _channel.setMethodCallHandler(_handleCall);
    } on Object {
      // No Flutter services binding initialized (pure unit tests).
      _handlerAttached = false;
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'cancel' && !_cancels.isClosed) {
      _cancels.add(null);
    }
  }

  @override
  Future<void> start({required String title, int? progress}) =>
      _invoke('start', {'title': title, 'progress': progress});

  @override
  Future<void> update({required String title, int? progress}) =>
      _invoke('update', {'title': title, 'progress': progress});

  @override
  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!_supported) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side (unit tests or non-Android host).
    } on PlatformException {
      // Best-effort foreground notification: never fail the download itself.
    }
  }
}

/// Reference-counted coordinator that keeps Android's foreground download
/// service running while one or more large model downloads are in flight.
final class DownloadForegroundCoordinator {
  new({DownloadForegroundService? service})
    : _service = service ?? MethodChannelDownloadForegroundService() {
    _cancelSubscription = _service.cancelRequests.listen((_) {
      for (final entry in [..._active.values]) {
        unawaited(entry.onCancel?.call());
      }
    });
  }

  /// App-wide singleton (replaceable in tests).
  static DownloadForegroundCoordinator instance =
      DownloadForegroundCoordinator();

  final DownloadForegroundService _service;
  late final StreamSubscription<void> _cancelSubscription;
  final Map<int, _ActiveDownload> _active = {};
  var _nextId = 1;
  int? _lastPercent;

  /// Number of downloads currently tracked.
  int get activeCount => _active.length;

  /// Runs [run] while keeping the Android foreground service alive.
  ///
  /// The `report` callback updates the notification's progress (throttled to
  /// whole percent steps). Tapping **Cancel** in the notification calls
  /// [onCancel] on every tracked download.
  Future<T> track<T>({
    required String label,
    required Future<T> Function(void Function(double? fraction) report) run,
    Future<void> Function()? onCancel,
  }) async {
    final id = _nextId++;
    final first = _active.isEmpty;
    _active[id] = _ActiveDownload(label: label, onCancel: onCancel);
    if (first) {
      _lastPercent = null;
      unawaited(_service.start(title: _currentTitle()));
    } else {
      unawaited(_service.update(title: _currentTitle(), progress: _average()));
    }

    void report(double? fraction) {
      final entry = _active[id];
      if (entry == null) return;
      entry.fraction = fraction?.clamp(0.0, 1.0);
      final percent = _average();
      if (percent == _lastPercent) return;
      _lastPercent = percent;
      unawaited(_service.update(title: _currentTitle(), progress: percent));
    }

    try {
      return await run(report);
    } finally {
      _active.remove(id);
      if (_active.isEmpty) {
        _lastPercent = null;
        unawaited(_service.stop());
      } else {
        final percent = _average();
        _lastPercent = percent;
        unawaited(_service.update(title: _currentTitle(), progress: percent));
      }
    }
  }

  String _currentTitle() {
    if (_active.length == 1) return _active.values.first.label;
    return '${_active.values.first.label} (+${_active.length - 1})';
  }

  int? _average() {
    var sum = 0.0;
    var count = 0;
    for (final entry in _active.values) {
      final f = entry.fraction;
      if (f != null) {
        sum += f;
        count++;
      }
    }
    if (count == 0) return null;
    return ((sum / count) * 100).floor().clamp(0, 100);
  }

  Future<void> dispose() => _cancelSubscription.cancel();
}

final class _ActiveDownload {
  new({required this.label, this.onCancel});

  final String label;
  final Future<void> Function()? onCancel;
  double? fraction;
}
