import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'application/error_messages.dart';
import 'application/session_vault.dart';
import 'data/database.dart';
import 'data/engine.dart';
import 'pantallas/login.dart'; // Conectamos con la carpeta de pantallas
import 'pantallas/seleccion.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InventarioApp());
}

class InventarioApp extends StatefulWidget {
  final SessionVault? vault;
  final http.Client? client;
  final InventoryDatabase? database;
  final DateTime Function()? clock;
  const InventarioApp(
      {super.key, this.vault, this.client, this.database, this.clock});

  @override
  State<InventarioApp> createState() => _InventarioAppState();
}

class _InventarioAppState extends State<InventarioApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final SessionVault _vault;
  InventoryDataEngine? _engine;
  bool _loading = true;
  String? _restoreError;

  @override
  void initState() {
    super.initState();
    _vault = widget.vault ?? SecureSessionVault();
    _restore();
  }

  Future<void> _restore() async {
    setState(() {
      _loading = true;
      _restoreError = null;
    });
    try {
      final saved = await _vault.restore();
      if (!mounted) return;
      if (saved != null) _engine = _makeEngine(saved);
    } on Object catch (error) {
      if (mounted) _restoreError = inventoryErrorMessage(error);
    } finally {
      if (mounted)
        setState(() {
          _loading = false;
        });
    }
  }

  InventoryDataEngine _makeEngine(SavedInventorySession saved) =>
      InventoryDataEngine(
          baseUri: saved.baseUri,
          session: saved.session,
          tokenProvider: () async => saved.accessToken,
          allowLocalHttp: kDebugMode,
          database: widget.database,
          client: widget.client,
          clock: widget.clock);

  Future<void> _authenticated(SavedInventorySession saved) async {
    final next = _makeEngine(saved);
    try {
      await _vault.save(saved);
    } on Object {
      next.closeNetwork();
      rethrow;
    }
    if (!mounted) {
      next.closeNetwork();
      return;
    }
    _engine?.closeNetwork();
    setState(() {
      _engine = next;
      _restoreError = null;
    });
  }

  Future<void> _resetSession() async {
    setState(() => _loading = true);
    try {
      await _vault.clear();
      if (mounted) _restoreError = null;
    } on Object catch (error) {
      if (mounted) _restoreError = inventoryErrorMessage(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signOut() async {
    final current = _engine;
    if (current == null) return;
    final queue = await current.repository.operations();
    final outstanding = queue
        .where((op) => op.status != 'synced' && op.resolvedAt == null)
        .length;
    if (!mounted) return;
    if (outstanding > 0) {
      final confirmed = await showDialog<bool>(
          context: _navigator.currentContext!,
          builder: (context) => AlertDialog(
                  title: const Text('Hay capturas sin sincronizar'),
                  content: Text(
                      'Tienes $outstanding operaciones sin resolver. Se conservarán en este dispositivo y podrás retomarlas al ingresar con la misma cuenta.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Continuar trabajando')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Cerrar sesión'))
                  ]));
      if (confirmed != true) return;
    }
    await _vault.clear();
    if (!mounted) return;
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _engine = null;
    });
    current.closeNetwork();
  }

  @override
  void dispose() {
    _engine?.closeNetwork();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Inventario Móvil',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue.shade900),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff4f6fa),
        inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
            filled: true,
            fillColor: Colors.white),
        filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14))),
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _restoreError != null
              ? Scaffold(
                  body: SafeArea(
                      child: Center(
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.lock_outline, size: 48),
                                    const SizedBox(height: 16),
                                    const Text(
                                        'No se pudo recuperar la sesión guardada.'),
                                    const SizedBox(height: 8),
                                    Text(_restoreError!,
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                        onPressed: _restore,
                                        child: const Text('Reintentar')),
                                    TextButton(
                                        onPressed: _resetSession,
                                        child: const Text(
                                            'Volver a iniciar sesión')),
                                  ])))))
              : _engine == null
                  ? PantallaLogin(
                      vault: _vault,
                      onAuthenticated: _authenticated,
                      client: widget.client)
                  : PantallaSeleccion(engine: _engine!, onSignOut: _signOut),
    );
  }
}
