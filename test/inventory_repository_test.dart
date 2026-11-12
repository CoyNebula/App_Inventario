import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/api_client.dart';
import 'package:inventario_app/data/database.dart';
import 'package:inventario_app/data/inventory_repository.dart';
import 'package:inventario_app/data/models.dart';
import 'package:inventario_app/data/qr.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/inventory_fixture.dart';

void main() {
  sqfliteFfiInit();
  late InventoryDatabase database;
  late MobileApiClient api;
  late InventoryRepository repository;
  late FixturePackage package;
  late bool corruptPage;

  setUp(() {
    corruptPage = false;
    package = fixturePackage();
    database = InventoryDatabase(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    api = MobileApiClient(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile/'),
        tokenProvider: () async => 'test-token',
        client: MockClient((request) async {
          if (request.url.path.contains('/pages/')) {
            final page = int.parse(request.url.pathSegments.last);
            return http.Response.bytes(
                corruptPage ? utf8.encode('{}') : package.pages[page]!, 200);
          }
          return http.Response('{}', 404);
        }));
    repository = InventoryRepository(
        database: database,
        api: api,
        session: fixtureSession(),
        clock: () => fixtureNow);
  });

  tearDown(() async {
    api.close();
    await database.close();
  });

  Future<void> install() async {
    await repository.installPackage(package.manifest, period: fixturePeriod());
  }

  test('download publishes a complete snapshot and QR preserves leading zeros',
      () async {
    await install();
    final found = await repository.findByQr(fixturePackageId,
        '{"clave_activo_fijo":"5150-000001","numero_inventario_consecutivo":"00001"}');
    expect(found.status, QrLookupStatus.found);
    expect(found.item!.identity.number, '00001');
    expect((await repository.progress(fixturePackageId)).total, 1);
    expect(
        (await repository.localEmployees(fixturePackageId))
            .single['clave_empleado'],
        '151');
    expect(await repository.downloadedPackages(), hasLength(1));
  });

  test('unknown and contradictory QR never create an inventory record',
      () async {
    await install();
    expect((await repository.findByQr(fixturePackageId, '99999')).message,
        'No disponible en esta descarga');
    expect(
        (await repository.findByQr(fixturePackageId,
                '{"clave_activo_fijo":"5150-000001","numero_inventario_consecutivo":"00002"}'))
            .status,
        QrLookupStatus.notAvailable);
    expect((await repository.progress(fixturePackageId)).total, 1);
  });

  test(
      'duplicate consecutive is ambiguous until both literal identifiers match',
      () async {
    package = fixturePackage(items: [
      fixtureItem(id: 1, number: '00001'),
      fixtureItem(id: 2, number: '00001')
    ]);
    await install();
    expect((await repository.findByQr(fixturePackageId, '00001')).status,
        QrLookupStatus.ambiguous);
    expect(
        (await repository.findByQr(fixturePackageId,
                '{"clave_activo_fijo":"5150-000002","numero_inventario_consecutivo":"00001"}'))
            .item!
            .detailId,
        '2');
  });

  test(
      'corrupt page stays unavailable and can be resumed without partial state',
      () async {
    corruptPage = true;
    await expectLater(install(), throwsA(isA<DataContractException>()));
    expect(await repository.downloadedPackages(), isEmpty);
    await expectLater(repository.progress(fixturePackageId),
        throwsA(isA<DataContractException>()));
    corruptPage = false;
    await install();
    expect((await repository.progress(fixturePackageId)).total, 1);
  });

  test('offline capture commits projection and immutable outbox together',
      () async {
    await install();
    final id = await repository.confirmReview(fixturePackageId, '1',
        observations: '  Nota literal  ');
    final db = await database.database;
    final queue = (await db.query('sync_queue')).single;
    final operation = jsonObject(jsonDecode(queue['operation_json'] as String));
    expect(queue['operation_uuid'], id);
    expect(operation['original']['revisado'], false);
    expect(operation['expected_version']['detalle'], '4');
    expect(operation['payload']['observaciones'], '  Nota literal  ');
    expect((await repository.progress(fixturePackageId)).percentage, 100);
    expect((await repository.item(fixturePackageId, '1'))!.reviewed, true);
    await expectLater(
        db.update('sync_queue', {'operation_json': '{}'},
            where: 'operation_uuid=?', whereArgs: [id]),
        throwsA(isA<DatabaseException>()));
    await expectLater(repository.confirmReview(fixturePackageId, '1'),
        throwsA(isA<DataContractException>()));
  });

  test('SQLite failure while queueing rolls back the local review', () async {
    await install();
    final db = await database.database;
    await db.execute(
        "CREATE TRIGGER fail_outbox BEFORE INSERT ON sync_queue BEGIN SELECT RAISE(ABORT, 'fixture'); END");
    await expectLater(repository.confirmReview(fixturePackageId, '1'),
        throwsA(isA<DatabaseException>()));
    expect((await repository.item(fixturePackageId, '1'))!.reviewed, false);
    expect(await db.query('sync_queue'), isEmpty);
  });

  test('account and device isolation also applies to cached QR and captures',
      () async {
    await install();
    final other = InventoryRepository(
        database: database,
        api: api,
        session: fixtureSession(userId: '8'),
        clock: () => fixtureNow);
    expect(await other.downloadedPackages(), isEmpty);
    await expectLater(other.findByQr(fixturePackageId, '00001'),
        throwsA(isA<DataContractException>()));
    await expectLater(other.confirmReview(fixturePackageId, '1'),
        throwsA(isA<DataContractException>()));
  });

  test('expired offline grant and another reviewer prevent captures', () async {
    package =
        fixturePackage(items: [fixtureItem(reviewed: true, reviewer: '8')]);
    await install();
    await expectLater(
        repository.updateObservations(fixturePackageId, '1',
            observations: 'Cambio'),
        throwsA(isA<DataContractException>()));
    final expired = InventoryRepository(
        database: database,
        api: api,
        session: fixtureSession(),
        clock: () => fixtureNow.add(const Duration(days: 2)));
    await expectLater(expired.confirmReview(fixturePackageId, '1'),
        throwsA(isA<DataContractException>()));
  });

  test('own observations retain the server original and expected version',
      () async {
    package = fixturePackage(items: [fixtureItem(reviewed: true)]);
    await install();
    await repository.updateObservations(fixturePackageId, '1',
        observations: 'Nueva nota');
    final db = await database.database;
    final op = jsonObject(jsonDecode(
        (await db.query('sync_queue')).single['operation_json'] as String));
    expect(op['type'], 'actualizar_observaciones');
    expect(op['original']['revisado'], true);
    expect(op['original']['observaciones'], null);
    expect(op['expected_version']['detalle'], '4');
  });

  test('reassignment uses downloaded candidates and rejects the same custodian',
      () async {
    await install();
    await expectLater(
        repository.proposeReassignment(fixturePackageId, '1',
            employeeId: '150',
            date: '2026-11-12',
            departmentNumber: '20',
            locationId: '31'),
        throwsA(isA<DataContractException>()));
    await expectLater(
        repository.proposeReassignment(fixturePackageId, '1',
            employeeId: '151',
            date: '2026-02-30',
            departmentNumber: '20',
            locationId: '31'),
        throwsA(isA<DataContractException>()));
    await repository.proposeReassignment(fixturePackageId, '1',
        employeeId: '151',
        date: '2026-11-12',
        departmentNumber: '20',
        locationId: '31',
        observations: 'Cambio observado');
    final item = (await repository.item(fixturePackageId, '1'))!;
    expect(item.current!['ubicacion_id'], '31');
    expect(item.current!['resguardante']['clave_empleado'], '151');
    expect(item.reviewed, true);
  });

  test('refresh cannot hide an unresolved capture in an older active snapshot',
      () async {
    await install();
    await repository.confirmReview(fixturePackageId, '1');
    package = fixturePackage(packageId: '550e8400-e29b-41d4-a716-446655440002');
    await expectLater(install(), throwsA(isA<DataContractException>()));
    expect((await repository.downloadedPackages()).single['package_id'],
        fixturePackageId);
    expect(
        (await (await database.database).query('sync_queue')).single['status'],
        'pending');
  });

  test('v1 migration preserves legacy rows and capture survives reopen',
      () async {
    await database.close();
    final dir = await Directory.systemTemp.createTemp('inventory-data-test-');
    final path = dir.path + '/inventory.db';
    final legacy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) async {
              await db.execute(
                  'CREATE TABLE bienes (id INTEGER PRIMARY KEY, clave_activo TEXT UNIQUE, no_inventario TEXT, descripcion TEXT, resguardante TEXT, departamento TEXT)');
              await db.insert('bienes', {
                'id': 1,
                'clave_activo': 'LEGADO',
                'no_inventario': '00001'
              });
            }));
    await legacy.close();
    database = InventoryDatabase(factory: databaseFactoryFfi, path: path);
    repository = InventoryRepository(
        database: database,
        api: api,
        session: fixtureSession(),
        clock: () => fixtureNow);
    await install();
    final id = await repository.confirmReview(fixturePackageId, '1',
        observations: 'Persistente');
    await database.close();
    database = InventoryDatabase(factory: databaseFactoryFfi, path: path);
    final reopened = await database.database;
    expect((await reopened.query('bienes')).single['no_inventario'], '00001');
    expect((await reopened.query('sync_queue')).single['operation_uuid'], id);
    expect((await reopened.query('items')).single['revisado'], 1);
    await database.close();
    await dir.delete(recursive: true);
  });
}
