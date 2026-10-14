import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the ordered list of Mozhi instances (first = preferred).
class InstancesPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const InstancesView();
}

/// Result of pinging an instance.
@immutable
sealed class PingStatus {
  const new();
}

class PingChecking extends PingStatus {
  const new();
}

class PingOnline extends PingStatus {
  const new(this.latency);
  final Duration latency;
}

class PingOffline extends PingStatus {
  const new();
}

class InstancesView extends StatefulWidget {
  const new({super.key});

  static final Uri mozhiProjectUrl = Uri.parse(
    'https://codeberg.org/aryak/mozhi',
  );

  @override
  State<InstancesView> createState() => _InstancesViewState();
}

enum _InstanceAction { prefer, moveUp, moveDown, remove }

class _InstancesViewState extends State<InstancesView> {
  final Map<String, PingStatus> _pings = {};

  /// Bumped on every full refresh so only the latest one is announced.
  int _round = 0;

  @override
  void initState() {
    super.initState();
    final instances = context.read<SettingsCubit>().state.instances;
    for (final instance in instances) {
      _pings[instance.url] = const PingChecking();
    }
    unawaited(_pingAll(instances));
  }

  /// Pings [instances] and, once all of them have answered, announces how
  /// many are reachable (WCAG 4.1.3) instead of one message per badge.
  Future<void> _pingAll(List<MozhiInstance> instances) async {
    final round = ++_round;
    await Future.wait(instances.map(_ping));
    if (!mounted || round != _round || instances.isEmpty) return;
    final online = instances.where((i) => _pings[i.url] is PingOnline).length;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        context.l10n.settingsInstancesPingSummary(online, instances.length),
        Directionality.of(context),
      ),
    );
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
    return _pingAll(instances);
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

  /// Moves the instance at [from] so it ends up at [to].
  /// `SettingsCubit.moveInstance` uses `ReorderableListView.onReorder`
  /// semantics (insertion index before removal), hence the adjustment.
  void _move(int from, int to) {
    if (from == to) return;
    context.read<SettingsCubit>().moveInstance(from, to > from ? to + 1 : to);
  }

  void _onAction(_InstanceAction action, int index, MozhiInstance instance) {
    final cubit = context.read<SettingsCubit>();
    switch (action) {
      case _InstanceAction.prefer:
        cubit.preferInstance(instance.url);
      case _InstanceAction.moveUp:
        _move(index, index - 1);
      case _InstanceAction.moveDown:
        _move(index, index + 1);
      case _InstanceAction.remove:
        cubit.removeInstance(instance.url);
        showUndoSnackBar(
          context,
          message: context.l10n.settingsInstanceRemoved,
          onUndo: () {
            cubit.addInstance(instance);
            final last = cubit.state.instances.length - 1;
            if (last > index) cubit.moveInstance(last, index);
          },
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
            // Pull to refresh needs a drag; this is the pointer, keyboard
            // and switch-access alternative (WCAG 2.5.7, 2.1.1).
            IconButton(
              tooltip: l10n.settingsInstancesRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: instances.isEmpty ? null : _refresh,
            ),
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
              onReorderItem: _move,
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
  const new({required this.empty, required this.onReset});

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
                Semantics(
                  header: true,
                  child: Text(
                    l10n.settingsInstancesEmptyTitle,
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
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
  const new({
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
      // The preferred card keeps the normal surface (so badge and text
      // contrast stay the same) and is marked by a primary outline instead.
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: preferred
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide.none,
        ),
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
/// "Offline" when the ping failed. Each level also has its own icon and a
/// spoken quality word, so colour is not the only cue (WCAG 1.4.1).
class LatencyBadge extends StatelessWidget {
  const new({required this.status, super.key});

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
      PingOnline(:final latency) => _online(l10n, colors, latency),
    };
  }

  static StatusBadge _online(
    AppLocalizations l10n,
    ColorScheme colors,
    Duration latency,
  ) {
    final ms = latency.inMilliseconds;
    final (color, icon, spoken) = ms < 500
        ? (colors.success, Icons.speed, l10n.settingsInstancesLatencyFast(ms))
        : ms < 1500
        ? (
            colors.warning,
            Icons.timelapse,
            l10n.settingsInstancesLatencyModerate(ms),
          )
        : (
            colors.error,
            Icons.hourglass_bottom,
            l10n.settingsInstancesLatencySlow(ms),
          );
    return StatusBadge(
      label: l10n.settingsInstancesLatency(ms),
      color: color,
      icon: icon,
      semanticsLabel: spoken,
    );
  }
}
