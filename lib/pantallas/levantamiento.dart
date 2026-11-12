import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'login.dart';

class PantallaLevantamiento extends StatefulWidget {
  const PantallaLevantamiento({super.key});

  @override
  State<PantallaLevantamiento> createState() => _PantallaLevantamientoState();
}

class _PantallaLevantamientoState extends State<PantallaLevantamiento> {
  bool _camaraActiva = false;
  final MobileScannerController _controladorCamara = MobileScannerController();
  bool _mostrarResultado = false;
  String _qrActual = '';

  @override
  void dispose() {
    _controladorCamara.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('Levantamiento de inventario', style: TextStyle(fontSize: 18, color: Colors.black87)),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.blueGrey),
        leading: const Padding(
          padding: EdgeInsets.all(10.0),
          child: CircleAvatar(
            backgroundColor: Colors.indigo,
            child: Icon(Icons.change_history, color: Colors.white, size: 18),
          ),
        ),
      ),
      endDrawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              decoration: BoxDecoration(color: Colors.blueGrey.shade700),
              accountName: const Text('Joel Clemente Serrano', style: TextStyle(fontWeight: FontWeight.bold)),
              accountEmail: const Text('SuperUsuario'),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Text('JC', style: TextStyle(color: Colors.blueGrey, fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Cerrar sesión', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const PantallaLogin()),
                );
              },
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _construirTarjetaPeriodo(),
            const SizedBox(height: 16),
            _construirTarjetaDepartamento(),
            const SizedBox(height: 16),
            _construirTarjetaEscaner(),
            const SizedBox(height: 16),
            _construirTarjetaReasignacion(),
            const SizedBox(height: 16),
            _construirTarjetaAvance(),
          ],
        ),
      ),
    );
  }

  Widget _construirTarjetaPeriodo() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade600,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: const Row(
              children: [
                Icon(Icons.calendar_today, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text('Periodo de levantamiento', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _crearDropdownFalso('Año', '2026')),
                    const SizedBox(width: 16),
                    Expanded(child: _crearDropdownFalso('Mes', 'Noviembre')),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Nombre',
                    hintText: 'Ej. Levantamiento anual 2026',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade600, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text('Crear/Cargar periodo'),
                    onPressed: () {},
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.red.shade300),
                  icon: const Icon(Icons.lock),
                  label: const Text('Cerrar levantamiento'),
                  onPressed: null,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _construirTarjetaDepartamento() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.location_on, color: Colors.blueGrey),
                SizedBox(width: 10),
                Text('Departamento y ubicación', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            _crearDropdownFalso('Departamento *', 'Selecciona un departamento'),
            const SizedBox(height: 16),
            _crearDropdownFalso('Ubicación *', 'Selecciona una ubicación'),
            const SizedBox(height: 16),
            const Text(
              'Ambos campos son obligatorios para activar la cámara.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            )
          ],
        ),
      ),
    );
  }

  Widget _construirTarjetaEscaner() {
return Card(
  elevation: 2,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.qr_code_scanner),
                SizedBox(width: 10),
                Text('Escáner QR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            Row(
              children: [
                Icon(Icons.circle, color: _camaraActiva ? Colors.green : Colors.grey, size: 12),
                const SizedBox(width: 5),
                Text(_camaraActiva ? 'Cámara encendida' : 'Cámara apagada', style: TextStyle(color: _camaraActiva ? Colors.green : Colors.grey, fontSize: 12)),
              ],
            )
          ],
        ),
        const SizedBox(height: 16),
        Container(
          height: 250,
          width: double.infinity,
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.hardEdge, 
          child: _camaraActiva
              ? MobileScanner(
                  controller: _controladorCamara,
                  onDetect: (capture) {
                    final List<Barcode> codigos = capture.barcodes;
                    if (codigos.isNotEmpty && codigos.first.rawValue != null) {
                      // Al detectar el QR, apaga la cámara y muestra el resultado
                      setState(() {
                        _camaraActiva = false;
                        _qrActual = codigos.first.rawValue!;
                        _mostrarResultado = true;
                      });
                    }
                  },
                )
              : const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.camera_alt, color: Colors.white54, size: 40),
                    SizedBox(height: 10),
                    Text('Activa la cámara para escanear', style: TextStyle(color: Colors.white54)),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade300, foregroundColor: Colors.white),
                icon: const Icon(Icons.videocam),
                label: const Text('Activar cámara'),
                onPressed: _camaraActiva ? null : () {
                  setState(() {
                    _camaraActiva = true;
                    _mostrarResultado = false; // Oculta resultado anterior si lo hay
                  });
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.videocam_off, color: Colors.grey),
                label: const Text('Desactivar', style: TextStyle(color: Colors.grey)),
                onPressed: _camaraActiva ? () => setState(() => _camaraActiva = false) : null,
              ),
            ),
          ],
        ),
        
        // Aquí va inserta la tarjeta de información si se escaneó algo
        if (_mostrarResultado) _construirTarjetaResultadoQR(),
        
      ],
    ),
  ),
);
}

  Widget _construirTarjetaResultadoQR() {
  return Container(
    margin: const EdgeInsets.only(top: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
    color: Colors.white,
    border: Border.all(color: Colors.grey.shade300),
    borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
      Row(
        children: [
          Expanded(child: _crearDato('CLAVE ACTIVO FIJO', _qrActual)), // Usamos el QR real escaneado temporalmente
          Expanded(child: _crearDato('NO. INVENTARIO', '00002')),
        ],
      ),
      const SizedBox(height: 12),
      _crearDato('DESCRIPCIÓN DEL BIEN', 'ARCHIVERO CON 2 GAVETAS VERTICAL'),
      const SizedBox(height: 12),
      _crearDatoConIcono('RESGUARDANTE', 'MOBILIARIO EN MAL ESTADO Y OBSOLETO', Icons.person),
      const SizedBox(height: 12),
      _crearDatoConIcono('DEPARTAMENTO', 'DEPARTAMENTO DE RECURSOS MATERIALES', Icons.domain),
      const SizedBox(height: 16),
      const Text('Observaciones', style: TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
      const SizedBox(height: 5),
      TextFormField(
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.all(10)),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _mostrarResultado = false),
              child: const Text('Limpiar', style: TextStyle(color: Colors.black87)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade800, foregroundColor: Colors.white),
              icon: const Icon(Icons.check),
              label: const Text('Ok'),
              onPressed: () {
                // Lógica futura para guardar el escaneo en la base local
                setState(() => _mostrarResultado = false);
              },
            ),
          ),
        ],
      )
    ],
  ),
  );
}

