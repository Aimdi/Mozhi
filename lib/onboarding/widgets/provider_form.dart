import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:translation_repository/translation_repository.dart';

/// Example address for a local [preset] reached from another device:
/// its default URL with the host replaced by a typical LAN IP.
String lanExample(AiProviderPreset preset) {
  final uri = Uri.tryParse(preset.baseUrl);
  if (uri == null || uri.host.isEmpty) return 'http://192.168.1.20:11434';
  return uri.replace(host: '192.168.1.20').toString();
}

/// Key, address and model of the selected preset, with Test and Save.
/// Values live in the [OnboardingCubit]; this widget only mirrors them in
/// text fields (initialised once, so key it by the preset id).
class ProviderForm extends StatefulWidget {
  const new({super.key});

  @override
  State<ProviderForm> createState() => _ProviderFormState();
}

class _ProviderFormState extends State<ProviderForm> {
  final _apiKey = TextEditingController();
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _sync(context.read<OnboardingCubit>().state);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Copies the cubit's draft into the text fields.
  void _sync(OnboardingState state) {
    _apiKey.text = state.apiKey;
    _baseUrl.text = state.baseUrl;
    _model.text = state.model;
  }

  void _pickModel(String model) {
    _model.text = model;
    context.read<OnboardingCubit>().updateProviderDraft(model: model);
  }

  String? _errorText(AppLocalizations l10n, ProviderFieldError? error) =>
      switch (error) {
        null => null,
        ProviderFieldError.required => l10n.onboardingAiRequired,
        ProviderFieldError.invalidUrl => l10n.onboardingAiUrlInvalid,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<OnboardingCubit>();
    final state = context.watch<OnboardingCubit>().state;
    final preset = state.preset;
    if (preset == null) return const SizedBox.shrink();
    final apiKeyUrl = preset.apiKeyUrl;
    final models = {...preset.suggestedModels, ...state.models}.take(16);
    final loadingModels = state.modelsStatus == ProviderTestStatus.running;
    final testing = state.testStatus == ProviderTestStatus.running;
    final saved = state.savedDraft;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(preset.name, style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 16),
            if (state.showsApiKey) ...[
              TextField(
                key: const Key('onboarding-api-key'),
                controller: _apiKey,
                obscureText: _obscureKey,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: preset.requiresApiKey
                      ? l10n.onboardingAiApiKey
                      : l10n.onboardingAiApiKeyOptional,
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: const OutlineInputBorder(),
                  helperText: l10n.onboardingAiKeyStorage,
                  errorText: _errorText(
                    l10n,
                    state.errorFor(ProviderField.apiKey),
                  ),
                  suffixIcon: IconButton(
                    tooltip: _obscureKey
                        ? l10n.onboardingAiShowKey
                        : l10n.onboardingAiHideKey,
                    icon: Icon(
                      _obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                onChanged: (value) => cubit.updateProviderDraft(apiKey: value),
              ),
              if (apiKeyUrl != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () =>
                        LinkLauncher.open(context, Uri.parse(apiKeyUrl)),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.onboardingAiGetKey),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            if (state.needsBaseUrl) ...[
              TextField(
                key: const Key('onboarding-base-url'),
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.onboardingAiBaseUrl,
                  hintText: preset.baseUrl.isEmpty
                      ? l10n.onboardingAiBaseUrlHint
                      : preset.baseUrl,
                  helperText: preset.isLocal
                      ? l10n.onboardingAiLanHint(lanExample(preset))
                      : null,
                  helperMaxLines: 3,
                  prefixIcon: const Icon(Icons.dns_outlined),
                  border: const OutlineInputBorder(),
                  errorText: _errorText(
                    l10n,
                    state.errorFor(ProviderField.baseUrl),
                  ),
                ),
                onChanged: (value) => cubit.updateProviderDraft(baseUrl: value),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const Key('onboarding-model'),
              controller: _model,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.onboardingAiModel,
                prefixIcon: const Icon(Icons.memory_outlined),
                border: const OutlineInputBorder(),
                errorText: _errorText(
                  l10n,
                  state.errorFor(ProviderField.model),
                ),
                suffixIcon: loadingModels
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: l10n.onboardingAiLoadModels,
                        icon: const Icon(Icons.manage_search),
                        onPressed: cubit.loadModels,
                      ),
              ),
              onChanged: (value) => cubit.updateProviderDraft(model: value),
            ),
            if (state.modelsStatus == ProviderTestStatus.failure) ...[
              const SizedBox(height: 8),
              Text(
                l10n.onboardingAiModelsFailed(
                  state.modelsError ?? l10n.onboardingServiceTimedOut,
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
            if (models.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final model in models)
                    ChoiceChip(
                      label: Text(model),
                      selected: state.model.trim() == model,
                      onSelected: (_) => _pickModel(model),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 48),
                  ),
                  onPressed: testing ? null : cubit.testProvider,
                  icon: testing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_outlined),
                  label: Text(
                    testing ? l10n.onboardingAiTesting : l10n.onboardingAiTest,
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 48),
                  ),
                  onPressed: saved != null ? null : cubit.saveProvider,
                  icon: Icon(saved != null ? Icons.check : Icons.save_outlined),
                  label: Text(l10n.onboardingAiSave),
                ),
              ],
            ),
            if (state.testStatus == ProviderTestStatus.success) ...[
              const SizedBox(height: 16),
              OnboardingNote(
                icon: Icons.check_circle_outline,
                text: l10n.onboardingAiTestOk(state.testOutput ?? ''),
                background: colors.onboardingSuccess.withValues(alpha: 0.12),
                foreground: colors.onboardingSuccess,
              ),
            ],
            if (state.testStatus == ProviderTestStatus.failure) ...[
              const SizedBox(height: 16),
              OnboardingNote(
                icon: Icons.error_outline,
                text: state.testError == null
                    ? l10n.onboardingAiTestTimedOut
                    : l10n.onboardingAiTestFailed(state.testError!),
                background: colors.errorContainer,
                foreground: colors.onErrorContainer,
              ),
            ],
            if (saved != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: OnboardingNote(
                  icon: Icons.task_alt,
                  text: l10n.onboardingAiSaved(saved.name),
                  background: colors.primaryContainer,
                  foreground: colors.onPrimaryContainer,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
