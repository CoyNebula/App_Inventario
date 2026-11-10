import 'dart:convert';
import 'package:http/http.dart' as http;
import 'sqlite_helper.dart';

class Sincronizacion {
  // ATENCIÓN CON LA URL:
  // Si pruebas en el emulador de Android usa: 'http://10.0.2.2:8000/api/bienes'
  // Si pruebas en un celular físico usa la IP de tu PC por Wi-Fi, ej: 'http://192.168.1.70:8000/api/bienes'
  // Si pruebas como aplicación de Windows usa: 'http://127.0.0.1:8000/api/bienes'
  static const String urlApi = 'http://10.0.2.2:8000/api/bienes';

  static Future<void> descargarBienes() async {
    print("Iniciando descarga de bienes...");
    
    try {
      final respuesta = await http.get(Uri.parse(urlApi));

      if (respuesta.statusCode == 200) {
        final List<dynamic> datosJson = json.decode(respuesta.body);
        final bdHelper = SQLiteHelper();

        for (var item in datosJson) {
          // Extraemos y aseguramos que no vengan nulos
          String clave = item['clave_activo_fijo'] ?? '';
          String noInventario = item['numero_inventario_consecutivo'] ?? '';
          String descripcion = item['descripcion'] ?? '';
          
          // Extraemos el departamento (viene anidado en el JSON)
          String departamento = '';
          if (item['departamento'] != null) {
            departamento = item['departamento']['descripcion'] ?? '';
          }

          // Extraemos el resguardante (viene anidado doble)
          String resguardante = '';
          if (item['resguardo'] != null && item['resguardo']['empleado'] != null) {
            resguardante = item['resguardo']['empleado']['nombre_completo'] ?? '';
          }

          // Armamos el diccionario exacto que espera SQLite
          Map<String, dynamic> bienLocal = {
            'clave_activo': clave,
            'no_inventario': noInventario,
            'descripcion': descripcion,
            'resguardante': resguardante,
            'departamento': departamento,
          };

          // Insertamos en el celular (usa el método que ya teníamos)
          await bdHelper.insertarBienDePrueba(bienLocal);
        }
        
        print("¡Sincronización exitosa! Se guardaron ${datosJson.length} bienes en el celular.");
      } else {
        print("Error en el servidor de Laravel: Código ${respuesta.statusCode}");
      }
    } catch (e) {
      print("Error de conexión: $e");
    }
  }
}