import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// "How private should translations be?": the three privacy modes in plain
/// language (Offline only / Offline first, recommended / Online), saved
/// with `SettingsCubit.setPrivacyMode` as soon as one is picked.
///
/// Where the device has no on-device engine (the web), Offline only says
/// that it would leave nothing to translate with.
class PrivacyStep extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = context.select<SettingsCubit, PrivacyMode>(
      (cubit) => cubit.state.privacyMode,
    );
    final onDevice = _hasOfflineEngine(context);
    final options = [
      (
        PrivacyMode.offlineOnly,
        Icons.phone_android,
        l10n.onboardingPrivacyOfflineOnly,
        onDevice
            ? l10n.onboardingPrivacyOfflineOnlyBody
            : '${l10n.onboardingPrivacyOfflineOnlyBody} '
                  '${l10n.onboardingPrivacyNoOfflineEngine}',
      ),
      (
        PrivacyMode.offlineFirst,
        Icons.shield_outlined,
        l10n.onboardingPrivacyOfflineFirst,
        l10n.onboardingPrivacyOfflineFirstBody,
      ),
      (
        PrivacyMode.online,
        Icons.public,
        l10n.onboardingPrivacyOnline,
        l10n.onboardingPrivacyOnlineBody,
      ),
    ];
    return OnboardingStepLayout(
      icon: Icons.privacy_tip_outlined,
      title: l10n.onboardingPrivacyTitle,
      subtitle: l10n.onboardingPrivacySubtitle,
      children: [
        Semantics(
          container: true,
          explicitChildNodes: true,
          label: l10n.onboardingPrivacyGroup,
          child: RadioGroup<PrivacyMode>(
            groupValue: mode,
            onChanged: (value) {
              if (value != null) {
                context.read<OnboardingCubit>().setPrivacyMode(value);
              }
            },
            child: Column(
              children: [
                for (final (value, icon, title, body) in options)
                  RadioListTile<PrivacyMode>(
                    key: Key('onboarding_privacy_${value.name}'),
                    value: value,
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(icon),
                    title: Text(title),
                    subtitle: Text(body),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static bool _hasOfflineEngine(BuildContext context) {
    try {
      return context.read<TranslationRepository>().hasOfflineEngine;
    } on Object {
      // No repository (or a test double): assume the device has one.
      return true;
    }
  }
}
