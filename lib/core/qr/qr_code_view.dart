import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/qr/qr_code.dart';

/// A QR code of [data], [size] logical pixels square: black modules on
/// white with the four-module quiet zone, in every theme (cameras read
/// light-on-dark codes badly, and the white square reads as "scan me" on a
/// dark screen too).
///
/// Modules are whole physical pixels, so the code stays crisp at any
/// screen density; the white square is [size] and the code is centred in
/// it. Screen readers hear [semanticLabel] (say what the code opens, e.g.
/// "QR code for the link below"), not the pattern.
///
/// [data] must fit a QR code at [errorCorrection] (2331 bytes at
/// [QrErrorCorrection.medium]); a longer text falls back to
/// [QrErrorCorrection.low], and beyond that throws an [ArgumentError].
class QrCodeView extends StatefulWidget {
  const new({
    required this.data,
    required this.semanticLabel,
    this.size = 240,
    this.errorCorrection = QrErrorCorrection.medium,
    super.key,
  });

  final String data;
  final String semanticLabel;
  final double size;
  final QrErrorCorrection errorCorrection;

  @override
  State<QrCodeView> createState() => _QrCodeViewState();
}

class _QrCodeViewState extends State<QrCodeView> {
  late QrCode _code = _encode();

  QrCode _encode() {
    final fits =
        utf8.encode(widget.data).length <=
        QrCode.byteCapacity(40, widget.errorCorrection);
    return QrCode.encode(
      widget.data,
      errorCorrection: fits ? widget.errorCorrection : QrErrorCorrection.low,
    );
  }

  @override
  void didUpdateWidget(QrCodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.errorCorrection != widget.errorCorrection) {
      _code = _encode();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: SizedBox.square(
        dimension: widget.size,
        child: ClipRRect(
          borderRadius: AppLook.of(context).badgeRadius,
          child: CustomPaint(
            painter: QrCodePainter(
              _code,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints [code] black on white with a four-module quiet zone, snapped to
/// whole physical pixels at [devicePixelRatio].
class QrCodePainter extends CustomPainter {
  const new(this.code, {required this.devicePixelRatio});

  /// Light modules around the symbol (ISO/IEC 18004 asks for four).
  static const quietZone = 4;

  final QrCode code;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final modules = code.size + quietZone * 2;
    final side = size.shortestSide * devicePixelRatio;
    // Whole physical pixels per module (at least one), centred.
    final pixels = (side / modules).floor().clamp(1, 1 << 20);
    final module = pixels / devicePixelRatio;
    final left =
        _snap((size.width - module * modules) / 2) + quietZone * module;
    final top =
        _snap((size.height - module * modules) / 2) + quietZone * module;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    // One rectangle per horizontal run of dark modules: fewer draw calls
    // and no seams between neighbours.
    for (var y = 0; y < code.size; y++) {
      var x = 0;
      while (x < code.size) {
        if (!code.isDark(x, y)) {
          x++;
          continue;
        }
        final start = x;
        while (x < code.size && code.isDark(x, y)) {
          x++;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            left + start * module,
            top + y * module,
            (x - start) * module,
            module,
          ),
          paint,
        );
      }
    }
  }

  /// [value] rounded to a whole physical pixel.
  double _snap(double value) =>
      (value * devicePixelRatio).roundToDouble() / devicePixelRatio;

  @override
  bool shouldRepaint(QrCodePainter oldDelegate) =>
      oldDelegate.code != code ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
