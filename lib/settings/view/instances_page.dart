import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/add_instance_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi_api/mozhi_api.dart' show MozhiPublicInstance;
import 'package:translation_repository/translation_repository.dart';

/// Manage the ordered list of Mozhi instances (first = preferred).
///
/// Nothing is contacted when the page opens: instances are only checked
/// ("Check instances", pull to refresh) or tested ("Test" in an instance's
/// menu) on request, through [checker] (default: the session's
/// [NetworkSession.instanceChecker], whose results last for the session).
/// [catalog] is the bundled public instance list
/// ([MozhiPublicInstance.all]); [proxyActive] whether requests go through
/// a proxy this session (default: [NetworkSession.hasProxy]).
class InstancesPage extends StatelessWidget {
  const new({
    this.checker,
    this.catalog = MozhiPublicInstance.all,
    this.proxyActive,
    super.key,
  });

  final MozhiInstanceChecker? checker;
  final List<MozhiPublicInstance> catalog;
  final bool? proxyActive;

  @override
  Widget build(BuildContext context) => InstancesView(
    checker: checker ?? NetworkSession.current.instanceChecker,
    catalog: catalog,
    proxyActive: proxyActive ?? NetworkSession.current.hasProxy,
  );
}

class InstancesView extends StatefulWidget {
  const new({
    required this.checker,
    required this.catalog,
    required this.proxyActive,
    super.key,
  });

  final MozhiInstanceChecker checker;
  final List<MozhiPublicInstance> catalog;
  final bool proxyActive;

  static final Uri mozhiProjectUrl = Uri.parse(
    'https://codeberg.org/aryak/mozhi',
  );

  @override
  State<InstancesView> createState() => _InstancesViewState();
}

enum _InstanceAction { test, edit, prefer, moveUp, moveDown, remove }

/// One address of a [MozhiPublicInstance] the user can add.
typedef _CatalogAddress = ({
  String url,
  MozhiPublicInstance entry,
  _Network network,
});

enum _Network { clearnet, tor, i2p }