// Funciones de apoyo para dibujar los textos del resultado limpios
Widget _crearDato(String titulo, String valor) {
return Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(titulo, style: const TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
    Text(valor, style: const TextStyle(fontSize: 14, color: Colors.black87)),
  ],
);
}

Widget _crearDatoConIcono(String titulo, String valor, IconData icono) {
return Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(titulo, style: const TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
    Row(
      children: [
        Icon(icono, size: 14, color: Colors.blueGrey),
        const SizedBox(width: 4),
        Expanded(child: Text(valor, style: const TextStyle(fontSize: 14, color: Colors.black87))),
      ],
    ),
  ],
);
}
  Widget _construirTarjetaReasignacion() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.swap_horiz),
                    SizedBox(width: 10),
                    Text('Reasignación', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade100, foregroundColor: Colors.orange.shade800, elevation: 0),
                  icon: const Icon(Icons.transfer_within_a_station, size: 16),
                  label: const Text('Reasignar'),
                  onPressed: () {},
                )
              ],
            ),
            const SizedBox(height: 16),
            const Text('Escanea un bien para poder reasignarlo.', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _construirTarjetaAvance() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.pie_chart),
                    SizedBox(width: 10),
                    Text('Avance del levantamiento', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                Text('Sin bienes', style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _crearCajaMetrica('0', 'REVISADOS', Colors.teal.shade50, Colors.teal),
                _crearCajaMetrica('0', 'PENDIENTES', Colors.grey.shade100, Colors.grey.shade600),
                _crearCajaMetrica('0', 'TOTAL', Colors.grey.shade100, Colors.grey.shade600),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _crearDropdownFalso(String label, String hint) {
    return DropdownButtonFormField<String>(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: const [],
      onChanged: (val) {},
      hint: Text(hint, style: const TextStyle(fontSize: 14)),
    );
  }

  Widget _crearCajaMetrica(String numero, String etiqueta, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: [
          Text(numero, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
          Text(etiqueta, style: TextStyle(fontSize: 10, color: textColor)),
        ],
      ),
    );
  }
}