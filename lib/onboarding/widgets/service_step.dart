import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/network/network.dart' show isCleartextAllowed;
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/instance_tile.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:translation_repository/translation_repository.dart';

/// The last step: the online service. On a device that translates on its
/// own it is for the languages that are not on the device ("Optional");
/// where the device can't (the web) it is how Mozhi translates, so the
/// badge is left out and a switch keeps the privacy choice ("Ask before
/// sending text", off: [PrivacyMode.online], see `OnboardingCubit`).
///
/// One row says which server is used ("Using mozhi.example · Change"); the
/// bundled public Mozhi instances (run by volunteers) are behind
/// "Change". "Find the fastest server" measures them, but only when
/// tapped: it contacts every listed server, so it is never automatic.
/// Then the user's own instance, and a note that AI providers can be
/// added in the settings ([onOpenAiSettings] opens them).
class ServiceStep extends StatelessWidget {
  const new({this.onOpenAiSettings, super.key});

  /// Finishes the onboarding and opens the AI provider settings; without
  /// it the note has no link.
  final VoidCallback? onOpenAiSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final offlineOnly = context.select<SettingsCubit, bool>(
      (c) => c.state.privacyMode == PrivacyMode.offlineOnly,
    );
    final onDevice = context.select<OnboardingCubit, bool>(
      (c) => c.state.onDevice,
    );
    return OnboardingStepLayout(
      icon: Icons.dns_outlined,
      title: l10n.onboardingOnlineTitle,
      titleTrailing: onDevice
          ? OnboardingBadge(
              label: l10n.onboardingAiOptional,
              color: colors.secondary,
            )
          : null,
      subtitle: onDevice
          ? l10n.onboardingServiceBody
          : l10n.onboardingServiceBodyNoDevice,
      children: [
        if (offlineOnly) ...[
          OnboardingNote(
            key: const Key('onboarding_service_offline_only'),
            icon: Icons.wifi_off_outlined,
            text: l10n.onboardingOnlineOfflineOnly,
            background: colors.secondaryContainer,
            foreground: colors.onSecondaryContainer,
          ),
          const SizedBox(height: 16),
        ],
        if (!onDevice) ...[
          const _AskBeforeSending(),
          const SizedBox(height: 8),
        ],
        const ServerChoice(),
        const SizedBox(height: 24),
        const OwnInstanceForm(),
        _AiLater(onOpenAiSettings: onOpenAiSettings),
      ],
    );
  }
}

/// "Ask before sending text" on a device without an on-device engine: the
/// privacy step's choice in one switch (on: Offline first, off: Online).
class _AskBeforeSending extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ask = context.select<SettingsCubit, bool>(
      (c) => c.state.privacyMode != PrivacyMode.online,
    );
    return SwitchListTile(
      key: const Key('onboarding_ask_before_sending'),
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Icons.shield_outlined),
      title: Text(l10n.onboardingServiceAskFirst),
      subtitle: Text(l10n.onboardingServiceAskFirstBody),
      value: ask,
      onChanged: (value) =>
          context.read<OnboardingCubit>().setAskBeforeSending(ask: value),
    );
  }
}

/// The server Mozhi uses first, in one row: "Using mozhi.example" with its
/// address (and its speed once measured), "Change" opening the list of
/// the configured instances to pick another
/// ([OnboardingCubit.selectInstance]), and below it "Find the fastest
/// server" ([OnboardingCubit.findFastestInstance], which also orders the
/// list by speed): a one-tap action that says it contacts every listed
/// server.
class ServerChoice extends StatefulWidget {
  const new({super.key});

  @override
  State<ServerChoice> createState() => _ServerChoiceState();
}

