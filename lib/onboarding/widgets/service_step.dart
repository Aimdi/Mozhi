import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/instance_tile.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:translation_repository/translation_repository.dart';

/// Step 3: find the fastest public Mozhi instance or add your own.
class ServiceStep extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingStepLayout(
      icon: Icons.dns_outlined,
      title: l10n.onboardingServiceTitle,
      subtitle: l10n.onboardingServiceBody,
      children: const [
        _FindFastest(),
        SizedBox(height: 8),
        _InstanceList(),
        SizedBox(height: 24),
        OwnInstanceForm(),
      ],
    );
  }
}

class _FindFastest extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<OnboardingCubit>();
    final status = context.select<OnboardingCubit, ServiceStatus>(
      (c) => c.state.serviceStatus,
    );
    final sortBySpeed = context.select<OnboardingCubit, bool>(
      (c) => c.state.sortBySpeed,
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
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: pinging ? null : cubit.findFastestInstance,
          icon: Icon(
            status == ServiceStatus.done ? Icons.refresh : Icons.speed,
          ),
          label: Text(switch (status) {
            ServiceStatus.idle => l10n.onboardingServiceFindFastest,
            ServiceStatus.pinging => l10n.onboardingServiceTesting,
            ServiceStatus.done => l10n.onboardingServiceTestAgain,
          }),
        ),
        if (pinging) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: progress,
            semanticsLabel: l10n.onboardingServiceTesting,
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingServiceSortBySpeed),
          subtitle: Text(l10n.onboardingServiceSortBySpeedHint),
          value: sortBySpeed,
          onChanged: (enabled) => cubit.setSortBySpeed(enabled: enabled),
        ),
      ],
    );
  }
}

class _InstanceList extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final cubit = context.read<OnboardingCubit>();
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (c) => c.state.instances,
    );
    final state = context.watch<OnboardingCubit>().state;
    final fastest = state.fastestUrl;
    if (instances.isEmpty) {
      return OnboardingNote(
        icon: Icons.info_outline,
        text: l10n.onboardingServiceEmpty,
      );
    }
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppPalette.of(context).hairline),
          ),
          child: RadioGroup<String>(
            // The first instance is the preferred one.
            groupValue: instances.first.url,
            onChanged: (url) {
              if (url != null) cubit.selectInstance(url);
            },
            child: Column(
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
          ),
        ),
      ],
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

  /// The plain-http URL the user agreed to add without encryption.
  String? _insecureConfirmedFor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Uri? get _insecureUri {
    final uri = normalizeOwnInstanceUrl(_controller.text);
    return isInsecureHttp(uri) ? uri : null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final cubit = context.read<OnboardingCubit>();
    final insecure = _insecureUri;
    if (insecure != null && !await _confirmInsecure(insecure)) return;
    await cubit.addOwnInstance(
      _controller.text,
      allowInsecure: insecure != null,
    );
  }

  /// Asks once per URL before a plain-http instance outside the local
  /// network is added (same dialog as Settings); true when it may be added.
  Future<bool> _confirmInsecure(Uri uri) async {
    final url = uri.toString();
    if (_insecureConfirmedFor == url) return true;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.no_encryption_outlined),
        title: Text(l10n.settingsInstanceInsecureConfirmTitle),
        content: Text(l10n.settingsInstanceInsecureConfirmBody(uri.host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsInstanceInsecureConfirmAction),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return false;
    _insecureConfirmedFor = url;
    return true;
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
      OwnInstanceError.insecure => l10n.onboardingServiceOwnInsecure,
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
              text: l10n.settingsInstanceInsecureWarning,
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