class _InstancesViewState extends State<InstancesView> {
  late StreamSubscription<void> _changes;
  late Map<String, MozhiPublicInstance> _catalogByUrl;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _changes = widget.checker.changes.listen(_onResults);
    _indexCatalog();
  }

  @override
  void didUpdateWidget(InstancesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checker != widget.checker) {
      unawaited(_changes.cancel());
      _changes = widget.checker.changes.listen(_onResults);
    }
    if (oldWidget.catalog != widget.catalog) _indexCatalog();
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  void _indexCatalog() => _catalogByUrl = {
    for (final entry in widget.catalog)
      for (final address in entry.addresses) address: entry,
  };

  void _onResults(void _) {
    if (mounted) setState(() {});
  }

  /// Checks every instance in the list (only when asked to) and, once all
  /// of them have answered, announces how many are reachable (WCAG 4.1.3)
  /// instead of one message per badge.
  Future<void> _checkAll() async {
    final instances = context.read<SettingsCubit>().state.instances;
    if (instances.isEmpty || _checking) return;
    setState(() => _checking = true);
    await widget.checker.checkAll([for (final i in instances) i.url]);
    if (!mounted) return;
    setState(() => _checking = false);
    final online = instances
        .where((i) => widget.checker.resultFor(i.url) is InstanceOnline)
        .length;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        context.l10n.settingsInstancesPingSummary(online, instances.length),
        Directionality.of(context),
      ),
    );
  }

  Future<void> _add() async {
    final cubit = context.read<SettingsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final added = context.l10n.settingsInstanceAdded;
    final instance = await showDialog<MozhiInstance>(
      context: context,
      builder: (_) => AddInstanceDialog(
        existingUrls: [for (final i in cubit.state.instances) i.url],
        checker: widget.checker,
        proxyActive: widget.proxyActive,
      ),
    );
    if (instance == null) return;
    cubit.addInstance(instance);
    messenger.showSnackBar(SnackBar(content: Text(added)));
  }

  Future<void> _edit(int index, MozhiInstance instance) async {
    final cubit = context.read<SettingsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final updatedText = context.l10n.settingsInstanceUpdated;
    final updated = await showDialog<MozhiInstance>(
      context: context,
      builder: (_) => AddInstanceDialog(
        initial: instance,
        existingUrls: [
          for (final i in cubit.state.instances)
            if (i.url != instance.url) i.url,
        ],
        checker: widget.checker,
        proxyActive: widget.proxyActive,
      ),
    );
    if (updated == null) return;
    if (updated.url == instance.url) {
      // Replaced in place.
      cubit.addInstance(updated);
    } else {
      cubit
        ..removeInstance(instance.url)
        ..addInstance(updated);
      final last = cubit.state.instances.length - 1;
      if (last > index) cubit.moveInstance(last, index);
    }
    messenger.showSnackBar(SnackBar(content: Text(updatedText)));
  }

  void _addFromCatalog(_CatalogAddress address) {
    final host = Uri.parse(address.url).host;
    final country = address.entry.country;
    context.read<SettingsCubit>().addInstance(
      MozhiInstance(
        url: address.url,
        label: address.network == _Network.clearnet && country != null
            ? '$host ($country)'
            : null,
        isCustom: false,
      ),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.settingsInstanceAdded)));
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
      case _InstanceAction.test:
        showDialog<void>(
          context: context,
          builder: (_) =>
              InstanceTestDialog(checker: widget.checker, instance: instance),
        );
      case _InstanceAction.edit:
        unawaited(_edit(index, instance));
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

  /// The catalogue addresses that are not in the list yet; Tor and I2P
  /// ones only with a proxy setting.
  List<_CatalogAddress> _available(
    List<MozhiInstance> instances, {
    required bool showHidden,
  }) {
    final added = {for (final i in instances) i.url};
    return [
      for (final entry in widget.catalog)
        for (final (url, network) in [
          (entry.url, _Network.clearnet),
          if (showHidden) ...[
            (entry.onion, _Network.tor),
            (entry.i2p, _Network.i2p),
          ],
        ])
          if (url != null && !added.contains(url))
            (url: url, entry: entry, network: network),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final instances = context.select<SettingsCubit, List<MozhiInstance>>(
      (cubit) => cubit.state.instances,
    );
    // The setting, not the session: addresses can be added before the
    // restart that activates the proxy (their badge says it is needed).
    final proxySet = context.select<SettingsCubit, bool>(
      (cubit) => !kIsWeb && cubit.state.httpProxy != null,
    );
    final hasHidden = widget.catalog.any(
      (entry) => entry.onion != null || entry.i2p != null,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsInstancesTitle),
        actions: [
          // Pull to refresh needs a drag; this is the pointer, keyboard
          // and switch-access alternative (WCAG 2.5.7, 2.1.1).
          IconButton(
            tooltip: l10n.settingsInstancesCheck,
            icon: const Icon(Icons.network_check),
            onPressed: instances.isEmpty || _checking ? null : _checkAll,
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
          onRefresh: _checkAll,
          child: ReorderableListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            padding: centeredPadding(constraints.maxWidth, bottom: 96),
            header: _Header(
              empty: instances.isEmpty,
              checking: _checking,
              onReset: _reset,
            ),
            footer: _Catalog(
              available: _available(instances, showHidden: proxySet),
              hiddenNote: hasHidden && !proxySet,
              onAdd: _addFromCatalog,
            ),
            itemCount: instances.length,
            onReorderItem: _move,
            itemBuilder: (context, index) {
              final instance = instances[index];
              return _InstanceTile(
                key: ValueKey(instance.url),
                index: index,
                count: instances.length,
                instance: instance,
                catalogEntry: _catalogByUrl[instance.url],
                health: widget.checker.resultFor(instance.url),
                proxyActive: widget.proxyActive,
                onAction: (action) => _onAction(action, index, instance),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const new({
    required this.empty,
    required this.checking,
    required this.onReset,
  });

  final bool empty;
  final bool checking;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card.outlined(
          margin: const EdgeInsets.only(bottom: 16),
          color: colors.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
            borderRadius: AppRadius.cardBorderRadius,
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
                _Note(
                  icon: Icons.privacy_tip_outlined,
                  text: l10n.settingsInstancesPrivacy,
                  style: secondary,
                ),
                const SizedBox(height: 8),
                _Note(
                  icon: Icons.network_check,
                  text: l10n.settingsInstancesCheckNote,
                  style: secondary,
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
        if (checking)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              semanticsLabel: l10n.settingsInstancesChecking,
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

class _Note extends StatelessWidget {
  const new({required this.icon, required this.text, required this.style});

  final IconData icon;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: style)),
    ],
  );
}

class _InstanceTile extends StatelessWidget {
  const new({
    required this.index,
    required this.count,
    required this.instance,
    required this.catalogEntry,
    required this.health,
    required this.proxyActive,
    required this.onAction,
    super.key,
  });

  final int index;
  final int count;
  final MozhiInstance instance;
  final MozhiPublicInstance? catalogEntry;
  final InstanceHealth? health;
  final bool proxyActive;
  final ValueChanged<_InstanceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final uri = Uri.tryParse(instance.url);
    final host = uri?.host ?? instance.url;
    final preferred = index == 0;
    final hidden = isHiddenServiceHost(host);
    final entry = catalogEntry;
    final cleartextRefused = uri != null && !isCleartextAllowed(uri);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // A flat hairline card; the preferred one keeps the same surface (so
      // badge and text contrast stay the same) and is marked by a primary
      // outline instead.
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardBorderRadius,
          side: preferred
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide(color: colors.outline),
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
                          if (entry?.cloudflare ?? false)
                            CloudflareBadge(
                              key: ValueKey('cf ${instance.url}'),
                            ),
                          if (hidden) NetworkBadge(host: host),
                          if (hidden && !proxyActive)
                            StatusBadge(
                              label: l10n.settingsInstancesNeedsProxy,
                              color: colors.warning,
                              icon: Icons.vpn_lock_outlined,
                            )
                          else if (cleartextRefused)
                            StatusBadge(
                              label: l10n.settingsInstancesNeedsHttps,
                              color: colors.error,
                              icon: Icons.no_encryption_outlined,
                            )
                          else if (health != null)
                            ...HealthBadges.of(context, health!),
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
                    value: _InstanceAction.test,
                    child: Text(l10n.settingsInstanceTest),
                  ),
                  PopupMenuItem(
                    value: _InstanceAction.edit,
                    child: Text(l10n.settingsInstancesEdit),
                  ),
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

/// "Cloudflare": the instance is behind Cloudflare, which terminates TLS
/// and can read the text (spoken as such).
class CloudflareBadge extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return StatusBadge(
      label: l10n.settingsInstancesCloudflare,
      color: Theme.of(context).colorScheme.warning,
      icon: Icons.visibility_outlined,
      semanticsLabel: l10n.settingsInstancesCloudflareDescription,
    );
  }
}

/// "Tor" or "I2P" for a hidden service [host]; nothing for other hosts.
class NetworkBadge extends StatelessWidget {
  const new({required this.host, super.key});

  final String host;

  @override
  Widget build(BuildContext context) {
    final name = host.toLowerCase();
    final l10n = context.l10n;
    final label = name.endsWith('.onion')
        ? l10n.settingsInstancesTor
        : name.endsWith('.i2p')
        ? l10n.settingsInstancesI2p
        : null;
    if (label == null) return const SizedBox.shrink();
    return StatusBadge(
      label: label,
      color: Theme.of(context).colorScheme.tertiary,
      icon: Icons.vpn_lock_outlined,
    );
  }
}

/// The badges for a check result: "Checking…", the latency and engine
/// count, "Offline", or why the network policy refused the instance.
abstract final class HealthBadges {
  static List<Widget> of(BuildContext context, InstanceHealth health) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return switch (health) {
      InstanceChecking() => [
        StatusBadge(
          label: l10n.settingsInstancesChecking,
          color: colors.onSurfaceVariant,
          icon: Icons.more_horiz,
        ),
      ],
      InstanceOnline(:final latency, :final engines) => [
        LatencyBadge(latency: latency),
        StatusBadge(
          label: l10n.settingsInstancesEngines(engines.length),
          color: engines.isEmpty ? colors.error : colors.onSurfaceVariant,
          icon: Icons.translate,
        ),
      ],
      InstanceOffline(:final error) => [
        switch (NetworkPolicyError.of(error)) {
          NetworkPolicyError.proxyRequired => StatusBadge(
            label: l10n.settingsInstancesNeedsProxy,
            color: colors.warning,
            icon: Icons.vpn_lock_outlined,
          ),
          NetworkPolicyError.cleartext => StatusBadge(
            label: l10n.settingsInstancesNeedsHttps,
            color: colors.error,
            icon: Icons.no_encryption_outlined,
          ),
          NetworkPolicyError.invalidProxy ||
          NetworkPolicyError.redirectRefused ||
          null => StatusBadge(
            label: l10n.settingsInstancesOffline,
            color: colors.error,
            icon: Icons.cloud_off_outlined,
          ),
        },
      ],
    };
  }
}

/// Latency badge: green < 500 ms, amber < 1500 ms, red otherwise. Each
/// level also has its own icon and a spoken quality word, so colour is not
/// the only cue (WCAG 1.4.1).
class LatencyBadge extends StatelessWidget {
  const new({required this.latency, super.key});

  final Duration latency;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
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

/// The bundled public instances that are not in the list yet, each with an
/// add button; Tor and I2P addresses only with a proxy setting
/// ([hiddenNote] says so otherwise).
class _Catalog extends StatelessWidget {
  const new({
    required this.available,
    required this.hiddenNote,
    required this.onAdd,
  });

  final List<_CatalogAddress> available;
  final bool hiddenNote;
  final ValueChanged<_CatalogAddress> onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.settingsInstancesCatalogTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.settingsInstancesCatalogBody(MozhiPublicInstance.snapshotDate),
            style: secondary,
          ),
          if (hiddenNote) ...[
            const SizedBox(height: 4),
            Text(l10n.settingsInstancesCatalogHidden, style: secondary),
          ],
          const SizedBox(height: 8),
          if (available.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.settingsInstancesCatalogEmpty, style: secondary),
            ),
          for (final address in available)
            _CatalogTile(
              key: ValueKey('catalog ${address.url}'),
              address: address,
              onAdd: () => onAdd(address),
            ),
        ],
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const new({required this.address, required this.onAdd, super.key});

  final _CatalogAddress address;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final host = Uri.parse(address.url).host;
    final entry = address.entry;
    // Hidden services show which clearnet instance they mirror, if known.
    final operator = switch (entry.url) {
      final url? when address.network != _Network.clearnet => Uri.parse(
        url,
      ).host,
      _ => null,
    };
    final details = [?operator, ?entry.country, ?entry.isp].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty) Text(details),
          if (entry.cloudflare && address.network == _Network.clearnet ||
              address.network != _Network.clearnet) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (entry.cloudflare && address.network == _Network.clearnet)
                  const CloudflareBadge(),
                if (address.network != _Network.clearnet)
                  NetworkBadge(host: host),
              ],
            ),
          ],
        ],
      ),
      subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      trailing: IconButton(
        tooltip: l10n.settingsInstancesCatalogAdd(host),
        icon: const Icon(Icons.add_circle_outline),
        onPressed: onAdd,
      ),
    );
  }
}

