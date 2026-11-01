import 'package:material_ui/material_ui.dart';

/// The title of an [AppBar] that is never cut while it can be read whole:
/// on one line in the app bar's title style when it fits, else scaled
/// down a little (to [minScale]), else on two lines in a smaller size
/// ([twoLineScale] of the title style's), and only then cut with an
/// ellipsis. Long translations ("Backup & Synchronisierung") stay
/// readable on phones, in both looks.
class AppBarTitle extends StatelessWidget {
  const new(this.text, {super.key});

  final String text;

  /// The smallest scale the title shrinks to on one line.
  static const double minScale = 0.85;

  /// The size of a title on two lines, relative to the title style's.
  static const double twoLineScale = 0.72;

  @override
  Widget build(BuildContext context) {
    // The app bar's title style (AppBar puts it around its title).
    final style = DefaultTextStyle.of(context).style;
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: direction,
          textScaler: textScaler,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        final available = constraints.maxWidth;
        if (!available.isFinite || width <= available) {
          return Text(text, maxLines: 1, softWrap: false);
        }
        if (width * minScale <= available) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(text, maxLines: 1, softWrap: false),
          );
        }
        return Text(
          text,
          maxLines: 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: (style.fontSize ?? 22) * twoLineScale,
            height: 1.15,
          ),
        );
      },
    );
  }
}
