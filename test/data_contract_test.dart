import 'dart:convert';

import 'package:crypto/crypto.dart';
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

const packageId = '550e8400-e29b-41d4-a716-446655440001';
const deviceId = '550e8400-e29b-41d4-a716-446655440002';

JsonMap validManifest() => {
      'schema_version': '1',
      'package_id': packageId,
      'device_id': deviceId,
      'user_id': '9007199254740993',
      'periodo_id': '12',
      'numero_departamento_inicial': '-20',
      'ubicacion_id_inicial': '30',
      'offline_authorized_until': '2026-11-13T18:00:00Z',
      'download_expires_at': '2026-11-12T20:00:00Z',
      'total_bytes': 120,
      'counts': {
        'items': 1,
        'departamentos': 0,
        'ubicaciones': 0,
        'empleados': 0
      },
      'pages': [
        {
          'page': 1,
          'bytes': 120,
          'sha256': List.filled(64, 'a').join(),
          'counts': {
            'items': 1,
            'departamentos': 0,
            'ubicaciones': 0,
            'empleados': 0,
          },
        },
      ],
    };

MobileApiClient mockApi(MockClient client,
        {Future<String?> Function()? tokenProvider}) =>
    MobileApiClient(
      baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
      tokenProvider: tokenProvider ?? () async => 'test-token',
      client: client,
    );

