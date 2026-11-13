import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../application/error_messages.dart';
import '../application/session_vault.dart';
import '../data/api_client.dart';
import '../data/models.dart';

class PantallaLogin extends StatefulWidget {
  final SessionVault vault;
  final Future<void> Function(SavedInventorySession session) onAuthenticated;
  final http.Client? client;
  const PantallaLogin(
      {super.key,
      required this.vault,
      required this.onAuthenticated,
      this.client});

  @override
  State<PantallaLogin> createState() => _PantallaLoginState();
}

class _PantallaLoginState extends State<PantallaLogin> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _factor = TextEditingController();
  final _server = TextEditingController(
      text: const String.fromEnvironment('INVENTARIO_API_URL',
          defaultValue: 'http://10.0.2.2:8084/api/v1/mobile'));
  MobileApiClient? _api;
  Uri? _baseUri;
  String? _deviceId;
  String? _challenge;
  String? _error;
  bool _busy = false;
  bool _recovery = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _factor.dispose();
    _server.dispose();
    _api?.close();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      JsonMap result;
      if (_challenge == null) {
        var uri = Uri.parse(_server.text.trim());
        if (uri.path.isEmpty || uri.path == '/') {
          uri = uri.replace(path: '/api/v1/mobile');
        }
        _api?.close();
        _api = MobileApiClient(
            baseUri: uri,
            tokenProvider: () async => null,
            allowLocalHttp: kDebugMode,
            client: widget.client);
        _baseUri = _api!.baseUri;
        _deviceId = await widget.vault.deviceId(_baseUri!, _email.text.trim());
        result = await _api!.login(
            email: _email.text.trim(),
            password: _password.text,
            deviceId: _deviceId!,
            deviceName: 'Inventario móvil');
      } else {
        result = await _api!.completeTwoFactor(
            challengeToken: _challenge!,
            code: _factor.text.trim(),
            recoveryCode: _recovery);
      }
      if (!mounted) return;
      if (result['status'] == 'two_factor_required') {
        final challenge = result['challenge_token'];
        if (challenge is! String || challenge.isEmpty) {
          throw const DataContractException(
              'El servidor no entregó un desafío válido.');
        }
        _password.clear();
        setState(() {
          _challenge = challenge;
        });
      } else {
        final saved = SavedInventorySession.fromLogin(_baseUri!, result);
        if (saved.session.deviceId != _deviceId) {
          throw const DataContractException(
              'El servidor respondió con otro dispositivo.');
        }
        await widget.onAuthenticated(saved);
        if (mounted) {
          _password.clear();
          _factor.clear();
        }
      }
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = inventoryErrorMessage(error);
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
              key: _form,
              child: AutofillGroup(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.inventory_2_outlined,
                      size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 20),
                  Text('Sistema de Inventario',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                      _challenge == null
                          ? 'Conecta una vez. Continúa el levantamiento sin conexión.'
                          : 'Completa la verificación de tu cuenta.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  if (_challenge == null) ...[
                    TextFormField(
                        key: const Key('login-email'),
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.text,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                            labelText: 'Usuario o correo electrónico',
                            prefixIcon: Icon(Icons.person_outline)),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                                ? 'Escribe tu usuario o correo electrónico.'
                                : value.trim().length > 255
                                    ? 'Usa un máximo de 255 caracteres.'
                                    : null),
                    const SizedBox(height: 16),
                    TextFormField(
                        key: const Key('login-password'),
                        controller: _password,
                        enabled: !_busy,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                            labelText: 'Contraseña',
                            prefixIcon: Icon(Icons.lock_outline)),
                        validator: (value) => value == null || value.isEmpty
                            ? 'Escribe tu contraseña.'
                            : null),
                    const SizedBox(height: 16),
                    ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Servidor de inventario'),
                        children: [
                          TextFormField(
                              key: const Key('login-server'),
                              controller: _server,
                              enabled: !_busy,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                  labelText: 'Dirección de la API',
                                  helperText:
                                      'Usa la dirección indicada por tu administrador.'),
                              validator: (value) {
                                final uri = Uri.tryParse(value?.trim() ?? '');
                                return uri == null ||
                                        !uri.hasAuthority ||
                                        !['http', 'https'].contains(uri.scheme)
                                    ? 'Escribe una dirección válida del servidor.'
                                    : null;
                              })
                        ]),
                  ] else ...[
                    TextFormField(
                        key: const Key('login-factor'),
                        controller: _factor,
                        enabled: !_busy,
                        keyboardType: _recovery
                            ? TextInputType.text
                            : TextInputType.number,
                        decoration: InputDecoration(
                            labelText: _recovery
                                ? 'Código de recuperación'
                                : 'Código de verificación'),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                                ? 'Escribe el código.'
                                : !_recovery &&
                                        !RegExp(r'^[0-9]{6}$')
                                            .hasMatch(value.trim())
                                    ? 'Escribe los 6 dígitos.'
                                    : null),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _recovery,
                        title: const Text('Usar código de recuperación'),
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                  _recovery = value;
                                  _factor.clear();
                                })),
                  ],
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Semantics(
                            liveRegion: true,
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)))),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                      key: const Key('login-submit'),
                      onPressed: _busy ? null : _submit,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login),
                      label: Text(_busy
                          ? 'Conectando…'
                          : _challenge == null
                              ? 'INGRESAR'
                              : 'Verificar y entrar')),
                  if (_challenge != null)
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _challenge = null;
                                  _factor.clear();
                                  _error = null;
                                }),
                        child: const Text('Volver al acceso')),
                ],
              ))),
        ),
      ))),
    );
  }
}
