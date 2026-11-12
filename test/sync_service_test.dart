import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/api_client.dart';
import 'package:inventario_app/data/database.dart';
import 'package:inventario_app/data/models.dart';
import 'package:inventario_app/data/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String testUuid(int number) =>
    '550e8400-e29b-41d4-a716-${number.toString().padLeft(12, '0')}';

final testDevice = testUuid(1);
final testPackage = testUuid(2);
final testNow = DateTime.utc(2026, 11, 12, 12);

JsonMap sessionJson({String user = '7', String? device}) => {
  'user': {'id': user, 'name': 'Revisor'},
  'device': {'id': device ?? testDevice},
  'permissions': ['hacer_levantamiento', 'asignar'],
  'supported_commands': ['confirmar_revision', 'actualizar_observaciones',
    'proponer_reasignacion'],
  'offline_authorized_until': '2026-11-13T12:00:00Z',
};

JsonMap version({String detail = '2'}) => {
  'detalle': detail, 'inventario': '9007199254740993',
  'resguardo_id': '-101', 'resguardo': '1',
};

JsonMap receipt(String id, {String state = 'aplicada', String? code}) => {
  'operation_id': id,
  'estado': state,
  'code': code ?? (state == 'aplicada' ? 'APPLIED' :
    state == 'conflicto' ? 'VERSION_CONFLICT' : 'PERMISSION_DENIED'),
  'received_at': '2026-11-12T12:00:00Z',
  'committed_at': '2026-11-12T12:00:01Z',
  'resulting_version': state == 'aplicada' ? version() : null,
  'replayed': false,
  'incidencia_id': null,
};

