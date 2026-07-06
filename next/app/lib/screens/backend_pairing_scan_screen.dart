import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/backend_pairing.dart';
import '../ui/app_tokens.dart';

class BackendPairingScanScreen extends StatefulWidget {
  const BackendPairingScanScreen({super.key});

  @override
  State<BackendPairingScanScreen> createState() =>
      _BackendPairingScanScreenState();
}

class _BackendPairingScanScreenState extends State<BackendPairingScanScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_handling) unawaited(_controller.start());
      case AppLifecycleState.inactive:
        unawaited(_controller.pause());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        raw = value;
        break;
      }
    }
    if (raw == null) return;

    setState(() {
      _handling = true;
      _error = null;
    });
    await _controller.stop();
    try {
      final target = BackendPairing.parseTarget(raw);
      if (!mounted) return;
      Navigator.of(context).pop(target);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _handling = false;
        _error = e.message;
      });
      await _controller.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _handling = false;
        _error = 'Could not read backend QR: $e';
      });
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan backend QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          const _ScanFrame(),
          Positioned(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.lg,
            child: SafeArea(
              top: false,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _handling
                            ? 'Reading backend QR...'
                            : 'Scan the QR printed by install.sh',
                        style: theme.textTheme.titleSmall,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide * 0.72;
          return Center(
            child: SizedBox.square(
              dimension: side,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
