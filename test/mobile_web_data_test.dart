import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/inventory_data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/inventory_fixture.dart';

FixturePackage legacyDownload({int itemCount = 1, bool unaffiliated = false}) {
  final source = fixturePackage(items: [
    for (var id = 1; id <= itemCount; id++)
      fixtureItem(id: id)..['snapshot_id'] = null
  ]);
  final manifest = source.manifest.toJson()
    ..['snapshot_completado_at'] = null
    ..['heredado'] = true
    ..['membership_sha256'] = List.filled(64, 'a').join();
  final pages = <int, List<int>>{};
  for (final entry in source.pages.entries) {
    final page = jsonObject(jsonDecode(utf8.decode(entry.value)));
    if (unaffiliated) {
      for (final employee in page['empleados'] as List) {
        employee['numero_departamento'] = null;
      }
    }
    final bytes = utf8.encode(jsonEncode(page));
    pages[entry.key] = bytes;
    final descriptor = manifest['pages'][entry.key - 1];
    descriptor['bytes'] = bytes.length;
    descriptor['sha256'] = sha256.convert(bytes).toString();
  }
  manifest['total_bytes'] =
      pages.values.fold<int>(0, (sum, page) => sum + page.length);
  return FixturePackage(PackageManifest.fromJson(manifest), pages);
}

