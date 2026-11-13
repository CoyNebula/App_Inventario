import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class PantallaEscanerQr extends StatefulWidget {
  const PantallaEscanerQr({super.key});
  @override
  State<PantallaEscanerQr> createState() => _PantallaEscanerQrState();
}

class _PantallaEscanerQrState extends State<PantallaEscanerQr>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
      autoStart: false,
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates);
  Future<void> _actions = Future<void>.value();
  bool _finishing = false;
  bool _foreground = true;
  String? _error;
  bool get _supported =>
      kIsWeb ||
      [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]
          .contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_supported)
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() {
    _actions = _actions.then((_) async {
      if (!mounted || !_foreground || _finishing || _controller.value.isRunning)
        return;
      try {
        await _controller.start();
        if (!mounted || !_foreground || _finishing) await _controller.stop();
        if (mounted) setState(() => _error = null);
      } on MobileScannerException catch (error) {
        if (mounted) setState(() => _error = _message(error));
      } on Object {
        if (mounted)
          setState(() => _error =
              'No se pudo abrir la cámara. Puedes usar la entrada manual.');
      }
    });
    return _actions;
  }

  Future<void> _stop() {
    _actions = _actions.then((_) async {
      try {
        await _controller.stop();
      } on Object {/* A failed start has no camera to stop. */}
    });
    return _actions;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Permission dialogs change lifecycle before start() has initialized the
    // controller. Do not queue a stop that would cancel the first granted start.
    if (!_controller.value.hasCameraPermission) return;
    if (!_foreground)
      unawaited(_stop());
    else if (!_finishing && _controller.value.hasCameraPermission)
      unawaited(_start());
  }

  void _detected(BarcodeCapture capture) {
    if (_finishing || !_foreground) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _finishing = true;
      unawaited(_returnCode(raw));
      return;
    }
  }

  Future<void> _returnCode(String raw) async {
    await _stop();
    if (mounted) Navigator.pop(context, raw);
  }

  @override
  void dispose() {
    _foreground = false;
    _finishing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
        _actions.then((_) => _controller.dispose()).catchError((Object _) {}));
    super.dispose();
  }

  String _message(MobileScannerException error) => error.errorCode ==
          MobileScannerErrorCode.permissionDenied
      ? 'El permiso de cámara está desactivado. Habilítalo en los ajustes del dispositivo o usa la entrada manual.'
      : 'La cámara no está disponible. Puedes usar la entrada manual.';

  Widget _errorView(String message) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (_supported)
              OutlinedButton(
                  onPressed: _start, child: const Text('Reintentar cámara')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Usar entrada manual'))
          ])));

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Escanear QR')),
      body: !_supported
          ? _errorView('Usa la entrada manual en este dispositivo.')
          : Column(children: [
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'Enfoca una sola etiqueta QR. La lectura se buscará en esta descarga.')),
              Expanded(
                  child: Stack(fit: StackFit.expand, children: [
                MobileScanner(
                    controller: _controller,
                    onDetect: _detected,
                    useAppLifecycleState: false,
                    errorBuilder: (_, error) => _errorView(_message(error))),
                if (_error != null)
                  ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: _errorView(_error!))
              ])),
              SafeArea(
                  top: false,
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Usar entrada manual'))))
            ]));
}
