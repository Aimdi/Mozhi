import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/app_shell.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Keeps the web app's offline copy ([AppShell]) as "Keep the web app for
/// offline use" says (`AppSettings.offlineAppShell`), provides the
/// [AppShell] below (the settings show its status), and says once, in a
/// snack bar, when an update is ready: "Update ready" with **Reload**
/// ([AppShell.applyUpdate]).
///
/// Mount it below the [MaterialApp] (its `builder`), where the app's
/// [ScaffoldMessenger] and texts are, or pass [messengerKey]. Does nothing
/// outside a browser.
class AppShellScope extends StatefulWidget {
  const new({required this.child, this.shell, this.messengerKey, super.key});

  final Widget child;

  /// The shell (default: [AppShell.instance]).
  final AppShell? shell;

  /// The messenger to show the notice with (default: the nearest one).
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  /// How long the update notice stays (it does not block other messages).
  static const noticeDuration = Duration(seconds: 12);

  @override
  State<AppShellScope> createState() => _AppShellScopeState();
}

class _AppShellScopeState extends State<AppShellScope> {
  late final AppShell _shell = widget.shell ?? AppShell.instance;
  late final StreamSubscription<AppShellStatus> _status;
  bool _noticeShown = false;

  @override
  void initState() {
    super.initState();
    final enabled = context.read<SettingsCubit>().state.offlineAppShell;
    unawaited(_shell.setEnabled(enabled: enabled));
    _status = _shell.status.listen(_onStatus);
  }

  @override
  void dispose() {
    unawaited(_status.cancel());
    super.dispose();
  }

  void _onStatus(AppShellStatus status) {
    if (status != AppShellStatus.updateReady || _noticeShown || !mounted) {
      return;
    }
    final messenger =
        widget.messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _noticeShown = true;
    final l10n = messenger.context.l10n;
    messenger.showSnackBar(
      SnackBar(
        key: const Key('app_shell_update_ready'),
        content: Text(l10n.appShellUpdateReady),
        // Gone after a while: an update can wait, other messages should not.
        persist: false,
        duration: AppShellScope.noticeDuration,
        showCloseIcon: true,
        action: SnackBarAction(
          label: l10n.appShellReload,
          onPressed: () => unawaited(_shell.applyUpdate()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepositoryProvider<AppShell>.value(
      value: _shell,
      child: BlocListener<SettingsCubit, AppSettings>(
        listenWhen: (previous, current) =>
            previous.offlineAppShell != current.offlineAppShell,
        listener: (context, settings) =>
            unawaited(_shell.setEnabled(enabled: settings.offlineAppShell)),
        child: widget.child,
      ),
    );
  }
}

/// The [AppShell] provided by an [AppShellScope] above, else
/// [AppShell.instance].
AppShell appShellOf(BuildContext context) {
  try {
    return context.read<AppShell>();
  } on ProviderNotFoundException {
    return AppShell.instance;
  }
}