void main() {
  sqfliteFfiInit();
  late InventoryDatabase database;
  late InventoryRepository repository;
  late MobileApiClient api;
  late MockClient client;
  late FixturePackage package;

  setUp(() {
    package = fixturePackage();
    database = InventoryDatabase(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    client = MockClient((request) async => http.Response.bytes(
        package.pages[int.parse(request.url.pathSegments.last)]!, 200));
    api = MobileApiClient(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        tokenProvider: () async => 'test-token',
        client: client);
    repository = InventoryRepository(
        database: database,
        api: api,
        session: fixtureSession(),
        clock: () => fixtureNow);
  });
  tearDown(() async {
    client.close();
    await database.close();
  });
  Future<void> install() async {
    await repository.installPackage(package.manifest, period: fixturePeriod());
  }

  test('period lookup, creation and close use the authenticated API contract',
      () async {
    final requests = <http.Request>[];
    final period = fixturePeriod()..['snapshot_completado_at'] = null;
    final httpClient = MockClient((request) async {
      requests.add(request);
      expect(request.headers['Authorization'], 'Bearer token');
      final body = request.method == 'GET'
          ? {
              'exists': false,
              'period': null,
              'can_create': true,
              'can_close': false
            }
          : {
              'period': {
                ...period,
                if (request.url.path.endsWith('/close')) 'estado': 'cerrado'
              }
            };
      return http.Response(
          jsonEncode(body), request.method == 'GET' ? 200 : 201);
    });
    addTearDown(httpClient.close);
    final periodApi = MobileApiClient(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        tokenProvider: () async => 'token',
        client: httpClient);
    final lookup = await periodApi.lookupPeriod(year: 2026, month: 11);
    expect([lookup.exists, lookup.canCreate, lookup.canClose],
        [false, true, false]);
    expect(requests.first.url.queryParameters, {'anio': '2026', 'mes': '11'});
    final created = await periodApi.createPeriod(
        year: 2026, month: 11, name: 'Periodo prueba');
    expect(created.toJson()['snapshot_completado_at'], null);
    expect(jsonDecode(requests[1].body),
        {'anio': 2026, 'mes': 11, 'nombre': 'Periodo prueba'});
    expect((await periodApi.closePeriod(created.id)).state, 'cerrado');
    expect(requests.last.url.path, '/api/v1/mobile/periods/12/close');
  });

  test(
      'legacy items with null snapshots preserve literal identities and queue operations',
      () async {
    package = legacyDownload(itemCount: 2);
    await install();
    final db = await database.database;
    final rows = await db.query('items');
    expect(rows.map((row) => row['snapshot_id']), everyElement(isNull));
    expect(rows.map((row) => row['numero_inventario_consecutivo']),
        ['00001', '00002']);
    expect(
        (await db.rawQuery(
                'SELECT typeof(clave_activo_fijo) k, typeof(numero_inventario_consecutivo) n FROM items'))
            .first,
        {'k': 'text', 'n': 'text'});
    final id = await repository.confirmReview(fixturePackageId, '1',
        observations: 'Legado');
    expect((await repository.operations()).single.uuid, id);
    expect((await repository.item(fixturePackageId, '1'))!.snapshotId, null);
    expect((await repository.downloadedPackages()).single['membership_sha256'],
        List.filled(64, 'a').join());
  });

  test(
      'legacy reassignment accepts an unaffiliated employee and adjusts the current-scope progress',
      () async {
    package = legacyDownload(unaffiliated: true);
    await install();
    expect(
        (await repository.localEmployees(fixturePackageId))
            .single['numero_departamento'],
        null);
    await repository.proposeReassignment(fixturePackageId, '1',
        employeeId: '151',
        date: '2026-11-12',
        departmentNumber: '20',
        locationId: '31');
    final progress = await repository.progress(fixturePackageId);
    expect([progress.total, progress.reviewed, progress.pending], [0, 0, 0]);
    expect(await repository.operations(), hasLength(1));
  });

  test(
      'known closed period blocks new offline captures without deleting the package',
      () async {
    await install();
    await repository.updatePeriodState(
        InventoryPeriod.fromJson({...fixturePeriod(), 'estado': 'cerrado'}));
    expect((await repository.periodForPackage(fixturePackageId))!.state,
        'cerrado');
    await expectLater(repository.confirmReview(fixturePackageId, '1'),
        throwsA(isA<DataContractException>()));
    expect(await repository.operations(), isEmpty);
    expect(await repository.downloadedPackages(), hasLength(1));
  });

  test(
      'v2 upgrade preserves pending UUID, payload, foreign keys, indexes and immutable queue trigger',
      () async {
    await install();
    final id = await repository.confirmReview(fixturePackageId, '1',
        observations: 'No perder');
    final originalDb = await database.database;
    final schema = await originalDb.query('sqlite_master',
        columns: ['type', 'name', 'sql'],
        where: "sql IS NOT NULL AND name NOT LIKE 'sqlite_%'");
    const tables = [
      'bienes',
      'packages',
      'items',
      'departments',
      'locations',
      'employees',
      'sync_queue'
    ];
    final data = <String, List<Map<String, Object?>>>{};
    for (final table in tables) {
      data[table] = await originalDb.query(table);
    }
    final originalOperation = data['sync_queue']!.single;
    await database.close();
    final directory =
        await Directory.systemTemp.createTemp('inventory-v2-migration-');
    final path = '${directory.path}/inventory.db';
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 2,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, version) async {
              for (final row in schema.where((row) => row['type'] == 'table')) {
                var sql = row['sql'] as String;
                if (row['name'] == 'items') {
                  sql = sql.replaceFirst(
                      'snapshot_id TEXT,', 'snapshot_id TEXT NOT NULL,');
                }
                if (row['name'] == 'employees') {
                  sql = sql.replaceFirst('numero_departamento TEXT,',
                      'numero_departamento TEXT NOT NULL,');
                }
                await db.execute(sql);
              }
              for (final row in schema.where((row) => row['type'] != 'table')) {
                await db.execute(row['sql'] as String);
              }
              for (final table in tables) {
                for (final row in data[table]!) {
                  await db.insert(table, row);
                }
              }
            }));
    expect(
        (await old.rawQuery('PRAGMA table_info(items)'))
            .singleWhere((row) => row['name'] == 'snapshot_id')['notnull'],
        1);
    await old.close();
    database = InventoryDatabase(factory: databaseFactoryFfi, path: path);
    final upgraded = await database.database;
    expect(await upgraded.getVersion(), 3);
    expect(await upgraded.query('sync_queue'), [originalOperation]);
    expect((await upgraded.query('sync_queue')).single['operation_uuid'], id);
    expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(
        ((await upgraded.rawQuery('PRAGMA foreign_keys')).first.values.first as int?),
        1);
    expect(
        (await upgraded.rawQuery('PRAGMA table_info(items)'))
            .singleWhere((row) => row['name'] == 'snapshot_id')['notnull'],
        0);
    expect(
        (await upgraded.rawQuery('PRAGMA table_info(employees)')).singleWhere(
            (row) => row['name'] == 'numero_departamento')['notnull'],
        0);
    expect(
        await upgraded.query('sqlite_master',
            where: 'name=?', whereArgs: ['items_inventory_literal']),
        hasLength(1));
    await expectLater(
        upgraded.update('sync_queue', {'operation_json': '{}'},
            where: 'operation_uuid=?', whereArgs: [id]),
        throwsA(isA<DatabaseException>()));
    await database.close();
    await directory.delete(recursive: true);
  });
}
