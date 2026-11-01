import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_download_notices.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show offlineOutcomeMessage;

/// Says, in a snack bar, when an offline-language download failed after
/// the screen that showed it had closed ([OfflineDownloadNotices.failures]):
/// "Couldn't download German", or why (no connection, a full disk, …), so
/// that the user does not take the language for downloaded.
///
/// Mount it below the [MaterialApp] (its `builder`), where the app's
/// [ScaffoldMessenger] and texts are, or pass [messengerKey].
class OfflineDownloadFailureListener extends StatefulWidget {
  const new({required this.child, this.notices, this.messengerKey, super.key});

  final Widget child;

  /// The notices to listen to (default: [OfflineDownloadNotices.instance]).
  final OfflineDownloadNotices? notices;

  /// The messenger to show the message with (default: the nearest one).
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  /// How long the message stays.
  static const messageDuration = Duration(seconds: 10);

  @override
  State<OfflineDownloadFailureListener> createState() =>
      _OfflineDownloadFailureListenerState();
}

class _OfflineDownloadFailureListenerState
    extends State<OfflineDownloadFailureListener> {
  late final StreamSubscription<OfflineModelOutcome> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = (widget.notices ?? OfflineDownloadNotices.instance).failures
        .listen(_show);
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  void _show(OfflineModelOutcome outcome) {
    if (!mounted) return;
    final messenger =
        widget.messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = messenger.context.l10n;
    messenger.showSnackBar(
      SnackBar(
        key: Key('offline_download_failed_${outcome.language.code}'),
        content: Text(offlineOutcomeMessage(l10n, outcome)),
        showCloseIcon: true,
        duration: OfflineDownloadFailureListener.messageDuration,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
