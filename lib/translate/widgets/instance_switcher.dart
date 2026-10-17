import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The instance Mozhi requests go to now: the one a failover switched to
/// (`TranslationRepository.activeInstance`) when it is still in
/// [instances], else the first.
String? currentInstanceUrl(
  BuildContext context,
  List<MozhiInstance> instances,
) {
  final active = _activeInstanceUrl(context);
  if (active != null && instances.any((i) => i.url == active)) return active;
  return instances.firstOrNull?.url;
}

String? _activeInstanceUrl(BuildContext context) {
  try {
    return context.read<TranslationRepository>().activeInstance?.url;
  } on ProviderNotFoundException {
    return null;
  }
}

/// Lists the configured Mozhi instances (the one in use marked) to
/// translate with another one; the last row opens the instance settings.
/// Resolves to the picked instance's URL (null when dismissed, or the
/// one in use was picked).
Future<String?> showInstanceSwitcher(BuildContext context) {
  final instances = context.read<SettingsCubit>().state.instances;
  final current = currentInstanceUrl(context, instances);
  final router = GoRouter.maybeOf(context);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final l10n = sheetContext.l10n;
      final theme = Theme.of(sheetContext);
      return SingleChildScrollView(
        key: const Key('translate_instance_switcher'),
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Semantics(
                header: true,
                child: Text(
                  l10n.translateSwitchInstanceTitle,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
            for (final instance in instances)
              ListTile(
                key: ValueKey('translate_instance:${instance.url}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(
                  instance.isCustom ? Icons.dns_outlined : Icons.public,
                ),
                title: Text(instance.displayName),
                subtitle: instance.url == current
                    ? Text(l10n.translateSwitchInstanceInUse)
                    : Text(Uri.tryParse(instance.url)?.host ?? instance.url),
                selected: instance.url == current,
                trailing: instance.url == current
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.of(sheetContext)
                        .pop(instance.url == current ? null : instance.url),
              ),
            if (router != null)
              ListTile(
                key: const Key('translate_instance_manage'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.tune),
                title: Text(l10n.translateManageInstances),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  router.go(AppRoutes.instances);
                },
              ),
          ],
        ),
      );
    },
  );
}

/// [showInstanceSwitcher], then (an instance was picked) makes it the
/// preferred one (`SettingsCubit.preferInstance`, which the app hands to
/// the repository) and translates again.
Future<void> switchInstanceAndRetry(BuildContext context) async {
  final settings = context.read<SettingsCubit>();
  final translate = context.read<TranslateCubit>();
  final url = await showInstanceSwitcher(context);
  if (url == null) return;
  settings.preferInstance(url);
  // The app applies the new order to the repository when the settings
  // stream delivers it (a microtask): retry after that.
  await Future<void>.delayed(Duration.zero);
  if (translate.isClosed) return;
  unawaited(translate.translate());
}