/// Runs [MozhiInstanceChecker.test] for [instance] when shown and reports
/// the translation of `hello`, the engine and the latency, or the error.
class InstanceTestDialog extends StatefulWidget {
  const new({required this.checker, required this.instance, super.key});

  final MozhiInstanceChecker checker;
  final MozhiInstance instance;

  @override
  State<InstanceTestDialog> createState() => _InstanceTestDialogState();
}

class _InstanceTestDialogState extends State<InstanceTestDialog> {
  InstanceTestResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final result = await widget.checker.test(widget.instance.url);
      if (mounted) setState(() => _result = result);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final result = _result;
    final error = _error;
    final (icon, color, text) = switch ((result, error)) {
      (final result?, _) => (
        Icons.check_circle_outline,
        colors.success,
        l10n.settingsInstancesTestResult(
          result.engineName,
          result.text,
          result.latency.inMilliseconds,
        ),
      ),
      (_, InstanceHasNoEnginesException()) => (
        Icons.error_outline,
        colors.error,
        l10n.settingsInstancesNoEngines,
      ),
      (_, final error?) => (
        Icons.error_outline,
        colors.error,
        l10n.settingsInstanceTestFailed(describeErrorLocalized(l10n, error)),
      ),
      _ => (null, null, null),
    };
    return AlertDialog(
      title: Text(l10n.settingsInstancesTestTitle(widget.instance.displayName)),
      content: text == null
          ? LinearProgressIndicator(
              semanticsLabel: l10n.settingsInstanceTesting,
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    child: Text(text),
                  ),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}
