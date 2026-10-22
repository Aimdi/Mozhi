import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';

/// Says, in a snackbar, when the settings could not be saved
/// ([SettingsCubit.saveFailures]): "Couldn't save your settings", or that
/// an API key could not be stored securely. The change itself stays in
/// effect until the app closes.
///
/// One message per burst of failures: settings are saved after every
/// change (each step of a slider, every translation's language pair), so
/// failures that follow each other within [burstGap] are told once. A
/// secret that could not be stored is still told during a burst of other
/// failures, once.
///
/// Mount it below the [MaterialApp] (its `builder`), where the app's
/// [ScaffoldMessenger] and texts are, or pass [messengerKey].
class SettingsSaveFailureListener extends StatefulWidget {
  const new({
    required this.child,
    this.messengerKey,
    this.burstGap = const Duration(seconds: 30),
    super.key,
  });

  final Widget child;

  /// The messenger to show the message with (default: the nearest one).
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  /// How long after a failure another one still belongs to its burst.
  final Duration burstGap;

  /// How long the message stays.
  static const messageDuration = Duration(seconds: 8);

  @override
  State<SettingsSaveFailureListener> createState() =>
      _SettingsSaveFailureListenerState();
}

class _SettingsSaveFailureListenerState
    extends State<SettingsSaveFailureListener> {
  /// On the app's [SettingsCubit], which lives as long as the app.
  late final StreamSubscription<SettingsSaveFailure> _subscription;

  /// Runs while a burst lasts; every failure restarts it.
  Timer? _burst;

  /// The failures told during the current burst.
  final Set<SettingsSaveFailure> _told = {};

  @override
  void initState() {
    super.initState();
    _subscription = context.read<SettingsCubit>().saveFailures.listen(
      _onFailure,
    );
  }

  @override
  void dispose() {
    _burst?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }

  void _onFailure(SettingsSaveFailure failure) {
    final quiet = _burst?.isActive ?? false;
    _burst?.cancel();
    _burst = Timer(widget.burstGap, _told.clear);
    if (!quiet) _told.clear();
    if (!_told.add(failure)) return;
    // A secret told already covers the settings failures around it.
    if (failure == SettingsSaveFailure.settings &&
        _told.contains(SettingsSaveFailure.secret)) {
      return;
    }
    _show(failure);
  }

  void _show(SettingsSaveFailure failure) {
    if (!mounted) return;
    final messenger =
        widget.messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = messenger.context.l10n;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: Key('settings_save_failed_${failure.name}'),
          content: Text(switch (failure) {
            SettingsSaveFailure.settings => l10n.settingsSaveFailed,
            SettingsSaveFailure.secret => l10n.settingsSaveSecretFailed,
          }),
          showCloseIcon: true,
          duration: SettingsSaveFailureListener.messageDuration,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
