import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Icon button that opens image translation (e.g. for the translate
/// screen's input card or app bar).
///
/// By default it pushes [ImageTranslatePage.location] (optionally opening
/// the picker for [source] right away); pass [onPressed] to navigate
/// differently.
class ImageTranslateButton extends StatelessWidget {
  const new({this.onPressed, this.source, super.key});

  final VoidCallback? onPressed;
  final ImagePickSource? source;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('image_translate_open_page_button'),
      tooltip: context.l10n.imageTranslateButtonTooltip,
      icon: const Icon(Icons.photo_camera_outlined),
      onPressed:
          onPressed ??
          () => context.push(ImageTranslatePage.locationFor(source: source)),
    );
  }
}