void main() {
  group('Identificadores patrimoniales', () {
    test('preserva ceros, espacios y prefijos literalmente', () {
      final identity = AssetIdentity.fromJson({
        'clave_activo_fijo': ' E5150-000001 ',
        'numero_inventario_consecutivo': '00002',
      });
      expect(identity.key, ' E5150-000001 ');
      expect(identity.number, '00002');
      expect(identity.toJson(), {
        'clave_activo_fijo': ' E5150-000001 ',
        'numero_inventario_consecutivo': '00002',
      });
    });

    test('identidad JSON numérica se rechaza sin convertir a texto', () {
      for (final identity in [
        {'clave_activo_fijo': 123, 'numero_inventario_consecutivo': '00002'},
        {
          'clave_activo_fijo': 'E5150-000001',
          'numero_inventario_consecutivo': 2
        },
        {'clave_activo_fijo': '', 'numero_inventario_consecutivo': '00002'},
      ]) {
        expect(() => AssetIdentity.fromJson(identity),
            throwsA(isA<DataContractException>()));
      }
    });

    test('IDs y revisiones grandes no pasan por double', () {
      expect(textId('9007199254740993'), '9007199254740993');
      expect(textId('9223372036854775807'), '9223372036854775807');
      expect(textId('-2147483648', signed: true), '-2147483648');
      for (final value in [
        9007199254740993,
        '01',
        '0',
        '-1',
        '9223372036854775808'
      ]) {
        expect(() => textId(value), throwsA(isA<DataContractException>()));
      }
      for (final value in ['-0', '-2147483649', '2147483648']) {
        expect(() => textId(value, signed: true),
            throwsA(isA<DataContractException>()));
      }
    });
  });

  group('Contrato QR', () {
    test('JSON con ambos identificadores conserva sus valores', () {
      expect(
        parseInventoryQr('  {"clave_activo_fijo":" E5150-000001 ",'
            '"numero_inventario_consecutivo":"00002"}  '),
        {
          'clave_activo_fijo': ' E5150-000001 ',
          'numero_inventario_consecutivo': '00002',
        },
      );
    });

    test('acepta JSON heredado con entidades HTML', () {
      expect(
        parseInventoryQr(
            '{&quot;clave_activo_fijo&quot;:&quot;E5150-000001&quot;,'
            '&#34;numero_inventario_consecutivo&#34;:&#x22;00002&#x22;}'),
        {
          'clave_activo_fijo': 'E5150-000001',
          'numero_inventario_consecutivo': '00002',
        },
      );
    });

    test('JSON válido no decodifica entidades dentro de la identidad', () {
      expect(
        parseInventoryQr('{"clave_activo_fijo":"E&amp;5150-01",'
            '"numero_inventario_consecutivo":"00002"}')['clave_activo_fijo'],
        'E&amp;5150-01',
      );
    });

    test('acepta etiquetas legacy de clave y consecutivo con y sin ceros', () {
      expect(parseInventoryQr(' E5150-000001 '),
          {'clave_activo_fijo': 'E5150-000001'});
      expect(parseInventoryQr('00002'),
          {'numero_inventario_consecutivo': '00002'});
      expect(parseInventoryQr('123'), {'numero_inventario_consecutivo': '123'});
      expect(parseInventoryQr('0'), {'numero_inventario_consecutivo': '0'});
    });

    test('rechaza campos numéricos, arreglos y QR sin identificadores', () {
      for (final raw in [
        '{"clave_activo_fijo":123,"numero_inventario_consecutivo":"00002"}',
        '{"clave_activo_fijo":"E5150-1","numero_inventario_consecutivo":2}',
        '{"numero_inventario_consecutivo":null}',
        '{"numero_inventario_consecutivo":""}',
        '{"otro":"E5150-1"}',
        '["E5150-1"]',
        'https://untrusted.test/asset/1',
        '',
      ]) {
        expect(
            () => parseInventoryQr(raw), throwsA(isA<DataContractException>()),
            reason: raw);
      }
    });
  });

  group('Manifiestos', () {
    test('conserva IDs literales y una copia del documento recibido', () {
      final source = validManifest();
      final manifest = PackageManifest.fromJson(source);
      source['user_id'] = '7';
      expect(manifest.userId, '9007199254740993');
      expect(manifest.departmentNumber, '-20');
      expect(manifest.counts['items'], 1);
      expect(manifest.pages.single.bytes, manifest.totalBytes);
      final exported = manifest.toJson();
      exported['user_id'] = '8';
      expect(manifest.toJson()['user_id'], '9007199254740993');
    });

    test('rechaza conteos negativos, omitidos, excesivos o inconsistentes', () {
      for (final counts in [
        {'items': -1, 'departamentos': 0, 'ubicaciones': 0, 'empleados': 0},
        {'items': 1, 'departamentos': 0, 'ubicaciones': 0},
        {'items': 10001, 'departamentos': 0, 'ubicaciones': 0, 'empleados': 0},
        {'items': 2, 'departamentos': 0, 'ubicaciones': 0, 'empleados': 0},
      ]) {
        final json = validManifest()..['counts'] = counts;
        expect(() => PackageManifest.fromJson(json),
            throwsA(isA<DataContractException>()));
      }
    });

    test('rechaza páginas discontinuas y bytes o hash inválidos', () {
      final mutations = <void Function(JsonMap)>[
        (json) => json['pages'] = <JsonMap>[],
        (json) => (json['pages'] as List).first['page'] = 2,
        (json) => (json['pages'] as List).first['bytes'] = 1048577,
        (json) => (json['pages'] as List).first['sha256'] = 'not-a-sha256',
        (json) => json['total_bytes'] = 121,
        (json) => json['total_bytes'] = 20971521,
        (json) => (json['pages'] as List).first['counts']['items'] = 251,
      ];
      for (final mutate in mutations) {
        final json = validManifest();
        mutate(json);
        expect(() => PackageManifest.fromJson(json),
            throwsA(isA<DataContractException>()));
      }
    });
  });

  group('Cliente móvil HTTP', () {
    test('pagina sin perder filtros ni bearer, sin seguir redirects', () async {
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/mobile/departments/-20/locations');
        expect(request.url.queryParameters['periodo_id'], '12');
        expect(request.headers['authorization'], 'Bearer test-token');
        expect(request.followRedirects, isFalse);
        final cursor = request.url.queryParameters['cursor'];
        return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': cursor == null ? '30' : '32',
                  'numero_departamento': '-20',
                  'descripcion': 'Oficina'
                },
              ],
              'next_cursor': cursor == null ? 'opaque+/cursor=' : null,
            }),
            200);
      });
      addTearDown(mock.close);
      final locations = await mockApi(mock).locations('12', '-20');
      expect(locations.map((row) => row['id']), ['30', '32']);
      expect(requests, hasLength(2));
      expect(requests.last.url.queryParameters['cursor'], 'opaque+/cursor=');
    });

    test('rechaza cursor repetido antes de un bucle infinito', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        return http.Response('{"data":[],"next_cursor":"same"}', 200);
      });
      addTearDown(mock.close);
      await expectLater(mockApi(mock).departments('12'),
          throwsA(isA<DataContractException>()));
      expect(calls, 2);
    });

    test('un error 503 conserva código y espera de reintento', () async {
      final mock = MockClient((request) async => http.Response(
          '{"error":{"code":"SERVER_NOT_READY","retryable":true}}', 503,
          headers: {'retry-after': '60'}));
      addTearDown(mock.close);
      await expectLater(
        mockApi(mock).departments('12'),
        throwsA(isA<MobileApiException>()
            .having((error) => error.status, 'status', 503)
            .having((error) => error.code, 'code', 'SERVER_NOT_READY')
            .having((error) => error.retryable, 'retryable', isTrue)
            .having((error) => error.retryAfterSeconds, 'retry after', 60)),
      );
    });

    test('un 401 HTML no se acepta como JSON válido ni error reintentable',
        () async {
      final mock = MockClient(
          (request) async => http.Response('<html>Login</html>', 401));
      addTearDown(mock.close);
      await expectLater(
        mockApi(mock).departments('12'),
        throwsA(isA<MobileApiException>()
            .having((error) => error.status, 'status', 401)
            .having((error) => error.retryable, 'retryable', isFalse)),
      );
    });

    test('rechaza listado JSON con una forma diferente al contrato', () async {
      final mock =
          MockClient((request) async => http.Response('{"data":{}}', 200));
      addTearDown(mock.close);
      await expectLater(mockApi(mock).departments('12'),
          throwsA(isA<DataContractException>()));
    });

    test('JSON roto en una respuesta 200 produce error de contrato tipado', () async {
      final mock = MockClient((request) async => http.Response('<html>Error</html>', 200));
      addTearDown(mock.close);
      await expectLater(mockApi(mock).departments('12'),
          throwsA(isA<DataContractException>()));
    });

    test('no hace solicitudes sin credencial y no incluye tokens en URL',
        () async {
      var called = false;
      final mock = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });
      addTearDown(mock.close);
      await expectLater(
        mockApi(mock, tokenProvider: () async => null).departments('12'),
        throwsA(isA<MobileApiException>()
            .having((error) => error.code, 'code', 'AUTH_REQUIRED')),
      );
      expect(called, isFalse);
    });
  });

  group('Publicación y autorización del paquete local', () {
    late InventoryDatabase database;
    late FixturePackage package;
    late MockClient client;

    setUpAll(sqfliteFfiInit);
    setUp(() {
      package = fixturePackage();
      database = InventoryDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      client = MockClient((request) async {
        if (request.url.path.contains('/pages/')) {
          return http.Response.bytes(package.pages[int.parse(request.url.pathSegments.last)]!, 200);
        }
        return http.Response('{}', 404);
      });
    });
    tearDown(() async {
      client.close();
      await database.close();
    });

    InventoryRepository repository({MobileSession? session}) => InventoryRepository(
      database: database,
      api: mockApi(client),
      session: session ?? fixtureSession(),
      clock: () => fixtureNow,
    );

    test('una sesión sin autorización offline no captura aunque conserve un paquete vigente', () async {
      final original = fixtureSession();
      final withoutLease = MobileSession(
        userId: original.userId,
        deviceId: original.deviceId,
        userName: original.userName,
        permissions: original.permissions,
        commands: original.commands,
      );
      final repo = repository(session: withoutLease);
      await repo.installPackage(package.manifest, period: fixturePeriod());
      await expectLater(repo.confirmReview(fixturePackageId, '1'),
          throwsA(isA<DataContractException>()));
      expect(await (await database.database).query('sync_queue'), isEmpty);
      expect((await repo.item(fixturePackageId, '1'))!.reviewed, isFalse);
    });

    test('no publica un paquete cuya ubicación actual pertenece a otro departamento', () async {
      final page = jsonObject(jsonDecode(utf8.decode(package.pages[1]!)));
      (page['departamentos'] as List).add({'numero_departamento': '99', 'descripcion': 'Otro departamento'});
      (page['ubicaciones'] as List).first['numero_departamento'] = '99';
      final bytes = utf8.encode(jsonEncode(page));
      final counts = {for (final key in packageCollections) key: (page[key] as List).length};
      final manifest = package.manifest.toJson()
        ..['counts'] = counts
        ..['total_bytes'] = bytes.length
        ..['pages'] = [{
          'page': 1, 'bytes': bytes.length, 'sha256': sha256.convert(bytes).toString(),
          'counts': counts,
        }];
      package = FixturePackage(PackageManifest.fromJson(manifest), {1: bytes});
      final repo = repository();
      await expectLater(repo.installPackage(package.manifest, period: fixturePeriod()),
          throwsA(isA<DataContractException>()));
      expect(await repo.downloadedPackages(), isEmpty);
    });
  });
}
