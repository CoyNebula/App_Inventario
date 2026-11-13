/* descarga ubicaciones
busca el bien localmente
guarda una revision
registra una reasignacion
calcula avance */

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'api_client.dart';
import 'database.dart';
import 'models.dart';
import 'qr.dart';

/// SQLite is the only source consulted during field work. Remote snapshots and
/// the local projection are stored separately; downloading never overwrites work.
class InventoryRepository {
  final InventoryDatabase database;
  final MobileApiClient api;
  final MobileSession session;
  final DateTime Function() clock;

  InventoryRepository(
      {required this.database,
      required this.api,
      required this.session,
      DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  Future<List<JsonMap>> departments(String periodId) =>
      api.departments(periodId);
  Future<List<JsonMap>> locations(String periodId, String departmentNumber) =>
      api.locations(periodId, departmentNumber);

  Future<String> downloadLocation(
      {required String periodId,
      required String departmentNumber,
      required String locationId,
      bool includeReassignmentCatalogs = true,
      String? packageId,
      void Function(int received, int total)? onDownloadProgress}) async {
    final downloadApi = await api.credentialSnapshot();
    final online = await downloadApi.getSession();
    _checkOwner(online.userId, online.deviceId);
    final periods = await downloadApi.periods();
    final selected = periods
        .where((p) =>
            p['id'] == periodId &&
            p['estado'] == 'abierto' &&
            p['mobile_eligible'] == true)
        .toList();
    if (selected.length != 1) {
      throw const DataContractException(
          'Selecciona un periodo abierto y autorizado.');
    }
    final manifest = await downloadApi.createPackage(
        packageId: packageId ?? newOperationUuid(),
        periodId: periodId,
        departmentNumber: departmentNumber,
        locationId: locationId,
        includeReassignmentCatalogs: includeReassignmentCatalogs);
    if (manifest.periodId != periodId ||
        manifest.departmentNumber != departmentNumber ||
        manifest.locationId != locationId) {
      throw const DataContractException(
          'El paquete no corresponde al sitio solicitado.');
    }
    return installPackage(manifest,
        period: selected.single,
        pageSource: downloadApi,
        onDownloadProgress: onDownloadProgress);
  }

  /// A failed download stays inactive. The same immutable package can be resumed
  /// by retrieving its manifest and reinstalling all pages (no partial publication).
  Future<String> resumeDownload(String packageId,
      {required JsonMap period}) async {
    final downloadApi = await api.credentialSnapshot();
    return installPackage(await downloadApi.manifest(packageId),
        period: period, pageSource: downloadApi);
  }

  Future<String> installPackage(PackageManifest manifest,
      {required JsonMap period,
      MobileApiClient? pageSource,
      void Function(int received, int total)? onDownloadProgress}) async {
    _checkOwner(manifest.userId, manifest.deviceId);
    if (period['id'] != manifest.periodId ||
        period['estado'] != 'abierto' ||
        !manifest.downloadExpiresAt.isAfter(clock().toUtc()) ||
        !manifest.offlineUntil.isAfter(clock().toUtc())) {
      throw const DataContractException(
          'El periodo o la vigencia del paquete no permiten descargarlo.');
    }
    final downloadApi = pageSource ?? await api.credentialSnapshot();
    final db = await database.database;
    final existing = await db.query('packages',
        where: 'package_id = ?', whereArgs: [manifest.packageId]);
    if (existing.isNotEmpty) {
      if (existing.single['user_id'] != session.userId ||
          existing.single['device_id'] != session.deviceId ||
          existing.single['manifest_json'] != jsonEncode(manifest.toJson())) {
        throw const DataContractException(
            'El UUID del paquete ya tiene otro contexto.');
      }
      if (existing.single['status'] == 'ready') return manifest.packageId;
    }
    await db.transaction((tx) async {
      if (existing.isNotEmpty) {
        if (Sqflite.firstIntValue(await tx.rawQuery(
                'SELECT COUNT(*) FROM sync_queue WHERE package_id = ?',
                [manifest.packageId])) !=
            0) {
          throw const DataContractException(
              'El paquete contiene operaciones y no puede reemplazarse.');
        }
        for (final table in [
          'items',
          'departments',
          'locations',
          'employees'
        ]) {
          await tx.delete(table,
              where: 'package_id = ?', whereArgs: [manifest.packageId]);
        }
        await tx.update('packages', {'status': 'staging', 'active': 0},
            where: 'package_id = ?', whereArgs: [manifest.packageId]);
      } else {
        await tx.insert('packages', {
          'package_id': manifest.packageId,
          'user_id': manifest.userId,
          'device_id': manifest.deviceId,
          'periodo_id': manifest.periodId,
          'numero_departamento': manifest.departmentNumber,
          'ubicacion_id': manifest.locationId,
          'manifest_json': jsonEncode(manifest.toJson()),
          'period_json': jsonEncode(period),
          'status': 'staging',
          'active': 0,
          'created_at': clock().toUtc().toIso8601String(),
        });
      }
    });
    try {
      onDownloadProgress?.call(0, manifest.pages.length);
      for (final descriptor in manifest.pages) {
        final bytes =
            await downloadApi.packagePage(manifest.packageId, descriptor.page);
        if (bytes.length != descriptor.bytes ||
            sha256.convert(bytes).toString() != descriptor.sha256) {
          throw const DataContractException('Integridad de página incorrecta.');
        }
        final page = jsonObject(jsonDecode(utf8.decode(bytes)));
        if (page['package_id'] != manifest.packageId ||
            page['page'] != descriptor.page ||
            page['schema_version'] != '1') {
          throw const DataContractException(
              'La página pertenece a otro paquete o versión.');
        }
        for (final collection in packageCollections) {
          if (page[collection] is! List ||
              (page[collection] as List).length !=
                  descriptor.counts[collection]) {
            throw const DataContractException('Conteo de página incorrecto.');
          }
        }
        await db.transaction((tx) async {
          final batch = tx.batch();
          for (final raw in page['items'] as List) {
            final item = InventoryItem.fromJson(jsonObject(raw));
            if (item.snapshotId == null && !manifest.isLegacy) {
              throw const DataContractException(
                  'Bien sin instantánea en un periodo oficial.');
            }
            final json = item.toJson();
            if (json['numero_departamento_inicial'] !=
                    manifest.departmentNumber ||
                (manifest.locationId != null &&
                    json['ubicacion_id_inicial'] != manifest.locationId)) {
              throw const DataContractException(
                  'Bien fuera del ámbito del paquete.');
            }
            batch.insert('items', item.toDatabaseRow(manifest.packageId));
          }
          for (final raw in page['departamentos'] as List) {
            final row = jsonObject(raw);
            batch.insert('departments', {
              'package_id': manifest.packageId,
              'numero_departamento':
                  textId(row['numero_departamento'], signed: true),
              'descripcion': row['descripcion'] as String?
            });
          }
          for (final raw in page['ubicaciones'] as List) {
            final row = jsonObject(raw);
            batch.insert('locations', {
              'package_id': manifest.packageId,
              'id': textId(row['id']),
              'numero_departamento':
                  nullableId(row['numero_departamento'], signed: true),
              'descripcion': row['descripcion'] as String?
            });
          }
          for (final raw in page['empleados'] as List) {
            final row = jsonObject(raw);
            batch.insert('employees', {
              'package_id': manifest.packageId,
              'clave_empleado': textId(row['clave_empleado'], signed: true),
              'numero_departamento':
                  nullableId(row['numero_departamento'], signed: true),
              'nombre_completo': row['nombre_completo'] as String?
            });
          }
          await batch.commit(noResult: true);
        });
        onDownloadProgress?.call(descriptor.page, manifest.pages.length);
      }
      await db.transaction((tx) async {
        const tables = {
          'items': 'items',
          'departamentos': 'departments',
          'ubicaciones': 'locations',
          'empleados': 'employees'
        };
        for (final collection in packageCollections) {
          final count = Sqflite.firstIntValue(await tx.rawQuery(
              'SELECT COUNT(*) FROM ' +
                  tables[collection]! +
                  ' WHERE package_id = ?',
              [manifest.packageId]));
          if (count != manifest.counts[collection]) {
            throw const DataContractException(
                'Paquete incompleto o con registros duplicados.');
          }
        }
        await _validateReferences(tx, manifest.packageId);
        if (!manifest.offlineUntil.isAfter(clock().toUtc()) ||
            !manifest.downloadExpiresAt.isAfter(clock().toUtc())) {
          throw const DataContractException(
              'La descarga venció antes de completarse.');
        }
        final pending = Sqflite.firstIntValue(await tx.rawQuery('''
          SELECT COUNT(*) FROM sync_queue q JOIN packages p ON p.package_id=q.package_id
          WHERE p.user_id=? AND p.device_id=? AND p.periodo_id=?
            AND p.numero_departamento=? AND p.ubicacion_id IS ?
            AND q.status<>'synced' AND q.resolved_at IS NULL
        ''', [
          session.userId,
          session.deviceId,
          manifest.periodId,
          manifest.departmentNumber,
          manifest.locationId
        ]));
        if (pending != 0) {
          throw const DataContractException(
              'Resuelve las operaciones locales antes de refrescar esta ubicación.');
        }
        await tx.update('packages', {
          'active': 0
        }, where: '''
          user_id=? AND device_id=? AND periodo_id=? AND numero_departamento=? AND ubicacion_id IS ?
        ''', whereArgs: [
          session.userId,
          session.deviceId,
          manifest.periodId,
          manifest.departmentNumber,
          manifest.locationId
        ]);
        await tx.update('packages', {'status': 'ready', 'active': 1},
            where: 'package_id=?', whereArgs: [manifest.packageId]);
      });
      return manifest.packageId;
    } catch (_) {
      await db.update('packages', {'status': 'failed', 'active': 0},
          where: 'package_id=? AND status<>?',
          whereArgs: [manifest.packageId, 'ready']);
      rethrow;
    }
  }

  Future<void> _validateReferences(
      DatabaseExecutor db, String packageId) async {
    final departmentRows = await db
        .query('departments', where: 'package_id=?', whereArgs: [packageId]);
    final departments =
        departmentRows.map((d) => d['numero_departamento']).toSet();
    final locationRows = await db
        .query('locations', where: 'package_id=?', whereArgs: [packageId]);
    final locations = {
      for (final location in locationRows) location['id'] as String: location
    };
    for (final location in locationRows) {
      final department = location['numero_departamento'];
      if (department != null && !departments.contains(department)) {
        throw const DataContractException(
            'Ubicación sin departamento en el paquete.');
      }
    }
    // An employee's affiliation is not a destination permission. The Web can
    // reassign an employee to another department or one without prior affiliation.
    final items = await db.query('items',
        columns: ['current_json'],
        where: 'package_id=?',
        whereArgs: [packageId]);
    for (final row in items) {
      final item = InventoryItem.fromJson(
          jsonObject(jsonDecode(row['current_json'] as String)));
      if (item.restricted) continue;
      final current = item.current;
      if (current == null ||
          !departments.contains(current['numero_departamento'])) {
        throw const DataContractException(
            'Bien visible sin departamento en el paquete.');
      }
      final locationId = current['ubicacion_id'];
      if (locationId != null &&
          (!locations.containsKey(locationId) ||
              locations[locationId]!['numero_departamento'] !=
                  current['numero_departamento'])) {
        throw const DataContractException(
            'La ubicación actual no corresponde al departamento del bien.');
      }
      // Initial references are historical: their current catalog entry may
      // legitimately be absent or belong to another department.
    }
  }

  Future<Map<String, Object?>> _ready(DatabaseExecutor db, String packageId,
      {bool active = false}) async {
    final rows = await db.query('packages',
        where: 'package_id=? AND user_id=? AND device_id=? AND status=?',
        whereArgs: [packageId, session.userId, session.deviceId, 'ready']);
    if (rows.length != 1 || (active && rows.single['active'] != 1)) {
      throw const DataContractException(
          'Paquete local no disponible para esta cuenta y dispositivo.');
    }
    return rows.single;
  }

  void _checkOwner(String userId, String deviceId) {
    if (userId != session.userId || deviceId != session.deviceId) {
      throw const DataContractException(
          'La sesión pertenece a otra cuenta o dispositivo.');
    }
  }

  Future<List<JsonMap>> downloadedPackages() async {
    final db = await database.database;
    return (await db.query('packages',
            where: 'user_id=? AND device_id=? AND status=? AND active=1',
            whereArgs: [session.userId, session.deviceId, 'ready'],
            orderBy: 'created_at DESC'))
        .map((p) => jsonObject(jsonDecode(p['manifest_json'] as String)))
        .toList();
  }

  Future<List<QueuedOperation>> operations() async {
    final db = await database.database;
    final rows = await db.rawQuery('''
      SELECT q.* FROM sync_queue q JOIN packages p ON p.package_id=q.package_id
      WHERE p.user_id=? AND p.device_id=? ORDER BY q.created_at, q.operation_uuid
    ''', [session.userId, session.deviceId]);
    return rows.map(QueuedOperation.fromRow).toList(growable: false);
  }

  Future<InventoryProgress> progress(String packageId) async {
    final db = await database.database;
    final package = await _ready(db, packageId);
    final manifest = PackageManifest.fromJson(
        jsonObject(jsonDecode(package['manifest_json'] as String)));
    var filter = 'package_id=?';
    final args = <Object?>[packageId];
    if (manifest.isLegacy) {
      filter += ' AND numero_departamento_actual=?';
      args.add(manifest.departmentNumber);
      if (manifest.locationId != null) {
        filter += ' AND ubicacion_id_actual=?';
        args.add(manifest.locationId);
      }
    }
    final row = (await db.rawQuery(
            'SELECT COUNT(*) AS total, COALESCE(SUM(revisado),0) AS reviewed FROM items WHERE $filter',
            args))
        .single;
    return InventoryProgress(
        total: row['total'] as int, reviewed: row['reviewed'] as int);
  }

  Future<InventoryPeriod?> periodForPackage(String packageId) async {
    final db = await database.database;
    final package = await _ready(db, packageId);
    final raw = package['period_json'];
    return raw == null
        ? null
        : InventoryPeriod.fromJson(jsonObject(jsonDecode(raw as String)));
  }

  Future<void> updatePeriodState(InventoryPeriod period) async {
    final db = await database.database;
    await db.update('packages', {'period_json': jsonEncode(period.toJson())},
        where: 'periodo_id=? AND user_id=? AND device_id=?',
        whereArgs: [period.id, session.userId, session.deviceId]);
  }

  Future<InventoryItem?> item(String packageId, String detailId) async {
    final db = await database.database;
    await _ready(db, packageId);
    final rows = await db.query('items',
        where: 'package_id=? AND detalle_id=?',
        whereArgs: [packageId, detailId]);
    return rows.isEmpty
        ? null
        : InventoryItem.fromJson(
            jsonObject(jsonDecode(rows.single['current_json'] as String)));
  }

  Future<QrLookupResult> findByQr(String packageId, String raw) async {
    final db = await database.database;
    await _ready(db, packageId);
    final ids = parseInventoryQr(raw);
    final clauses = <String>['package_id=?'];
    final args = <Object?>[packageId];
    for (final entry in ids.entries) {
      clauses.add(entry.key + ' = ? COLLATE BINARY');
      args.add(entry.value);
    }
    final rows = await db.query('items',
        where: clauses.join(' AND '), whereArgs: args, limit: 2);
    if (rows.isEmpty) return const QrLookupResult(QrLookupStatus.notAvailable);
    if (rows.length > 1) return const QrLookupResult(QrLookupStatus.ambiguous);
    return QrLookupResult(
        QrLookupStatus.found,
        InventoryItem.fromJson(
            jsonObject(jsonDecode(rows.single['current_json'] as String))));
  }

  Future<List<Map<String, Object?>>> localEmployees(String packageId) =>
      _catalogue(packageId, 'employees');
  Future<List<Map<String, Object?>>> localDepartments(String packageId) =>
      _catalogue(packageId, 'departments');
  Future<List<Map<String, Object?>>> localLocations(String packageId) =>
      _catalogue(packageId, 'locations');

  Future<List<Map<String, Object?>>> _catalogue(
      String packageId, String table) async {
    final db = await database.database;
    await _ready(db, packageId);
    return db.query(table, where: 'package_id=?', whereArgs: [packageId]);
  }

  Future<String> confirmReview(String packageId, String detailId,
          {String? observations, String? rawQr}) =>
      _capture(packageId, detailId, SyncCommand.confirmReview,
          {'observaciones': observations},
          rawQr: rawQr);

  Future<String> updateObservations(String packageId, String detailId,
          {String? observations}) =>
      _capture(packageId, detailId, SyncCommand.updateObservations,
          {'observaciones': observations});

  Future<String> proposeReassignment(String packageId, String detailId,
          {required String employeeId,
          required String date,
          required String departmentNumber,
          required String locationId,
          String? observations}) =>
      _capture(packageId, detailId, SyncCommand.proposeReassignment, {
        'empleado_id': textId(employeeId, signed: true),
        'fecha_resguardo': date,
        'numero_departamento': textId(departmentNumber, signed: true),
        'ubicacion_id': textId(locationId),
        'observaciones': observations
      });

  Future<String> _capture(
      String packageId, String detailId, SyncCommand command, JsonMap payload,
      {String? rawQr}) async {
    final db = await database.database;
    return db.transaction((tx) async {
      final package = await _ready(tx, packageId, active: true);
      final rawPeriod = package['period_json'];
      if (rawPeriod != null &&
          jsonObject(jsonDecode(rawPeriod as String))['estado'] != 'abierto') {
        throw const DataContractException(
            'El periodo está cerrado; no admite nuevas capturas.');
      }
      final manifest = PackageManifest.fromJson(
          jsonObject(jsonDecode(package['manifest_json'] as String)));
      if (!manifest.offlineUntil.isAfter(clock().toUtc()) ||
          (session.offlineUntil != null &&
              !session.offlineUntil!.isAfter(clock().toUtc()))) {
        throw const DataContractException(
            'La autorización offline venció. Conecta para renovarla.');
      }
      if (!session.commands.contains(command.wireName) ||
          !session.permissions.contains('hacer_levantamiento')) {
        throw const DataContractException(
            'La sesión no autoriza este comando.');
      }
      final observations = payload['observaciones'];
      if (observations != null &&
          (observations is! String || observations.runes.length > 5000)) {
        throw const DataContractException(
            'Las observaciones exceden 5000 caracteres.');
      }
      final rows = await tx.query('items',
          where: 'package_id=? AND detalle_id=?',
          whereArgs: [packageId, detailId]);
      if (rows.length != 1)
        throw const DataContractException('No disponible en esta descarga');
      final row = rows.single;
      final original = InventoryItem.fromJson(
          jsonObject(jsonDecode(row['original_json'] as String)));
      final current = InventoryItem.fromJson(
          jsonObject(jsonDecode(row['current_json'] as String)));
      if (row['needs_refresh'] == 1) {
        throw const DataContractException(
            'Actualiza el paquete antes de realizar otra acción sobre este bien.');
      }
      final unresolved = Sqflite.firstIntValue(await tx.rawQuery('''
        SELECT COUNT(*) FROM sync_queue q JOIN packages p ON p.package_id=q.package_id
        WHERE p.user_id=? AND p.device_id=? AND q.detalle_id=?
          AND q.status<>'synced' AND q.resolved_at IS NULL
      ''', [session.userId, session.deviceId, detailId]));
      if (unresolved != 0) {
        throw const DataContractException(
            'Este bien tiene una operación sin resolver. Sincroniza antes de registrar otra.');
      }
      if (!current.editable ||
          current.restricted ||
          (current.reviewed && current.reviewedById != session.userId)) {
        throw const DataContractException('El bien es de solo lectura.');
      }
      if (command == SyncCommand.confirmReview && original.reviewed ||
          command == SyncCommand.updateObservations &&
              (!original.reviewed || original.reviewedById != session.userId)) {
        throw const DataContractException(
            'El comando no corresponde al estado original del bien.');
      }
      final projected = current.toJson();
      projected['revisado'] = true;
      projected['revisado_por_id'] = session.userId;
      projected['revisado_por_nombre'] = session.userName;
      projected['observaciones'] = observations == '' ? null : observations;
      if (command == SyncCommand.proposeReassignment) {
        if (!session.permissions.contains('asignar') ||
            current.version['resguardo_id'] == null) {
          throw const DataContractException(
              'Reasignación no autorizada o sin resguardo vigente.');
        }
        _validateDate(payload['fecha_resguardo'] as String);
        final employees = await tx.query('employees',
            where: 'package_id=? AND clave_empleado=?',
            whereArgs: [packageId, payload['empleado_id']]);
        final destinations = await tx.query('locations',
            where: 'package_id=? AND id=? AND numero_departamento=?',
            whereArgs: [
              packageId,
              payload['ubicacion_id'],
              payload['numero_departamento']
            ]);
        if (employees.length != 1 || destinations.length != 1) {
          throw const DataContractException(
              'Empleado o destino no disponible en los catálogos autorizados.');
        }
        final oldCustodian = jsonObject(current.current!['resguardante']);
        if (oldCustodian['clave_empleado'] == payload['empleado_id']) {
          throw const DataContractException(
              'El bien ya está en resguardo de este empleado.');
        }
        final updated = jsonObject(projected['actual']);
        updated['numero_departamento'] = payload['numero_departamento'];
        updated['ubicacion_id'] = payload['ubicacion_id'];
        updated['resguardante'] = {
          'clave_empleado': payload['empleado_id'],
          'nombre_completo': employees.single['nombre_completo']
        };
        // The server appends the official movement legend; refresh after its receipt.
        projected['observaciones'] = observations == '' ? null : observations;
      }
      JsonMap? qr;
      if (rawQr != null) {
        qr = parseInventoryQr(rawQr);
        final identity = original.identity.toJson();
        if (qr.entries.any((e) => identity[e.key] != e.value)) {
          throw const DataContractException(
              'Los identificadores del QR son contradictorios.');
        }
      }
      final id = newOperationUuid();
      final now = clock().toUtc().toIso8601String();
      final operation = <String, dynamic>{
        'operation_id': id,
        'user_id': session.userId,
        'device_id': session.deviceId,
        'package_id': packageId,
        'periodo_id': manifest.periodId,
        'detalle_id': detailId,
        'bien': original.identity.toJson(),
        'expected_version': original.version,
        'original': original.originalValues(),
        'captured_at': now,
        'type': command.wireName,
        'payload': payload,
        if (qr != null) 'qr': qr
      };
      if (utf8
              .encode(jsonEncode({
                'batch_id': id,
                'operations': [operation]
              }))
              .length >
          1048576) {
        throw const DataContractException(
            'La operación excede el límite de envío.');
      }
      await tx.insert('sync_queue', {
        'operation_uuid': id,
        'package_id': packageId,
        'detalle_id': detailId,
        'type': command.wireName,
        'operation_json': jsonEncode(operation),
        'payload_json': jsonEncode(payload),
        'expected_version_json': jsonEncode(original.version),
        'status': 'pending',
        'created_at': now
      });
      await tx.update(
          'items',
          InventoryItem.fromJson(projected)
              .toDatabaseRow(packageId, original: original),
          where: 'package_id=? AND detalle_id=?',
          whereArgs: [packageId, detailId]);
      return id;
    });
  }

  Future<String?> refreshPackage(String oldPackageId) async {
    final db = await database.database;
    final old = await _ready(db, oldPackageId);
    final manifest = PackageManifest.fromJson(
        jsonObject(jsonDecode(old['manifest_json'] as String)));
    if (manifest.locationId == null)
      throw const DataContractException(
          'Se requiere una ubicación específica.');
    return downloadLocation(
        periodId: manifest.periodId,
        departmentNumber: manifest.departmentNumber,
        locationId: manifest.locationId!,
        includeReassignmentCatalogs:
            manifest.toJson()['include_reassignment_catalogs'] == true);
  }

  /// Terminal conflicts remain in the audit trail. Resolve them explicitly,
  /// refresh the snapshot, then create a new operation with a new UUID.
  Future<void> resolveRejectedOperation(String operationId) async {
    final db = await database.database;
    await db.transaction((tx) async {
      final rows = await tx.rawQuery('''
        SELECT q.* FROM sync_queue q JOIN packages p ON p.package_id=q.package_id
        WHERE q.operation_uuid=? AND p.user_id=? AND p.device_id=?
      ''', [operationId, session.userId, session.deviceId]);
      if (rows.length != 1 ||
          !['conflict', 'error'].contains(rows.single['status']) ||
          rows.single['receipt_json'] == null) {
        throw const DataContractException(
            'Solo se puede resolver un rechazo terminal acusado por el servidor.');
      }
      await tx.update(
          'sync_queue', {'resolved_at': clock().toUtc().toIso8601String()},
          where: 'operation_uuid=?', whereArgs: [operationId]);
    });
  }

  static void _validateDate(String date) {
    if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(date)) {
      throw const DataContractException('Fecha de resguardo inválida.');
    }
    final parsed = DateTime.tryParse(date);
    if (parsed == null || parsed.toIso8601String().substring(0, 10) != date) {
      throw const DataContractException('Fecha de resguardo inválida.');
    }
  }
}
