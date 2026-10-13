import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the ordered list of Mozhi instances (first = preferred).
class InstancesPage extends StatelessWidget {
  const InstancesPage({super.key});

  @override
  Widget build(BuildContext context) => const InstancesView();
}

/// Result of pinging an instance.
@immutable
sealed class PingStatus {
  const PingStatus();
}

class PingChecking extends PingStatus {
  const PingChecking();
}

class PingOnline extends PingStatus {
  const PingOnline(this.latency);
  final Duration latency;
}

class PingOffline extends PingStatus {
  const PingOffline();
}

class InstancesView extends StatefulWidget {
  const InstancesView({super.key});

  static final mozhiProjectUrl = Uri.parse('https://codeberg.org/aryak/mozhi');

  @override
  State<InstancesView> createState() => _InstancesViewState();
}

enum _InstanceAction { prefer, moveUp, moveDown, remove }

class _InstancesViewState extends State<InstancesView> {
  final Map<String, PingStatus> _pings = {};

  @override
  void initState() {
    super.initState();
    final instances = context.read<SettingsCubit>().state.instances;
    for (final instance in instances) {
      _pings[instance.url] = const PingChecking();
    }
    for (final instance in instances) {
      _ping(instance);
    }
  }

  Future<void> _ping(MozhiInstance instance) async {
    final repository = context.read<TranslationRepository>();
    PingStatus status;
    try {
      status = PingOnline(await repository.pingInstance(instance));
    } on Object {
      status = const PingOffline();
    }
    if (!mounted) return;
    setState(() => _pings[instance.url] = status);
  }

  Future<void> _refresh() {
    final instances = context.read<SettingsCubit>().state.instances;
    setState(() {
      for (final instance in instances) {
        _pings[instance.url] = const PingChecking();
      }
    });
    return Future.wait(instances.map(_ping));
  }

  void _onInstancesChanged(BuildContext context, AppSettings settings) {
    final missing = settings.instances
        .where((i) => !_pings.containsKey(i.url))
        .toList();
    if (missing.isEmpty) return;
    setState(() {
      for (final instance in missing) {
        _pings[instance.url] = const PingChecking();
      }
    });
    missing.forEach(_ping);
  }

  Future<void> _add() async {
    final cubit = context.read<SettingsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final added = context.l10n.settingsInstanceAdded;
    final instance = await showDialog<MozhiInstance>(
      context: context,
      builder: (_) => AddInstanceDialog(
        existingUrls: [for (final i in cubit.state.instances) i.url],
      ),
    );
    if (instance == null) return;
    cubit.addInstance(instance);
    messenger.showSnackBar(SnackBar(content: Text(added)));
  }