http.Response jsonResponse(JsonMap json, {int status = 200}) =>
    http.Response(jsonEncode(json), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late InventoryDatabase database;
  late DateTime now;
  late MobileSession session;

  setUpAll(sqfliteFfiInit);
  setUp(() {
    database = InventoryDatabase(factory: databaseFactoryFfi,
      path: inMemoryDatabasePath);
    now = testNow;
    session = MobileSession.fromJson(sessionJson());
  });
  tearDown(() => database.close());

  Future<JsonMap> enqueue(int number, {
    String user = '7', String? device, String? package,
    bool submitted = false, String observations = 'Captura local',
  }) async {
    final db = await database.database;
    final packageId = package ?? testPackage;
    final deviceId = device ?? testDevice;
    if ((await db.query('packages', where: 'package_id = ?',
        whereArgs: [packageId])).isEmpty) {
      await db.insert('packages', {
        'package_id': packageId, 'user_id': user, 'device_id': deviceId,
        'periodo_id': '12', 'numero_departamento': '-20', 'ubicacion_id': '30',
        'manifest_json': '{}', 'status': 'ready', 'active': 1,
        'created_at': testNow.toIso8601String(),
      });
    }
    final original = InventoryItem.fromJson({
      'snapshot_id': '$number', 'detalle_id': '$number',
      'bien': {'clave_activo_fijo': '5150-${number.toString().padLeft(6, '0')}',
        'numero_inventario_consecutivo': number.toString().padLeft(5, '0')},
      'numero_departamento_inicial': '-20', 'ubicacion_id_inicial': '30',
      'actual': {'descripcion': 'Bien de prueba', 'numero_departamento': '-20',
        'ubicacion_id': '30', 'resguardante': {
          'clave_empleado': '-7', 'nombre_completo': 'Custodio',
        }},
      'actual_restringido': false, 'revisado': false,
      'revisado_por_id': null, 'revisado_por_nombre': null,
      'fecha_revisado': null, 'observaciones': null, 'editable': true,
      'version': version(detail: '1'),
    });
    final projected = InventoryItem.fromJson(original.toJson()
      ..['revisado'] = true
      ..['revisado_por_id'] = user
      ..['observaciones'] = observations);
    await db.insert('items', projected.toDatabaseRow(packageId, original: original));
    final operation = <String, dynamic>{
      'operation_id': testUuid(1000 + number), 'user_id': user,
      'device_id': deviceId, 'package_id': packageId,
      'periodo_id': '12', 'detalle_id': '$number', 'bien': original.identity.toJson(),
      'expected_version': original.version, 'original': original.originalValues(),
      'captured_at': testNow.toIso8601String(),
      'qr': original.identity.toJson(), 'type': 'confirmar_revision',
      'payload': {'observaciones': observations},
    };
    await db.insert('sync_queue', {
      'operation_uuid': operation['operation_id'], 'package_id': packageId,
      'detalle_id': '$number', 'type': 'confirmar_revision',
      // Unusual whitespace checks that the persisted envelope is never replaced.
      'operation_json': const JsonEncoder.withIndent('  ').convert(operation),
      'payload_json': jsonEncode(operation['payload']),
      'expected_version_json': jsonEncode(original.version),
      'status': 'pending', 'attempts': submitted ? 1 : 0,
      'submitted_at': submitted ? testNow.toIso8601String() : null,
      'created_at': testNow.add(Duration(microseconds: number)).toIso8601String(),
    });
    return operation;
  }

  Future<JsonMap> queued(String id) async => Map<String, dynamic>.from(
    (await (await database.database).query('sync_queue',
      where: 'operation_uuid = ?', whereArgs: [id])).single);

  InventorySyncService service(Future<http.Response> Function(http.Request) handler) {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/session')) {
        return jsonResponse(sessionJson());
      }
      return handler(request);
    });
    addTearDown(client.close);
    return InventorySyncService(database: database, session: session,
      clock: () => now, api: MobileApiClient(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        tokenProvider: () async => 'synthetic-token', client: client,
      ));
  }

  test('acuse aplicado conserva sobre y original, actualiza versión y pide refresco', () async {
    final op = await enqueue(1);
    final before = await queued(op['operation_id'] as String);
    final db = await database.database;
    final original = (await db.query('items')).single['original_json'];
    final sync = service((request) async {
      expect(request.url.path.endsWith('/sync'), isTrue);
      final saved = await queued(op['operation_id'] as String);
      expect(saved['attempts'], 1);
      expect(saved['submitted_at'], isNotNull);
      final body = jsonObject(jsonDecode(request.body));
      expect(body['operations'], [op]);
      return jsonResponse({'batch_id': body['batch_id'],
        'results': [receipt(op['operation_id'] as String)]});
    });
    final report = await sync.synchronize();
    expect(report.applied, 1);
    expect(report.pending, 0);
    expect(report.errors, isEmpty);
    final after = await queued(op['operation_id'] as String);
    expect(after['status'], 'synced');
    expect(after['operation_json'], before['operation_json']);
    expect(after['receipt_json'], isNotNull);
    final item = (await db.query('items')).single;
    expect(item['needs_refresh'], 1);
    expect(item['original_json'], original);
    final current = jsonObject(jsonDecode(item['current_json'] as String));
    expect(current['version'], version());
    expect(current['fecha_revisado'], isNull);
    expect(current['observaciones'], 'Captura local');
  });

  test('respuesta perdida se recupera por UUID sin volver a ejecutar el envío', () async {
    final op = await enqueue(1);
    var syncCalls = 0;
    var recoveryCalls = 0;
    final sync = service((request) async {
      if (request.url.path.endsWith('/sync/results')) {
        recoveryCalls++;
        return jsonResponse({'receipts': [receipt(op['operation_id'] as String)],
          'unknown_operation_ids': []});
      }
      syncCalls++;
      throw http.ClientException('Respuesta perdida después del commit');
    });
    final lost = await sync.synchronize();
    expect(lost.pending, 1);
    expect(lost.errors, isNotEmpty);
    expect((await queued(op['operation_id'] as String))['status'], 'pending');
    final recovered = await sync.synchronize();
    expect(recovered.applied, 1);
    expect(recovered.pending, 0);
    expect(syncCalls, 1);
    expect(recoveryCalls, 1);
    expect((await queued(op['operation_id'] as String))['attempts'], 1);
  });

  test('solo UUID desconocidos explícitos se reenvían y conservan el mismo sobre', () async {
    final op = await enqueue(1, submitted: true);
    final before = await queued(op['operation_id'] as String);
    final calls = <String>[];
    final sync = service((request) async {
      calls.add(request.url.path);
      if (request.url.path.endsWith('/sync/results')) {
        return jsonResponse({'receipts': [],
          'unknown_operation_ids': [op['operation_id']]});
      }
      final body = jsonObject(jsonDecode(request.body));
      expect(body['operations'], [op]);
      return jsonResponse({'batch_id': body['batch_id'],
        'results': [receipt(op['operation_id'] as String)]});
    });
    final report = await sync.synchronize();
    expect(report.applied, 1);
    expect(calls, ['/api/v1/mobile/sync/results', '/api/v1/mobile/sync']);
    final after = await queued(op['operation_id'] as String);
    expect(after['operation_json'], before['operation_json']);
    expect(after['attempts'], 2);
  });

  test('lote parcial guarda cada terminal y conserva reintento y acuse faltante', () async {
    final operations = <JsonMap>[];
    for (var number = 1; number <= 5; number++) {
      operations.add(await enqueue(number));
    }
    var refreshCalls = 0;
    final sync = service((request) async {
      final body = jsonObject(jsonDecode(request.body));
      return jsonResponse({'batch_id': body['batch_id'], 'results': [
        receipt(operations[0]['operation_id'] as String),
        receipt(operations[1]['operation_id'] as String, state: 'conflicto'),
        receipt(operations[2]['operation_id'] as String, state: 'rechazada'),
        {'operation_id': operations[3]['operation_id'], 'estado': 'reintentar',
          'code': 'SERVER_BUSY', 'retryable': true, 'retry_after_seconds': 5},
      ]});
    });
    final report = await sync.synchronize(refreshPackage: (id) async {
      refreshCalls++;
      return testUuid(3);
    });
    expect([report.applied, report.conflicts, report.rejected, report.pending], [1, 1, 1, 2]);
    expect(report.errors, isNotEmpty);
    expect(refreshCalls, 0);
    final rows = await (await database.database).query('sync_queue', orderBy: 'detalle_id');
    expect(rows.map((row) => row['status']), ['synced', 'conflict', 'error', 'pending', 'pending']);
    expect(rows[3]['next_attempt_at'], now.add(const Duration(seconds: 5)).toIso8601String());
    final items = await (await database.database).query('items', orderBy: 'detalle_id');
    expect(items.map((item) => item['needs_refresh']), [1, 1, 1, 0, 0]);
  });

  for (final invalid in ['duplicate', 'foreign', 'wrong-batch', 'bad-version',
    'bad-state', 'retry-applied', 'bad-date', 'bad-time', 'bad-offset',
    'out-of-range', 'upper-range', 'bad-second', 'reversed-dates']) {
    test('respuesta $invalid conserva todas las operaciones pendientes', () async {
      final op = await enqueue(1);
      final sync = service((request) async {
        final body = jsonObject(jsonDecode(request.body));
        final outcome = receipt(op['operation_id'] as String);
        final response = <String, dynamic>{'batch_id': body['batch_id'], 'results': [outcome]};
        if (invalid == 'duplicate') response['results'] = [outcome, outcome];
        if (invalid == 'foreign') outcome['operation_id'] = testUuid(999);
        if (invalid == 'wrong-batch') response['batch_id'] = testUuid(999);
        if (invalid == 'bad-version') outcome['resulting_version'] = {'detalle': 2};
        if (invalid == 'bad-state') outcome['estado'] = 'desconocido';
        if (invalid == 'bad-date') outcome['received_at'] = '2026-02-31T12:00:00Z';
        if (invalid == 'bad-time') outcome['received_at'] = '2026-11-12T24:00:00Z';
        if (invalid == 'bad-offset') outcome['received_at'] = '2026-11-12T12:00:00+24:00';
        if (invalid == 'out-of-range') outcome['received_at'] = '1000-01-01T00:00:00+01:00';
        if (invalid == 'upper-range') outcome['committed_at'] = '9999-12-31T23:59:59-01:00';
        if (invalid == 'bad-second') outcome['received_at'] = '2026-11-12T12:00:60Z';
        if (invalid == 'reversed-dates') outcome['received_at'] = '2026-11-12T12:00:02Z';
        if (invalid == 'retry-applied') {
          response['results'] = [{'operation_id': op['operation_id'],
            'estado': 'reintentar', 'code': 'APPLIED', 'retryable': true,
            'retry_after_seconds': 3}];
        }
        return jsonResponse(response);
      });
      final report = await sync.synchronize();
      expect(report.applied, 0);
      expect(report.pending, 1);
      expect(report.errors, isNotEmpty);
      expect((await queued(op['operation_id'] as String))['receipt_json'], isNull);
    });
  }

  test('recuperación incompleta no reenvía un UUID cuyo estado sigue incierto', () async {
    final op = await enqueue(1, submitted: true);
    var uploads = 0;
    final sync = service((request) async {
      if (request.url.path.endsWith('/sync/results')) {
        return jsonResponse({'receipts': [], 'unknown_operation_ids': []});
      }
      uploads++;
      throw StateError('No debe enviar');
    });
    final report = await sync.synchronize();
    expect(report.pending, 1);
    expect(report.errors, isNotEmpty);
    expect(uploads, 0);
    expect((await queued(op['operation_id'] as String))['attempts'], 1);
  });

  test('acuse acepta calendario bisiesto válido, fracciones y offset explícito', () async {
    final op = await enqueue(1);
    final sync = service((request) async {
      final body = jsonObject(jsonDecode(request.body));
      final outcome = receipt(op['operation_id'] as String)
        ..['received_at'] = '2024-02-29T23:59:59.123456+01:00'
        ..['committed_at'] = '2024-02-29T23:59:59.123457+01:00';
      return jsonResponse({'batch_id': body['batch_id'], 'results': [outcome]});
    });
    final report = await sync.synchronize();
    expect(report.applied, 1);
    expect(report.pending, 0);
    expect(report.errors, isEmpty);
  });

  test('cambiar credencial tras sesión no cambia propietario de UUID en vuelo', () async {
    final op = await enqueue(1, submitted: true);
    var currentToken = 'credential-A';
    var credentialReads = 0;
    final headers = <String?>[];
    final client = MockClient((request) async {
      headers.add(request.headers['authorization']);
      if (request.url.path.endsWith('/session')) {
        currentToken = 'credential-B';
        return jsonResponse(sessionJson());
      }
      if (request.url.path.endsWith('/sync/results')) {
        return jsonResponse({'receipts': [], 'unknown_operation_ids': [op['operation_id']]});
      }
      final body = jsonObject(jsonDecode(request.body));
      expect(body['operations'], [op]);
      return jsonResponse({'batch_id': body['batch_id'],
        'results': [receipt(op['operation_id'] as String)]});
    });
    addTearDown(client.close);
    final sync = InventorySyncService(database: database, session: session,
      api: MobileApiClient(baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        client: client, tokenProvider: () async {
          credentialReads++;
          return currentToken;
        }));
    final report = await sync.synchronize();
    expect(report.applied, 1);
    expect(report.errors, isEmpty);
    expect(currentToken, 'credential-B');
    expect(credentialReads, 1);
    expect(headers, ['Bearer credential-A', 'Bearer credential-A', 'Bearer credential-A']);
  });

  for (final status in [401, 503]) {
    test('HTTP $status no borra ni consume una operación', () async {
      final op = await enqueue(1);
      final sync = service((request) async => jsonResponse({
        'error': {'code': status == 401 ? 'TOKEN_EXPIRED_OR_REVOKED' : 'SERVER_NOT_READY'},
      }, status: status));
      final report = await sync.synchronize();
      expect(report.pending, 1);
      expect(report.errors, isNotEmpty);
      final row = await queued(op['operation_id'] as String);
      expect(row['status'], 'pending');
      expect(row['attempts'], 1);
      expect(row['receipt_json'], isNull);
    });
  }

  test('sesión remota de otro dispositivo impide todo envío', () async {
    await enqueue(1);
    var uploads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/session')) {
        return jsonResponse(sessionJson(device: testUuid(99)));
      }
      uploads++;
      throw StateError('No debe enviar');
    });
    addTearDown(client.close);
    final sync = InventorySyncService(database: database,
      session: session, api: MobileApiClient(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        tokenProvider: () async => 'synthetic-token', client: client,
      ));
    final report = await sync.synchronize();
    expect(report.pending, 1);
    expect(report.errors, isNotEmpty);
    expect(uploads, 0);
  });

  test('cola ajena no se envía ni se cuenta como pendiente del actor actual', () async {
    final own = await enqueue(1);
    final other = await enqueue(2, user: '8', package: testUuid(8), device: testUuid(9));
    final sync = service((request) async {
      final body = jsonObject(jsonDecode(request.body));
      expect(body['operations'], [own]);
      return jsonResponse({'batch_id': body['batch_id'],
        'results': [receipt(own['operation_id'] as String)]});
    });
    final report = await sync.synchronize();
    expect(report.applied, 1);
    expect(report.pending, 0);
    expect((await queued(other['operation_id'] as String))['status'], 'pending');
  });

  for (final unicode in [false, true]) {
    test('divide lotes por ${unicode ? 'bytes UTF-8' : '100 operaciones'}', () async {
      final count = unicode ? 70 : 150;
      final observations = unicode ? List.filled(5000, '🚀').join() : 'Captura';
      for (var index = 1; index <= count; index++) {
        await enqueue(index, observations: observations);
      }
      final sizes = <int>[];
      final sync = service((request) async {
        expect(request.bodyBytes.length, lessThanOrEqualTo(1048576));
        final body = jsonObject(jsonDecode(request.body));
        final operations = (body['operations'] as List).map(jsonObject).toList();
        sizes.add(operations.length);
        expect(operations.length, lessThanOrEqualTo(100));
        expect(operations.map((op) => op['detalle_id']).toSet(), hasLength(operations.length));
        return jsonResponse({'batch_id': body['batch_id'], 'results': operations
          .map((op) => receipt(op['operation_id'] as String)).toList()});
      });
      final report = await sync.synchronize();
      expect(report.applied, count);
      expect(report.pending, 0);
      expect(sizes.length, greaterThanOrEqualTo(2));
      if (!unicode) expect(sizes, [100, 50]);
    });
  }

  test('reintentar respeta próximo intento y vuelve a recuperar UUID antes de enviar', () async {
    final op = await enqueue(1);
    var uploads = 0;
    var recoveries = 0;
    final sync = service((request) async {
      if (request.url.path.endsWith('/sync/results')) {
        recoveries++;
        return jsonResponse({'receipts': [], 'unknown_operation_ids': [op['operation_id']]});
      }
      final body = jsonObject(jsonDecode(request.body));
      uploads++;
      return jsonResponse({'batch_id': body['batch_id'], 'results': uploads == 1
        ? [{'operation_id': op['operation_id'], 'estado': 'reintentar',
            'code': 'SERVER_BUSY', 'retryable': true, 'retry_after_seconds': 10}]
        : [receipt(op['operation_id'] as String)]});
    });
    expect((await sync.synchronize()).pending, 1);
    expect((await sync.synchronize()).pending, 1);
    expect(uploads, 1);
    expect(recoveries, 0);
    now = now.add(const Duration(seconds: 11));
    expect((await sync.synchronize()).applied, 1);
    expect(uploads, 2);
    expect(recoveries, 1);
  });

  test('mutex comparte ejecución y refresca únicamente después de resolver todos los pendientes', () async {
    final op = await enqueue(1);
    final gate = Completer<void>();
    var uploads = 0;
    var refreshes = 0;
    final sync = service((request) async {
      await gate.future;
      uploads++;
      final body = jsonObject(jsonDecode(request.body));
      return jsonResponse({'batch_id': body['batch_id'],
        'results': [receipt(op['operation_id'] as String)]});
    });
    final first = sync.synchronize(refreshPackage: (id) async {
      expect(id, testPackage);
      refreshes++;
      return testUuid(3);
    });
    final second = sync.synchronize();
    expect(identical(first, second), isTrue);
    gate.complete();
    final report = await first;
    expect(await second, same(report));
    expect(uploads, 1);
    expect(refreshes, 1);
    expect(report.refreshedPackages, {testPackage: testUuid(3)});
  });
}
