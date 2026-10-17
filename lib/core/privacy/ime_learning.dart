import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Whether keyboards may learn from what is typed in a text field built
/// with [context]: false while incognito ([AppSettings.incognito]) is on,
/// true otherwise and when no [SettingsCubit] is provided above [context].
///
/// Pass it as `TextField.enableIMEPersonalizedLearning` (Android sends
/// `IME_FLAG_NO_PERSONALIZED_LEARNING`; on the web it is ignored). Call it
/// while building: it rebuilds the caller when incognito changes.
bool imeLearningAllowed(BuildContext context) {
  try {
    return !context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.incognito,
    );
  } on ProviderNotFoundException {
    return true;
  }
}
