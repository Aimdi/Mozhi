import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';

/// An empty or error state in the style of the tabs' greeting
/// ([TabHero]): an accent icon, a bold centred headline, quiet body text
/// and an optional pill action. Scrolls when the window is too low.
class PresetsMessage extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TabHero(icon: icon, title: title, body: body, child: action),
        ),
      ),
    );
  }
}