class _ServerChoiceState extends State<ServerChoice> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (c) => c.state.instances,
    );
    final state = context.watch<OnboardingCubit>().state;
    if (instances.isEmpty) {
      return OnboardingNote(
        icon: Icons.info_outline,
        text: l10n.onboardingServiceEmpty,
      );
    }
    final first = instances.first;
    final host = Uri.tryParse(first.url)?.host ?? first.url;
    final ping = state.pings[first.url];
    final fastest =
        state.serviceStatus == ServiceStatus.done &&
        first.url == state.fastestUrl;
    // Its rows are controls: the control outline (3:1).
    final shape = RoundedRectangleBorder(
      borderRadius: AppRadius.cardBorderRadius,
      side: BorderSide(color: colors.outline),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.noneReachable) ...[
          OnboardingNote(
            icon: Icons.wifi_off,
            text: l10n.onboardingServiceNoneReachable,
            background: colors.errorContainer,
            foreground: colors.onErrorContainer,
          ),
          const SizedBox(height: 12),
        ],
        Card.outlined(
          margin: EdgeInsets.zero,
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          shape: shape,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                key: const Key('onboarding_server_row'),
                leading: Icon(
                  first.isCustom ? Icons.dns_outlined : Icons.public,
                  color: colors.primary,
                ),
                title: Text(
                  l10n.onboardingServiceUsing(first.displayName),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (first.displayName != host)
                      Text(host, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (ping != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: PingIndicator(
                          ping: ping,
                          isFastest: fastest,
                          inline: true,
                        ),
                      ),
                  ],
                ),
                trailing: TextButton(
                  key: const Key('onboarding_server_change'),
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: () => setState(() => _open = !_open),
                  // On the button's own node: it shows and hides the list.
                  child: Semantics(
                    expanded: _open,
                    child: Text(
                      _open
                          ? l10n.onboardingServiceChangeDone
                          : l10n.onboardingServiceChange,
                    ),
                  ),
                ),
              ),
              if (_open) ...[const Hairline(), const _InstanceList()],
              const Hairline(),
              const _FindFastest(),
            ],
          ),
        ),
      ],
    );
  }
}

/// "AI translators are optional…" with a link to the AI provider settings.
class _AiLater extends StatelessWidget {
  const new({required this.onOpenAiSettings});

  final VoidCallback? onOpenAiSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Hairline(),
        const SizedBox(height: 8),
        OnboardingInfoRow(
          icon: Icons.auto_awesome_outlined,
          text: l10n.onboardingAiLaterSettings,
        ),
        if (onOpenAiSettings case final open?)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: TextButton.icon(
              key: const Key('onboarding_open_ai_settings'),
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: open,
              icon: const Icon(Icons.arrow_forward),
              iconAlignment: IconAlignment.end,
              label: Text(l10n.onboardingAiOpenSettings),
            ),
          ),
      ],
    );
  }
}

/// "Find the fastest server": measures every configured instance (only
/// when tapped, as its subtitle says) and puts the fastest first, the
/// others in order of speed; a bar shows the progress, then it offers to
/// measure again.
class _FindFastest extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final cubit = context.read<OnboardingCubit>();
    final status = context.select<OnboardingCubit, ServiceStatus>(
      (c) => c.state.serviceStatus,
    );
    final progress = context.select<OnboardingCubit, double>((c) {
      final pings = c.state.pings.values;
      if (pings.isEmpty) return 0.0;
      final done = pings.where((p) => p.status != PingStatus.pending).length;
      return done / pings.length;
    });
    final pinging = status == ServiceStatus.pinging;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const Key('onboarding_find_fastest'),
          enabled: !pinging,
          leading: Icon(Icons.speed, color: colors.primary),
          title: Text(switch (status) {
            ServiceStatus.idle => l10n.onboardingServiceFindFastestTitle,
            ServiceStatus.pinging => l10n.onboardingServiceTesting,
            ServiceStatus.done => l10n.onboardingServiceTestAgain,
          }),
          subtitle: Text(l10n.onboardingServiceFindFastestHint),
          trailing: status == ServiceStatus.done
              ? const Icon(Icons.refresh)
              : null,
          onTap: pinging ? null : cubit.findFastestInstance,
        ),
        if (pinging)
          LinearProgressIndicator(
            value: progress,
            semanticsLabel: l10n.onboardingServiceTesting,
          ),
      ],
    );
  }
}

