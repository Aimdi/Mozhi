import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_settings_cubit.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of the Android integration settings
/// (Settings › General).
abstract final class ScreenTranslateAnchors {
  static const translateScreen = 'translate_screen';
  static const addTile = 'translate_screen_tile';

  /// Also the bubble notification's link (`TranslateBubbleService.kt`,
  /// `SETTINGS_LINK`).
  static const bubble = 'translate_bubble';
}

/// "Android integration" in Settings › General: what "Translate screen"
/// is (the Quick Settings tile, the launcher shortcut and the bubble),
/// "Add the Quick Settings tile" (Android 13+) and the opt-in "Translate
/// bubble" switch.
///
/// Turning the bubble on explains "Display over other apps" first when it
/// is not allowed yet, then opens Android's page for it; notifications are
/// asked for on Android 13+. The switch follows the bubble's own state
/// (read again whenever the app comes back: the bubble may have been
/// dragged onto × meanwhile).
///
/// Where the feature does not exist ([ScreenTranslateControls.isSupported]
/// false: the web, and tests on a desktop host) it says it needs the
/// Android app, like On-device AI.
class ScreenTranslateSettingsSection extends StatelessWidget {
  const new({this.controls, super.key});

  /// Default: [MethodChannelScreenTranslateControls.instance].
  final ScreenTranslateControls? controls;

  /// Whether the rows of the supported platform are shown (for the
  /// settings search index).
  static bool supported([ScreenTranslateControls? controls]) =>
      (controls ?? MethodChannelScreenTranslateControls.instance).isSupported;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controls =
        this.controls ?? MethodChannelScreenTranslateControls.instance;
    if (!controls.isSupported) {
      return SettingsSection(
        title: l10n.settingsAndroidIntegration,
        divider: false,
        children: [
          SettingsAnchor(
            id: ScreenTranslateAnchors.translateScreen,
            child: ListTile(
              key: const Key('settings_screen_translate_unavailable'),
              leading: const SettingsIcon(Icons.screenshot_monitor_outlined),
              title: Text(l10n.settingsScreenTranslate),
              subtitle: Text(l10n.settingsScreenTranslateUnavailable),
            ),
          ),
        ],
      );
    }
    return BlocProvider(
      create: (_) {
        final cubit = ScreenTranslateSettingsCubit(controls: controls);
        unawaited(cubit.refresh());
        return cubit;
      },
      child: const ScreenTranslateSettingsView(),
    );
  }
}

class ScreenTranslateSettingsView extends StatefulWidget {
  const new({super.key});

  @override
  State<ScreenTranslateSettingsView> createState() =>
      _ScreenTranslateSettingsViewState();
}

class _ScreenTranslateSettingsViewState
    extends State<ScreenTranslateSettingsView> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from Android's settings, or from another app after the bubble
    // was removed there.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted) {
          unawaited(context.read<ScreenTranslateSettingsCubit>().refresh());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _setBubble({required bool on}) async {
    final cubit = context.read<ScreenTranslateSettingsCubit>();
    if (!on) {
      await cubit.disableBubble();
      return;
    }
    if (!cubit.state.support.canDrawOverlays) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => const _OverlayPermissionDialog(),
      );
      if (proceed != true || !mounted) return;
    }
    await cubit.enableBubble();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ScreenTranslateSettingsCubit>().state;
    final cubit = context.read<ScreenTranslateSettingsCubit>();
    return BlocListener<
      ScreenTranslateSettingsCubit,
      ScreenTranslateSettingsState
    >(
      listenWhen: (previous, current) =>
          current.notice != null &&
          previous.noticeSerial != current.noticeSerial,
      listener: (context, state) {
        final message = _noticeText(l10n, state.notice!);
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      },
      child: SettingsSection(
        title: l10n.settingsAndroidIntegration,
        divider: false,
        children: [
          SettingsAnchor(
            id: ScreenTranslateAnchors.translateScreen,
            child: ListTile(
              key: const Key('settings_screen_translate'),
              leading: const SettingsIcon(Icons.screenshot_monitor_outlined),
              title: Text(l10n.settingsScreenTranslate),
              subtitle: Text(l10n.settingsScreenTranslateSubtitle),
            ),
          ),
          if (state.support.canAddTile)
            SettingsAnchor(
              id: ScreenTranslateAnchors.addTile,
              child: ListTile(
                key: const Key('settings_screen_translate_add_tile'),
                leading: const SettingsIcon(Icons.add_circle_outline),
                title: Text(l10n.settingsScreenTranslateAddTile),
                subtitle: Text(l10n.settingsScreenTranslateAddTileSubtitle),
                enabled: !state.busy,
                onTap: () => unawaited(cubit.addTile()),
              ),
            ),
          SettingsAnchor(
            id: ScreenTranslateAnchors.bubble,
            child: SwitchListTile(
              key: const Key('settings_screen_translate_bubble'),
              secondary: const SettingsIcon(Icons.bubble_chart_outlined),
              title: Text(l10n.settingsScreenTranslateBubble),
              subtitle: Text(l10n.settingsScreenTranslateBubbleSubtitle),
              value: state.bubbleOn,
              onChanged: state.busy || !state.loaded
                  ? null
                  : (on) => unawaited(_setBubble(on: on)),
            ),
          ),
        ],
      ),
    );
  }
}

String _noticeText(AppLocalizations l10n, ScreenTranslateNotice notice) =>
    switch (notice) {
      ScreenTranslateNotice.tileAdded => l10n.settingsScreenTranslateTileAdded,
      ScreenTranslateNotice.tileAlreadyAdded =>
        l10n.settingsScreenTranslateTileAlreadyAdded,
      ScreenTranslateNotice.tileFailed =>
        l10n.settingsScreenTranslateTileFailed,
      ScreenTranslateNotice.overlayDenied =>
        l10n.settingsScreenTranslateOverlayDenied,
      ScreenTranslateNotice.notificationsDenied =>
        l10n.settingsScreenTranslateNotificationsDenied,
      ScreenTranslateNotice.bubbleFailed =>
        l10n.settingsScreenTranslateBubbleFailed,
    };

/// Why the bubble needs "Display over other apps", before Android's page
/// for it opens. Continue answers true.
class _OverlayPermissionDialog extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const Key('settings_screen_translate_overlay_dialog'),
      icon: const Icon(Icons.bubble_chart_outlined),
      title: Text(l10n.settingsScreenTranslateOverlayTitle),
      content: Text(l10n.settingsScreenTranslateOverlayBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('settings_screen_translate_overlay_continue'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.settingsScreenTranslateOverlayContinue),
        ),
      ],
    );
  }
}
