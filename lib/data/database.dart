/* este archivo crea las tablas y columnas sonde se guardan datos permanentes */

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class InventoryDatabase {
  InventoryDatabase({DatabaseFactory? factory, String? path})
      : _factory = factory,
        _path = path;

  static final InventoryDatabase shared = InventoryDatabase();

  final DatabaseFactory? _factory;
  final String? _path;
  Future<Database>? _opening;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    try {
      final factory = _factory ?? databaseFactory;
      final path = _path ??
          p.join(await factory.getDatabasesPath(), 'inventario_offline.db');
      return await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onConfigure: (db) async {
            // SQLite cannot change foreign_keys inside the upgrade transaction.
            // Only v2 needs table rebuilding; checks run before its commit.
            final previous = await db.getVersion();
            await db.execute(
                'PRAGMA foreign_keys = ${previous == 2 ? 'OFF' : 'ON'}');
          },
          onCreate: (db, version) => _createSchema(db),
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) {
              await _createSchema(db);
            } else if (oldVersion < 3) {
              await _upgradeV3(db);
            }
          },
          onOpen: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
            if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
              throw StateError(
                  'La base local contiene referencias inconsistentes.');
            }
          },
        ),
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<void> close() async {
    final opening = _opening;
    if (opening == null) return;
    await (await opening).close();
    _opening = null;
  }

  static Future<void> _createSchema(Database db) async {
    // Keep the prototype's v1 table intact when opening an existing installation.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bienes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        clave_activo TEXT UNIQUE,
        no_inventario TEXT,
        descripcion TEXT,
        resguardante TEXT,
        departamento TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE packages (
        package_id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        periodo_id TEXT NOT NULL,
        numero_departamento TEXT NOT NULL,
        ubicacion_id TEXT,
        manifest_json TEXT NOT NULL,
        period_json TEXT,
        status TEXT NOT NULL CHECK (status IN ('staging', 'ready', 'failed')),
        active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1)),
        created_at TEXT NOT NULL,
        CHECK (active = 0 OR status = 'ready')
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX packages_active_scope
      ON packages (user_id, device_id, periodo_id, numero_departamento,
                   COALESCE(ubicacion_id, ''))
      WHERE active = 1 AND status = 'ready'
    ''');
    await db.execute(_itemsSql('items'));
    await _itemsIndex(db);
    await db.execute('''
      CREATE TABLE departments (
        package_id TEXT NOT NULL,
        numero_departamento TEXT NOT NULL,
        descripcion TEXT,
        PRIMARY KEY (package_id, numero_departamento),
        FOREIGN KEY (package_id) REFERENCES packages (package_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE locations (
        package_id TEXT NOT NULL,
        id TEXT NOT NULL,
        numero_departamento TEXT,
        descripcion TEXT,
        PRIMARY KEY (package_id, id),
        FOREIGN KEY (package_id) REFERENCES packages (package_id)
      )
    ''');
    await db.execute(_employeesSql('employees'));
    await _createQueue(db);
  }

  static String _itemsSql(String table) => '''
      CREATE TABLE $table (
        package_id TEXT NOT NULL,
        detalle_id TEXT NOT NULL,
        snapshot_id TEXT,
        clave_activo_fijo TEXT COLLATE BINARY NOT NULL,
        numero_inventario_consecutivo TEXT COLLATE BINARY NOT NULL,
        numero_departamento_inicial TEXT,
        ubicacion_id_inicial TEXT,
        numero_departamento_actual TEXT,
        ubicacion_id_actual TEXT,
        revisado INTEGER NOT NULL DEFAULT 0 CHECK (revisado IN (0, 1)),
        revisado_por_id TEXT,
        revisado_por_nombre TEXT,
        observaciones TEXT,
        resguardante_id TEXT,
        resguardante_nombre TEXT,
        version_json TEXT NOT NULL,
        original_json TEXT NOT NULL,
        current_json TEXT,
        needs_refresh INTEGER NOT NULL DEFAULT 0 CHECK (needs_refresh IN (0, 1)),
        PRIMARY KEY (package_id, detalle_id),
        UNIQUE (package_id, snapshot_id),
        UNIQUE (package_id, clave_activo_fijo),
        FOREIGN KEY (package_id) REFERENCES packages (package_id)
      )
    ''';

  static Future<void> _itemsIndex(Database db) => db.execute('''
      CREATE INDEX items_inventory_literal
      ON items (package_id, numero_inventario_consecutivo COLLATE BINARY)
    ''');

  static String _employeesSql(String table) => '''
      CREATE TABLE $table (
        package_id TEXT NOT NULL,
        clave_empleado TEXT NOT NULL,
        numero_departamento TEXT,
        nombre_completo TEXT,
        PRIMARY KEY (package_id, clave_empleado),
        FOREIGN KEY (package_id) REFERENCES packages (package_id)
      )
    ''';

  static Future<void> _upgradeV3(Database db) async {
    // Keep queue, UUIDs, payload bytes and their trigger in place. Rebuild only
    // the two tables whose nullable columns changed, within one transaction.
    await db.execute(_itemsSql('items_v3'));
    await db.execute('INSERT INTO items_v3 SELECT * FROM items');
    await db.execute('DROP TABLE items');
    await db.execute('ALTER TABLE items_v3 RENAME TO items');
    await _itemsIndex(db);
    await db.execute(_employeesSql('employees_v3'));
    await db.execute('INSERT INTO employees_v3 SELECT * FROM employees');
    await db.execute('DROP TABLE employees');
    await db.execute('ALTER TABLE employees_v3 RENAME TO employees');
    if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw StateError(
          'No se pudo migrar la base local conservando sus referencias.');
    }
  }

  static Future<void> _createQueue(Database db) async {
    await db.execute('''
      CREATE TABLE sync_queue (
        operation_uuid TEXT PRIMARY KEY,
        package_id TEXT NOT NULL,
        detalle_id TEXT NOT NULL,
        type TEXT NOT NULL,
        operation_json TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        expected_version_json TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending', 'synced', 'conflict', 'error')),
        attempts INTEGER NOT NULL DEFAULT 0,
        submitted_at TEXT,
        next_attempt_at TEXT,
        last_error TEXT,
        receipt_json TEXT,
        created_at TEXT NOT NULL,
        synced_at TEXT,
        resolved_at TEXT,
        FOREIGN KEY (package_id) REFERENCES packages (package_id),
        FOREIGN KEY (package_id, detalle_id) REFERENCES items (package_id, detalle_id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX sync_queue_pending_item
      ON sync_queue (package_id, detalle_id)
      WHERE status = 'pending'
    ''');
    await db.execute('''
      CREATE INDEX sync_queue_retry
      ON sync_queue (status, next_attempt_at, created_at)
    ''');
    await db.execute('''
      CREATE TRIGGER sync_queue_immutable_operation
      BEFORE UPDATE OF operation_uuid, package_id, detalle_id, type, operation_json
      ON sync_queue
      WHEN NEW.operation_uuid IS NOT OLD.operation_uuid
        OR NEW.package_id IS NOT OLD.package_id
        OR NEW.detalle_id IS NOT OLD.detalle_id
        OR NEW.type IS NOT OLD.type
        OR NEW.operation_json IS NOT OLD.operation_json
      BEGIN
        SELECT RAISE(ABORT, 'Queued operation identity and content are immutable');
      END
    ''');
  }
}
