import 'package:sqflite/sqflite.dart';
import '../data/database.dart';

class SQLiteHelper {
  static final SQLiteHelper _instancia = SQLiteHelper._interno();
  factory SQLiteHelper() => _instancia;
  SQLiteHelper._interno();

  // Share schema v2 with the offline repository; never reopen it at version 1.
  Future<Database> get bd => InventoryDatabase.shared.database;

  @Deprecated('Usa InventoryRepository.findByQr con el paquete seleccionado.')
  Future<Map<String, dynamic>> buscarBienPorQR(String qr) async {
    final base = await bd;
    final resultado = await base.query(
      'bienes',
      where: 'clave_activo = ?', 
      whereArgs: [qr],
    );
    
    // Si no encuentra nada, devuelve un diccionario vacío en lugar de null
    return resultado.isNotEmpty ? resultado.first : {};
  }

  @Deprecated('Solo conserva compatibilidad con los datos de prueba antiguos.')
  Future<void> insertarBienDePrueba(Map<String, dynamic> bien) async {
    final base = await bd;
    await base.insert(
      'bienes',
      bien,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
