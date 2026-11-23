import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/qr/qr_decoder.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/data/method_channel_live_camera_controller.dart';
import 'package:mozhi/live_camera/data/upright_frame.dart';
import 'package:mozhi/live_camera/widgets/live_camera_preview.dart'
    show coverRect;
import 'package:mozhi/pairing/protocol/pairing_code.dart';

typedef _DecodeInput = ({CameraFrame frame});

String? _decodeFrame(_DecodeInput input) {
  final upright = uprightFrame(input.frame);
  return QrDecoder.decode(upright.pixels, upright.width, upright.height);
}

/// Licence-clean, on-device QR scanner for phone-to-phone pairing using
/// Android's Camera2 preview ([LiveCameraController], no Google code) and
/// Mozhi's pure-Dart [QrDecoder].
///
/// Pops with the scanned [PairingCode.text] as soon as a valid pairing QR
/// code (`mozhi://pair?code=...` or raw pairing code) is decoded.
class PairingQrScannerPage extends StatefulWidget {
  const new({this.controller, this.decodeInline = false, super.key});

  /// Camera controller; defaults to [defaultLiveCameraController].
  final LiveCameraController? controller;

  /// When true (tests), runs [QrDecoder.decode] on the current isolate instead
  /// of `compute`.
  final bool decodeInline;

  @override
  State<PairingQrScannerPage> createState() => _PairingQrScannerPageState();
}

class _PairingQrScannerPageState extends State<PairingQrScannerPage> {
  late final LiveCameraController _camera =
      widget.controller ?? defaultLiveCameraController();

  LivePreview? _preview;
  CameraAccess? _access;
  int _displayRotation = 0;
  bool _torchOn = false;
  bool _scanning = false;
  bool _found = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _scanning = false;
    unawaited(_camera.stop());
    super.dispose();
  }

  Future<void> _start() async {
    if (!_camera.isSupported) {
      if (!mounted) return;
      setState(() => _error = 'unsupported');
      return;
    }
    final access = await _camera.requestAccess();
    if (!mounted) return;
    setState(() => _access = access);
    if (access != CameraAccess.granted) return;
    try {
      final rotation =
          await liveCameraPlatformOf(_camera)?.displayRotation() ?? 0;
      final preview = await _camera.start();
      if (!mounted) return;
      setState(() {
        _displayRotation = rotation;
        _preview = preview;
      });
      _scanning = true;
      unawaited(_scanLoop());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _scanLoop() async {
    while (_scanning && mounted && !_found) {
      CameraFrame? frame;
      try {
        frame = await _camera.nextFrame();
      } on Object {
        break;
      }
      if (frame == null || !_scanning || !mounted || _found) break;
      String? payload;
      try {
        payload = widget.decodeInline
            ? _decodeFrame((frame: frame))
            : await compute(_decodeFrame, (frame: frame));
      } on Object {
        payload = null;
      }
      if (!mounted || !_scanning || _found) break;
      if (payload != null) {
        final parsed = PairingCode.tryParse(payload);
        if (parsed != null) {
          _found = true;
          _scanning = false;
          Navigator.of(context).pop(parsed.text);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _toggleTorch() async {
    final next = !_torchOn;
    try {
      await _camera.setTorch(on: next);
      if (mounted) setState(() => _torchOn = next);
    } on Object {
      // Best-effort torch toggle.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pairingScanQrTitle),
        actions: [
          if (preview != null && preview.hasTorch)
            IconButton(
              key: const Key('pairing_qr_torch'),
              tooltip: _torchOn
                  ? l10n.liveCameraTorchOff
                  : l10n.liveCameraTorchOn,
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              onPressed: () => unawaited(_toggleTorch()),
            ),
        ],
      ),
      body: _buildBody(context, preview),
    );
  }

  Widget _buildBody(BuildContext context, LivePreview? preview) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (_access == CameraAccess.denied || _access == CameraAccess.blocked) {
      final platform = liveCameraPlatformOf(_camera);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.no_photography_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.pairingScanQrPermissionDenied,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              if (_access == CameraAccess.blocked && platform != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(platform.openAppSettings()),
                  child: Text(l10n.liveCameraOpenSettings),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.pairingScanQrPermissionDenied,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (preview == null) {
      return Center(
        child: CircularProgressIndicator(
          semanticsLabel: l10n.pairingScanQrTitle,
        ),
      );
    }
    final turns = (4 - _displayRotation ~/ 90) % 4;
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final rect = coverRect(
            preview.sizeOnScreen(_displayRotation),
            constraints.biggest,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: rect,
                child: ExcludeSemantics(
                  child: RotatedBox(
                    quarterTurns: turns,
                    child: Texture(textureId: preview.textureId),
                  ),
                ),
              ),
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 32,
                child: SafeArea(
                  top: false,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        l10n.pairingScanQrHint,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