/// The configured instances to choose the one used first (behind
/// "Change"), each with its speed once measured.
class _InstanceList extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<OnboardingCubit>();
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (c) => c.state.instances,
    );
    final state = context.watch<OnboardingCubit>().state;
    final fastest = state.fastestUrl;
    return RadioGroup<String>(
      // The first instance is the preferred one.
      groupValue: instances.first.url,
      onChanged: (url) {
        if (url != null) cubit.selectInstance(url);
      },
      child: Column(
        key: const Key('onboarding_instance_list'),
        children: [
          for (final instance in instances)
            InstanceTile(
              key: ValueKey(instance.url),
              instance: instance,
              ping: state.pings[instance.url],
              isFastest:
                  state.serviceStatus == ServiceStatus.done &&
                  instance.url == fastest,
            ),
        ],
      ),
    );
  }
}

/// "Use my own instance": URL field validated and tested by the cubit.
class OwnInstanceForm extends StatefulWidget {
  const new({super.key});

  @override
  State<OwnInstanceForm> createState() => _OwnInstanceFormState();
}

class _OwnInstanceFormState extends State<OwnInstanceForm> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// A plain-http address of a public server: refused (the app only sends
  /// text unencrypted inside this device or the local network).
  Uri? get _insecureUri {
    final uri = normalizeOwnInstanceUrl(_controller.text);
    return uri == null || isCleartextAllowed(uri) ? null : uri;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    await context.read<OnboardingCubit>().addOwnInstance(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<OnboardingCubit>();
    final status = context.select<OnboardingCubit, OwnInstanceStatus>(
      (c) => c.state.ownInstanceStatus,
    );
    final error = context.select<OnboardingCubit, OwnInstanceError?>(
      (c) => c.state.ownInstanceError,
    );
    final message = context.select<OnboardingCubit, String?>(
      (c) => c.state.ownInstanceMessage,
    );
    final latency = context.select<OnboardingCubit, Duration?>(
      (c) => c.state.ownInstanceLatency,
    );
    final testing = status == OwnInstanceStatus.testing;
    final errorText = switch (error) {
      null => null,
      OwnInstanceError.empty => l10n.onboardingServiceOwnEmpty,
      OwnInstanceError.invalidUrl => l10n.onboardingServiceOwnInvalid,
      OwnInstanceError.unreachable => l10n.onboardingServiceOwnFailed(
        message ?? '',
      ),
      OwnInstanceError.timedOut => l10n.onboardingServiceOwnTimedOut,
      OwnInstanceError.insecure => l10n.commonHttpsRequired,
    };
    return OnboardingSection(
      title: l10n.onboardingServiceOwnTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.onboardingServiceOwnBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enableIMEPersonalizedLearning: imeLearningAllowed(context),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              labelText: l10n.onboardingServiceOwnUrl,
              hintText: l10n.onboardingServiceOwnHint,
              prefixIcon: const Icon(Icons.link),
              border: const OutlineInputBorder(),
              errorText: errorText,
              errorMaxLines: 4,
            ),
            onChanged: (_) {
              // Rebuild for the insecure-http banner.
              setState(() {});
              cubit.ownInstanceChanged();
            },
            onSubmitted: testing ? null : (_) => _submit(),
          ),
          if (_insecureUri != null) ...[
            const SizedBox(height: 12),
            InsecureHttpWarning(
              key: const Key('onboarding_insecure_warning'),
              title: l10n.settingsInstanceInsecureTitle,
              text: l10n.commonHttpsRequired,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: testing ? null : _submit,
              icon: testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_link),
              label: Text(l10n.onboardingServiceOwnAdd),
            ),
          ),
          if (status == OwnInstanceStatus.success && latency != null) ...[
            const SizedBox(height: 12),
            OnboardingNote(
              icon: Icons.check_circle_outline,
              text: l10n.onboardingServiceOwnAdded(latency.inMilliseconds),
              background: theme.colorScheme.onboardingSuccess.withValues(
                alpha: 0.12,
              ),
              foreground: theme.colorScheme.onboardingSuccess,
            ),
          ],
        ],
      ),
    );
  }
}
