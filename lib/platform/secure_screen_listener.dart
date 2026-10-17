import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/platform/secure_screen.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Whether [current] changes [AppSettings.secureScreen].
bool secureScreenChanged(AppSettings previous, AppSettings current) =>
    previous.secureScreen != current.secureScreen;

/// Applies [AppSettings.secureScreen] to the app's window ("Hide content
/// in recents & block screenshots", Android `FLAG_SECURE`): when inserted
/// (if on) and on every change after that. A no-op where [SecureScreen]
/// is unsupported (the web).
///
/// Reads the [SettingsCubit] from the context; place it below its
/// provider, around the whole app.
class SecureScreenListener extends StatefulWidget {
  const new({required this.child, this.secureScreen, super.key});

  final Widget child;

  /// Defaults to [SecureScreen.instance].
  final SecureScreen? secureScreen;

  @override
  State<SecureScreenListener> createState() => _SecureScreenListenerState();
}

class _SecureScreenListenerState extends State<SecureScreenListener> {
  SecureScreen get _screen => widget.secureScreen ?? SecureScreen.instance;

  @override
  void initState() {
    super.initState();
    if (context.read<SettingsCubit>().state.secureScreen) _apply(enabled: true);
  }

  void _apply({required bool enabled}) =>
      unawaited(_screen.setEnabled(enabled: enabled));

  @override
  Widget build(BuildContext context) {
    return BlocListener<SettingsCubit, AppSettings>(
      listenWhen: secureScreenChanged,
      listener: (context, settings) => _apply(enabled: settings.secureScreen),
      child: widget.child,
    );
  }
}
