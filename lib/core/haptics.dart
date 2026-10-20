import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Haptic feedback that follows the user's choice
/// ([AppSettings.hapticFeedback]).
///
/// Use these instead of calling [HapticFeedback] directly. They read the
/// setting from the [SettingsCubit] above `context` and fall back to the
/// default (on) without one, so widgets used outside the app (tests,
/// previews) keep working.
abstract final class Haptics {
  /// Whether haptic feedback is on for widgets built with [context].
  static bool enabled(BuildContext context) {
    try {
      return context.read<SettingsCubit>().state.hapticFeedback;
    } on ProviderNotFoundException {
      return const AppSettings().hapticFeedback;
    }
  }

  /// A tick for a change of selection (e.g. swapping the languages).
  static void selection(BuildContext context) {
    if (enabled(context)) unawaited(HapticFeedback.selectionClick());
  }

  /// A light tap for a button press (translate, copy, favourite).
  static void light(BuildContext context) {
    if (enabled(context)) unawaited(HapticFeedback.lightImpact());
  }
}
