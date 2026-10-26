import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The app's [AppLock] (`RepositoryProvider<AppLock>`), or null where none
/// is provided (tests).
AppLock? maybeAppLock(BuildContext context) {
  try {
    return context.read<AppLock>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// "Off", "Immediately", "After 5 minutes" for [timeout].
String appLockTimeoutLabel(AppLocalizations l10n, AppLockTimeout timeout) =>
    switch (timeout) {
      AppLockTimeout.off => l10n.settingsAppLockOff,
      AppLockTimeout.immediately => l10n.settingsAppLockImmediately,
      _ => l10n.settingsAppLockAfterMinutes(timeout.delay!.inMinutes),
    };

/// Whether this platform has an app lock at all (the Android app).
bool get appLockSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// "App lock" in Settings > Privacy & data: when Mozhi asks for the
/// phone's biometrics or screen lock ([AppLockTimeout]).
///
/// Disabled, with the reason, on the web and where the phone has no
/// secure lock screen (checked again whenever the app comes back, e.g.
/// from setting one up). Turning the lock on needs one successful unlock
/// first ([AppLockController.confirm]), so nobody locks themselves out;
/// changing the time or turning it off does not.
class AppLockSettingsTile extends StatefulWidget {
  const new({required this.timeout, super.key});

  /// The current setting ([AppSettings.appLock]).
  final AppLockTimeout timeout;

  /// The settings search's anchor of this row.
  static const anchor = 'app_lock';

  @override
  State<AppLockSettingsTile> createState() => _AppLockSettingsTileState();
}

class _AppLockSettingsTileState extends State<AppLockSettingsTile> {
  AppLockController? _lock;

  /// Whether the lock can be used; null until the platform said. Known at
  /// once where there is none, so the row never changes its height then.
  bool? _available;
  int _checks = 0;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lock = switch (maybeAppLock(context)) {
      final AppLockController lock => lock,
      _ => null,
    };
    if (lock != _lock || _checks == 0) {
      _lock = lock;
      _available = appLockSupported ? lock?.lastKnownAvailable : false;
      _refresh();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Asks the platform again (also when the app comes back: the user may
  /// have set a screen lock meanwhile).
  void _refresh() {
    final check = ++_checks;
    final lock = _lock;
    if (!appLockSupported || lock == null) {
      if (_available != false && mounted) setState(() => _available = false);
      return;
    }
    unawaited(
      lock.isAvailable().then((available) {
        if (!mounted || check != _checks || available == _available) return;
        setState(() => _available = available);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final available = _available ?? false;
    final subtitle = switch (_available) {
      true || null => appLockTimeoutLabel(l10n, widget.timeout),
      false when !appLockSupported => l10n.settingsAppLockUnsupported,
      false => l10n.settingsAppLockNoScreenLock,
    };
    return ListTile(
      key: const Key('settings_app_lock'),
      leading: const SettingsIcon(Icons.lock_outline),
      title: Text(l10n.settingsAppLock),
      subtitle: Text(subtitle),
      trailing: available ? const Icon(Icons.chevron_right) : null,
      enabled: available,
      onTap: available ? () => unawaited(_choose(context)) : null,
    );
  }

  Future<void> _choose(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final lock = _lock;
    final current = widget.timeout;
    final choice = await showDialog<AppLockTimeout>(
      context: context,
      builder: (context) => ChoiceDialog<AppLockTimeout>(
        title: l10n.settingsAppLock,
        body: l10n.settingsAppLockDialogBody,
        initialValue: current,
        options: [
          for (final timeout in AppLockTimeout.values)
            ChoiceDialogOption(
              value: timeout,
              title: Text(appLockTimeoutLabel(l10n, timeout)),
            ),
        ],
      ),
    );
    if (choice == null || choice == current || lock == null) return;
    // One successful unlock before the lock goes on.
    if (!current.isOn && choice.isOn && !await lock.confirm()) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.settingsAppLockNotTurnedOn)),
      );
      return;
    }
    cubit.setAppLock(choice);
  }
}
