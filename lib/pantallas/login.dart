import 'dart:convert';
import 'package:flutter/material.dart';
import 'levantamiento.dart'; 
import 'package:http/http.dart' as http;
import 'levantamiento.dart';
import '../bd/sincronizacion.dart';

class PantallaLogin extends StatelessWidget {
class PantallaLogin extends StatefulWidget {
  const PantallaLogin({super.key});

  @override
  State<PantallaLogin> createState() => _PantallaLoginState();
}

class _PantallaLoginState extends State<PantallaLogin> {
  // Controladores para capturar el texto de los campos
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _cargando = false;

  // Usamos la misma IP de red local configurada en Sincronizacion (172.17.3.18)
  // Si usas emulador Android puedes cambiarla a: 'http://10.0.2.2:8000/api/v1/mobile/auth/login'
  static const String _urlLogin =
      'http://172.17.3.18:8000/api/v1/mobile/auth/login';

  @override
  void dispose() {
    // Liberamos memoria al destruir el widget (buena práctica Senior)
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _iniciarSesion() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _mostrarSnackBar(
        'Por favor, ingresa tu correo y contraseña.',
        esError: true,
      );
      return;
    }

    setState(() => _cargando = true);

    // Payload estricto requerido por AuthPayload.php en Laravel
    final Map<String, dynamic> payload = {
      "email": email,
      "password": password,
      "device": {
        "id": "550e8400-e29b-41d4-a716-446655440000", // UUID v4 válido estático
        "name": "DispositivoInventarioAndroid",
        "platform": "android",
        "app_version": "1.0.0",
      },
    };

    try {
      final respuesta = await http.post(
        Uri.parse(_urlLogin),
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json', // Clave para que Laravel devuelva errores 422 en JSON y no redirija
        },
        body: jsonEncode(payload),
      );

      if (!mounted) return;

      if (respuesta.statusCode == 200 || respuesta.statusCode == 202) {
        _mostrarSnackBar(
          '¡Inicio de sesión exitoso! (Código ${respuesta.statusCode})',
          esError: false,
        );

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const PantallaLevantamiento(),
          ),
        );
      } else {
        // Intentamos extraer el mensaje de error de Laravel (ej. 401 o 422)
        String detalleError = respuesta.body;
        try {
          final Map<String, dynamic> bodyJson = jsonDecode(respuesta.body);
          if (bodyJson.containsKey('message')) {
            detalleError = bodyJson['message'].toString();
          }
        } catch (_) {}

        _mostrarSnackBar(
          'Error ${respuesta.statusCode}: $detalleError',
          esError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _mostrarSnackBar(
        'Error de conexión con el servidor: $e',
        esError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  void _mostrarSnackBar(String mensaje, {required bool esError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensaje),
        backgroundColor: esError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2, size: 100, color: Colors.blue.shade900),
            const SizedBox(height: 20),
            const Text(
              'Sistema de Inventario',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Usuario',
                labelText: 'Usuario (Correo)',
                prefixIcon: Icon(Icons.person),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Contraseña',
                prefixIcon: Icon(Icons.lock),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade900,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  // Salto directo al levantamiento, como indicó Joel
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => const PantallaLevantamiento()),
                  );
                },
                child: const Text('INGRESAR', style: TextStyle(fontSize: 16)),
                onPressed: _cargando ? null : _iniciarSesion,
                child: _cargando
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      )
                    : const Text('INGRESAR', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
        floatingActionButton: FloatingActionButton(
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Sincronizacion.descargarBienes();
        },
        child: const Icon(Icons.download),
      ),
    ); // <- Fin del Scaffold
  }   
    );
  }
}