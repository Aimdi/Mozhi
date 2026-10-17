import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/privacy_channel.dart';

/// Copies text the user asked to copy, marked as sensitive where the
/// platform supports it.
///
/// On Android 13+ the clip carries `ClipDescription.EXTRA_IS_SENSITIVE`, so
/// the system's copy confirmation and keyboard clipboard suggestions don't
/// show its content. Elsewhere (older Android, the web, a missing platform
/// side) it falls back to [Clipboard.setData].
///
/// Android 13+ also confirms every copy itself
/// ([systemShowsCopyConfirmation]); callers then skip their own "Copied"
/// message.
class ClipboardService {
  new({
    MethodChannel? channel,
    bool? isAndroid,
    Future<void> Function(ClipboardData data)? setData,
  }) : _channel = channel ?? privacyChannel(),
       _isAndroid = isAndroid ?? runsOnAndroid,
       _setData = setData ?? Clipboard.setData;

  /// Used by [copyText] and [systemShowsCopyConfirmation].
  static ClipboardService instance = ClipboardService();

  final MethodChannel _channel;
  final bool _isAndroid;
  final Future<void> Function(ClipboardData data) _setData;

  /// Whether the platform channel marks copies as sensitive; null until
  /// the first [copyText] on Android finds out.
  bool? _sensitiveCopies;

  /// Whether the system shows its own confirmation for every copy (Android
  /// 13+), so the app should not show a "Copied" message too.
  ///
  /// Known once [copyText] has completed on this platform (false before):
  /// check it after awaiting [copyText].
  bool get systemShowsCopyConfirmation => _sensitiveCopies ?? false;

  /// Puts [text] on the clipboard (see the class docs). Throws what
  /// [Clipboard.setData] throws.
  Future<void> copyText(String text) async {
    if (_isAndroid && _sensitiveCopies != false) {
      try {
        final copied = await _channel.invokeMethod<bool>(
          'copySensitiveText',
          text,
        );
        _sensitiveCopies = copied ?? false;
        if (_sensitiveCopies!) return;
      } on MissingPluginException {
        _sensitiveCopies = false;
      } on PlatformException {
        // Copied below instead; try the channel again next time.
      }
    }
    await _setData(ClipboardData(text: text));
  }
}

/// Copies [text] with [ClipboardService.instance] (see
/// [ClipboardService.copyText]).
Future<void> copyText(String text) => ClipboardService.instance.copyText(text);

/// Whether the system confirms copies itself (see
/// [ClipboardService.systemShowsCopyConfirmation]).
bool get systemShowsCopyConfirmation =>
    ClipboardService.instance.systemShowsCopyConfirmation;
