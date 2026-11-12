import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/api_client.dart';
import 'package:inventario_app/data/database.dart';
import 'package:inventario_app/data/inventory_repository.dart';
import 'package:inventario_app/data/models.dart';
import 'package:inventario_app/data/qr.dart';
import 'package:inventario_app/data/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/inventory_fixture.dart';

const _officialObservations = 'Comprobado en campo\n'
    '[12/11/2026] Este bien estaba en resguardo de Anterior y se reasignó a Nuevo';

void main() {
  sqfliteFfiInit();

  for (final captureDuringRefresh in [false, true]) {
    test(
      captureDuringRefresh
          ? 'un refresco concurrente conserva la captura nueva y la cola histórica'
          : 'descarga, QR offline, reasignación y acuse culminan en snapshot oficial',
      () async {
        final database = InventoryDatabase(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        final session = fixtureSession();
        late InventoryRepository repository;
        final packages = <String, FixturePackage>{};
        final requests = <String>[];
        var offline = false;
        var serverApplied = false;
        var packageCreates = 0;
        var syncCalls = 0;
        String? operationId;
        String? concurrentOperationId;
        String? replacementId;
        String? originalOperationBytes;

        JsonMap officialItem() => fixtureItem(reviewed: true)
          ..['revisado_por_nombre'] = 'Revisor oficial del servidor'
          ..['fecha_revisado'] = '2026-11-12'
          ..['observaciones'] = _officialObservations
          ..['version'] = {
            'detalle': '5',
            'inventario': '10',
            'resguardo_id': '821',
            'resguardo': '4',
          }
          ..['actual'] = {
            'descripcion': 'Activo de prueba',
            'numero_departamento': '20',
            'ubicacion_id': '31',
            'resguardante': {
              'clave_empleado': '151',
              'nombre_completo': 'Nuevo',
            },
          };

        FixturePackage serverPackage(String id) {
          final fixture = fixturePackage(
            packageId: id,
            items: [
              serverApplied ? officialItem() : fixtureItem(),
              fixtureItem(id: 2),
            ],
          );
          final manifest = fixture.manifest.toJson();
          manifest['avance'] = {
            'total': 2,
            'revisados': serverApplied ? 1 : 0,
            'pendientes': serverApplied ? 1 : 2,
            'porcentaje': serverApplied ? 50 : 0,
            'etiqueta': 'Avance',
            'heredado': false,
          };
          return FixturePackage(
            PackageManifest.fromJson(manifest),
            fixture.pages,
          );
        }

        http.Response jsonResponse(JsonMap value) => http.Response(
              jsonEncode(value),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );

        final client = MockClient((request) async {
          if (offline) {
            fail('El trabajo de campo intentó consultar HTTP.');
          }
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path.endsWith('/session')) {
            return jsonResponse({
              'user': {'id': session.userId, 'name': session.userName},
              'device': {'id': session.deviceId},
              'permissions': session.permissions.toList(),
              'supported_commands': session.commands.toList(),
              'offline_authorized_until': session.offlineUntil!.toIso8601String(),
            });
          }
          if (path.endsWith('/periods')) {
            expect(request.url.queryParameters, {'estado': 'abierto'});
            return jsonResponse({'data': [fixturePeriod()], 'next_cursor': null});
          }
          if (path.endsWith('/packages') && request.method == 'POST') {
            packageCreates++;
            final body = jsonObject(jsonDecode(request.body));
            expect(body['periodo_id'], '12');
            expect(body['numero_departamento'], '20');
            expect(body['ubicacion_id'], '30');
            expect(body['include_reassignment_catalogs'], true);
            final id = uuidText(body['package_id']);
            if (packageCreates == 1) {
              expect(id, fixturePackageId);
            } else {
              replacementId = id;
              expect(id, isNot(fixturePackageId));
            }
            final package = serverPackage(id);
            packages[id] = package;
            return jsonResponse(package.manifest.toJson());
          }
          if (path.contains('/pages/')) {
            final segments = request.url.pathSegments;
            final id = segments[segments.indexOf('packages') + 1];
            final page = int.parse(segments.last);
            if (id != fixturePackageId && captureDuringRefresh &&
                concurrentOperationId == null) {
              // The replacement snapshot has already been materialized online.
              // Another field capture commits while its page is in flight.
              final before = requests.length;
              offline = true;
              concurrentOperationId = await repository.confirmReview(
                fixturePackageId,
                '2',
                observations: 'Captura nueva durante el refresco',
              );
              offline = false;
              expect(requests.length, before);
            }
            return http.Response.bytes(packages[id]!.pages[page]!, 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
          }
          if (path.endsWith('/sync')) {
            syncCalls++;
            final body = jsonObject(jsonDecode(request.body));
            uuidText(body['batch_id']);
            final operations = (body['operations'] as List).map(jsonObject).toList();
            expect(operations, hasLength(1));
            final operation = operations.single;
            expect(operation['operation_id'], operationId);
            expect(operation['type'], 'proponer_reasignacion');
            expect(operation['original']['revisado'], false);
            expect(operation['original']['ubicacion_id'], '30');
            expect(operation['expected_version']['detalle'], '4');
            expect(operation['payload'], {
              'empleado_id': '151',
              'fecha_resguardo': '2026-11-12',
              'numero_departamento': '20',
              'ubicacion_id': '31',
              'observaciones': 'Comprobado en campo',
            });
            final row = (await (await database.database).query('sync_queue',
              where: 'operation_uuid=?', whereArgs: [operationId])).single;
            expect(row['submitted_at'], isNotNull);
            expect(row['attempts'], 1);
            expect(row['operation_json'], originalOperationBytes);
            serverApplied = true;
            return jsonResponse({
              'batch_id': body['batch_id'],
              'results': [{
                'operation_id': operationId,
                'estado': 'aplicada',
                'code': 'APPLIED',
                'received_at': fixtureNow.toIso8601String(),
                'committed_at': fixtureNow.add(const Duration(seconds: 1)).toIso8601String(),
                'resulting_version': officialItem()['version'],
                'replayed': false,
                'incidencia_id': null,
              }],
            });
          }
          fail('Solicitud inesperada: ${request.method} $path');
        });
        final api = MobileApiClient(
          baseUri: Uri.parse('https://inventory.test/api/v1/mobile/'),
          tokenProvider: () async => 'synthetic-token',
          client: client,
        );
        addTearDown(() async {
          client.close();
          api.close();
          await database.close();
        });
        repository = InventoryRepository(
          database: database,
          api: api,
          session: session,
          clock: () => fixtureNow,
        );

        final downloaded = await repository.downloadLocation(
          periodId: '12',
          departmentNumber: '20',
          locationId: '30',
          packageId: fixturePackageId,
        );
        expect(downloaded, fixturePackageId);
        expect(packageCreates, 1);
        expect((await repository.progress(downloaded)).reviewed, 0);

        final beforeOffline = requests.length;
        offline = true;
        final qr = jsonEncode(fixtureItem()['bien']);
        final found = await repository.findByQr(downloaded, qr);
        expect(found.status, QrLookupStatus.found);
        expect(found.item!.identity.number, '00001');
        operationId = await repository.proposeReassignment(
          downloaded,
          found.item!.detailId,
          employeeId: '151',
          date: '2026-11-12',
          departmentNumber: '20',
          locationId: '31',
          observations: 'Comprobado en campo',
        );
        expect(requests.length, beforeOffline);
        final projected = (await repository.item(downloaded, '1'))!;
        expect(projected.current!['ubicacion_id'], '31');
        expect(projected.observations, 'Comprobado en campo');
        expect(projected.toJson()['fecha_revisado'], null);
        final localProgress = await repository.progress(downloaded);
        expect([localProgress.total, localProgress.reviewed], [2, 1]);
        offline = false;

        final db = await database.database;
        final captured = (await db.query('sync_queue')).single;
        originalOperationBytes = captured['operation_json'] as String;
        final originalItemBytes = (await db.query('items',
          where: 'package_id=? AND detalle_id=?',
          whereArgs: [fixturePackageId, '1'])).single['original_json'];
        final report = await InventorySyncService(
          database: database,
          api: api,
          session: session,
          clock: () => fixtureNow,
        ).synchronize(refreshPackage: repository.refreshPackage);

        expect(report.applied, 1);
        expect(syncCalls, 1);
        expect(packageCreates, 2);
        final historicQueue = (await db.query('sync_queue',
          where: 'operation_uuid=?', whereArgs: [operationId])).single;
        expect(historicQueue['status'], 'synced');
        expect(historicQueue['operation_json'], originalOperationBytes);
        expect(historicQueue['receipt_json'], isNotNull);
        final oldItem = (await db.query('items',
          where: 'package_id=? AND detalle_id=?',
          whereArgs: [fixturePackageId, '1'])).single;
        expect(oldItem['original_json'], originalItemBytes);
        expect(oldItem['needs_refresh'], 1);

        final active = await repository.downloadedPackages();
        expect(active, hasLength(1));
        if (captureDuringRefresh) {
          expect(report.pending, 1);
          expect(report.errors, isNotEmpty);
          expect(report.refreshedPackages, isEmpty);
          expect(active.single['package_id'], fixturePackageId);
          final queued = (await db.query('sync_queue',
            where: 'operation_uuid=?', whereArgs: [concurrentOperationId])).single;
          expect(queued['status'], 'pending');
          expect(queued['submitted_at'], null);
          expect(queued['attempts'], 0);
          expect(jsonObject(jsonDecode(queued['operation_json'] as String))['payload']['observaciones'],
            'Captura nueva durante el refresco');
          final second = (await repository.item(fixturePackageId, '2'))!;
          expect(second.reviewed, true);
          expect(second.observations, 'Captura nueva durante el refresco');
          final replacement = (await db.query('packages',
            where: 'package_id=?', whereArgs: [replacementId])).single;
          expect(replacement['active'], 0);
          expect(replacement['status'], 'failed');
        } else {
          expect(report.pending, 0);
          expect(report.errors, isEmpty);
          expect(report.refreshedPackages, {fixturePackageId: replacementId});
          expect(active.single['package_id'], replacementId);
          final replacement = (await repository.item(replacementId!, '1'))!;
          expect(replacement.reviewed, true);
          expect(replacement.reviewedById, '7');
          expect(replacement.reviewerName, 'Revisor oficial del servidor');
          expect(replacement.toJson()['fecha_revisado'], '2026-11-12');
          expect(replacement.observations, _officialObservations);
          expect(replacement.version, officialItem()['version']);
          expect(replacement.current!['resguardante']['clave_empleado'], '151');
          expect(replacement.current!['ubicacion_id'], '31');
          final newItem = (await db.query('items',
            where: 'package_id=? AND detalle_id=?',
            whereArgs: [replacementId, '1'])).single;
          expect(newItem['needs_refresh'], 0);
          final officialOriginal = jsonObject(jsonDecode(newItem['original_json'] as String));
          expect(officialOriginal['revisado'], true);
          expect(officialOriginal['observaciones'], _officialObservations);
          expect(officialOriginal['version'], officialItem()['version']);
          expect((await db.query('packages', where: 'package_id=?',
            whereArgs: [fixturePackageId])).single['active'], 0);
          final progress = await repository.progress(replacementId!);
          expect([progress.total, progress.reviewed], [2, 1]);
          expect(await db.query('sync_queue'), hasLength(1));
        }
      },
    );
  }
}