  Future<void> _reset() async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restore),
        title: Text(l10n.settingsInstancesResetTitle),
        content: Text(l10n.settingsInstancesResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsInstancesResetAction),
          ),
        ],
      ),
    );
    if (confirmed ?? false) cubit.resetInstances();
  }

  void _onAction(_InstanceAction action, int index, MozhiInstance instance) {
    final cubit = context.read<SettingsCubit>();
    switch (action) {
      case _InstanceAction.prefer:
        cubit.preferInstance(instance.url);
      case _InstanceAction.moveUp:
        cubit.moveInstance(index, index - 1);
      case _InstanceAction.moveDown:
        cubit.moveInstance(index, index + 1);
      case _InstanceAction.remove:
        cubit.removeInstance(instance.url);
        final l10n = context.l10n;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.settingsInstanceRemoved),
              action: SnackBarAction(
                label: l10n.commonUndo,
                onPressed: () {
                  cubit.addInstance(instance);
                  final last = cubit.state.instances.length - 1;
                  if (last > index) cubit.moveInstance(last, index);
                },
              ),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (cubit) => cubit.state.instances,
    );
    return BlocListener<SettingsCubit, AppSettings>(
      listenWhen: (previous, current) =>
          previous.instances != current.instances,
      listener: _onInstancesChanged,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.settingsInstancesTitle),
          actions: [
            IconButton(
              tooltip: l10n.settingsInstancesReset,
              icon: const Icon(Icons.restore),
              onPressed: _reset,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: Text(l10n.settingsInstancesAdd),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) => RefreshIndicator(
            onRefresh: _refresh,
            child: ReorderableListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              padding: centeredPadding(constraints.maxWidth, bottom: 96),
              header: _Header(empty: instances.isEmpty, onReset: _reset),
              itemCount: instances.length,
              onReorderItem: (oldIndex, newIndex) => context
                  .read<SettingsCubit>()
                  .moveInstance(oldIndex, newIndex),
              itemBuilder: (context, index) {
                final instance = instances[index];
                return _InstanceTile(
                  key: ValueKey(instance.url),
                  index: index,
                  count: instances.length,
                  instance: instance,
                  ping: _pings[instance.url],
                  onAction: (action) => _onAction(action, index, instance),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.empty, required this.onReset});

  final bool empty;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card.outlined(
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.settingsInstancesInfoTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsInstancesInfoBody,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.privacy_tip_outlined,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.settingsInstancesPrivacy,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => LinkLauncher.open(
                      context,
                      InstancesView.mozhiProjectUrl,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.settingsInstancesLearnMore),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (empty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              children: [
                Icon(Icons.dns_outlined, size: 48, color: colors.outline),
                const SizedBox(height: 16),
                Text(
                  l10n.settingsInstancesEmptyTitle,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsInstancesEmptyBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: onReset,
                  icon: const Icon(Icons.restore),
                  label: Text(l10n.settingsInstancesReset),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _InstanceTile extends StatelessWidget {
  const _InstanceTile({
    required this.index,
    required this.count,
    required this.instance,
    required this.ping,
    required this.onAction,
    super.key,
  });

  final int index;
  final int count;
  final MozhiInstance instance;
  final PingStatus? ping;
  final ValueChanged<_InstanceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final host = Uri.tryParse(instance.url)?.host ?? instance.url;
    final preferred = index == 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: preferred
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Semantics(
                  label: l10n.settingsInstancesDragHandle,
                  child: Tooltip(
                    message: l10n.settingsInstancesDragHandle,
                    excludeFromSemantics: true,
                    child: SizedBox.square(
                      dimension: 48,
                      child: Icon(
                        Icons.drag_indicator,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instance.displayName,
                        style: theme.textTheme.bodyLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (instance.displayName != host)
                        Text(
                          host,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (preferred)
                            StatusBadge(
                              label: l10n.settingsInstancesPreferred,
                              color: colors.primary,
                              icon: Icons.star_rounded,
                            ),
                          LatencyBadge(status: ping),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<_InstanceAction>(
                tooltip: l10n.commonMoreOptions,
                onSelected: onAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _InstanceAction.prefer,
                    enabled: !preferred,
                    child: Text(l10n.settingsInstancesMakePreferred),
                  ),
                  PopupMenuItem(
                    value: _InstanceAction.moveUp,
                    enabled: index > 0,
                    child: Text(l10n.settingsInstancesMoveUp),
                  ),
                  PopupMenuItem(
                    value: _InstanceAction.moveDown,
                    enabled: index < count - 1,
                    child: Text(l10n.settingsInstancesMoveDown),
                  ),
                  PopupMenuItem(
                    value: _InstanceAction.remove,
                    child: Text(l10n.settingsInstancesRemove),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Latency badge: green < 500 ms, amber < 1500 ms, red otherwise or
/// "Offline" when the ping failed.
class LatencyBadge extends StatelessWidget {
  const LatencyBadge({required this.status, super.key});

  final PingStatus? status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      null || PingChecking() => StatusBadge(
        label: l10n.settingsInstancesChecking,
        color: colors.onSurfaceVariant,
        icon: Icons.more_horiz,
      ),
      PingOffline() => StatusBadge(
        label: l10n.settingsInstancesOffline,
        color: colors.error,
        icon: Icons.cloud_off_outlined,
      ),
      PingOnline(:final latency) => StatusBadge(
        label: l10n.settingsInstancesLatency(latency.inMilliseconds),
        color: latency.inMilliseconds < 500
            ? colors.success
            : latency.inMilliseconds < 1500
            ? colors.warning
            : colors.error,
        icon: Icons.network_check,
      ),
    };
  }
}
