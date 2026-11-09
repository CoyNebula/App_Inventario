import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class SQLiteHelper {
  static final SQLiteHelper _instancia = SQLiteHelper._interno();
  factory SQLiteHelper() => _instancia;
  SQLiteHelper._interno();

  static var _bd;

  Future<Database> get bd async {
    if (_bd != null) return _bd;
    _bd = await _iniciarBD();
    return _bd;
  }

  Future<Database> _iniciarBD() async {
    String rutaBase = await getDatabasesPath();
    String rutaBD = join(rutaBase, 'inventario_offline.db');

    return await openDatabase(
      rutaBD,
      version: 1,
      onCreate: _crearTablas,
    );
  }

  Future<void> _crearTablas(Database bd, int version) async {
    await bd.execute('''
      CREATE TABLE bienes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        clave_activo TEXT UNIQUE,
        no_inventario TEXT,
        descripcion TEXT,
        resguardante TEXT,
        departamento TEXT
      )
    ''');
  }

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

  Future<void> insertarBienDePrueba(Map<String, dynamic> bien) async {
    final base = await bd;
    await base.insert(
      'bienes',
      bien,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}