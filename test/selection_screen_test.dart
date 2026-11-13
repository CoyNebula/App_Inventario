import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/database.dart';
import 'package:inventario_app/data/engine.dart';
import 'package:inventario_app/data/models.dart';
import 'package:inventario_app/pantallas/levantamiento.dart';
import 'package:inventario_app/pantallas/seleccion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/inventory_fixture.dart';

http.Response jsonReply(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});

JsonMap sessionReply(MobileSession session) => {
      'user': {'id': session.userId, 'name': session.userName},
      'device': {'id': session.deviceId},
      'permissions': session.permissions.toList(),
      'supported_commands': session.commands.toList(),
      'offline_authorized_until': session.offlineUntil?.toIso8601String(),
    };

void main() {
  setUpAll(sqfliteFfiInit);

  Future<InventoryDataEngine> makeEngine(
      Future<http.Response> Function(http.Request) handler,
      {MobileSession? session}) async {
    final database = InventoryDatabase(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    await database.database;
    final client = MockClient(handler);
    final engine = InventoryDataEngine(
      baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
      session: session ?? fixtureSession(),
      tokenProvider: () async => 'test-token',
      database: database,
      client: client,
      clock: () => fixtureNow,
    );
    addTearDown(() async {
      engine.closeNetwork();
      client.close();
      await database.close();
    });
    return engine;
  }

  Future<void> settle(WidgetTester tester, {bool Function()? ready, bool ignoreLoading = false}) async {
    // Route transitions can start new SQLite futures on their final frame.
    // Alternate real IO time and frames until the visible loading state ends;
    // pumpAndSettle cannot drain FFI while an indeterminate indicator animates.
    await tester.pump(const Duration(milliseconds: 400));
    for (var attempt = 0; attempt < 250; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      final loading = find
              .byType(CircularProgressIndicator)
              .evaluate()
              .isNotEmpty ||
          find.byKey(const ValueKey('local-loading')).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('period-loading')).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('download-progress')).evaluate().isNotEmpty;
      if ((!loading || ignoreLoading) && (ready == null || ready())) return;
    }
    fail('La pantalla no terminó de cargar después de drenar SQLite y red.');
  }

  Future<void> show(WidgetTester tester, InventoryDataEngine engine, {bool wait = true}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: PantallaSeleccion(
      engine: engine,
      onSignOut: () async {},
    )));
    if (wait) await settle(tester);
    else await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> choose(WidgetTester tester, String label, String option,
      {bool waitForDependencies = true}) async {
    final field = find.byWidgetPredicate((widget) =>
        (widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText?.replaceAll(' *', '') == label) ||
        (widget is DropdownButtonFormField<int> &&
        widget.decoration.labelText == label));
    await tester.ensureVisible(field);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(option).last);
    if (!waitForDependencies) { await tester.pump(const Duration(milliseconds: 400)); return; }
    await settle(tester,
        ready: waitForDependencies
            ? () =>
                find.text('Cargando departamentos…').evaluate().isEmpty &&
                find.text('Cargando ubicaciones…').evaluate().isEmpty
            : null);
  }

  testWidgets(
      'descarga guardada abre sin API disponible y conserva datos al volver',
      (tester) async {
    final package = fixturePackage();
    var requests = 0;
    final engine = await tester.runAsync(() => makeEngine((request) async {
          if (request.url.path.contains('/pages/')) {
            return http.Response.bytes(package.pages[1]!, 200);
          }
          requests++;
          return jsonReply({
            'error': {'code': 'SERVER_NOT_READY'}
          }, 503);
        }));
    await tester.runAsync(() => engine!.repository
        .installPackage(package.manifest, period: fixturePeriod()));
    await show(tester, engine!);
    expect(find.text('Origen'), findsOneWidget);
    expect(find.text('Departamento prueba'), findsOneWidget);
    expect(find.text('Periodo prueba'), findsOneWidget);
    expect(find.textContaining('El servicio de inventario no está disponible'),
        findsOneWidget);
    final before = requests;
    await tester.tap(find.byKey(const ValueKey('open-$fixturePackageId')));
    await settle(tester,
        ready: () => find.byType(PantallaLevantamiento).evaluate().isNotEmpty);
    expect(find.byType(PantallaLevantamiento), findsOneWidget);
    expect(requests, before);
    Navigator.of(tester.element(find.byType(PantallaLevantamiento))).pop();
    await settle(tester,
        ready: () =>
            find.byType(PantallaLevantamiento).evaluate().isEmpty &&
            find
                .byKey(const ValueKey('cached-$fixturePackageId'))
                .evaluate()
                .isNotEmpty);
    expect(
        find.byKey(const ValueKey('cached-$fixturePackageId')), findsOneWidget);
    expect(await tester.runAsync(() => engine.repository.downloadedPackages()),
        hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cambiar periodo limpia hijos y descarta departamentos tardíos',
      (tester) async {
    final lateDepartments = Completer<http.Response>();
    var firstDepartmentRequested = false;
    final engine = await tester.runAsync(() => makeEngine((request) async {
          if (request.url.path.endsWith('/periods/lookup')) {
            return jsonReply({
              'exists': true,
              'period': request.url.queryParameters['mes'] == '11' ? fixturePeriod() : {...fixturePeriod(), 'id': '15', 'mes':12, 'nombre': 'Periodo segundo'},
              'can_create': false, 'can_close': false,
            });
          }
          if (request.url.path.endsWith('/departments')) {
            if (request.url.queryParameters['periodo_id'] == '12') {
              firstDepartmentRequested = true;
              return lateDepartments.future;
            }
            return jsonReply({
              'data': [
                {
                  'numero_departamento': '21',
                  'descripcion': 'Departamento segundo'
                }
              ],
              'next_cursor': null
            });
          }
          return jsonReply({}, 404);
        }));
    await show(tester, engine!, wait:false);
    await settle(tester, ready:() => firstDepartmentRequested, ignoreLoading:true);
    await choose(tester, 'Mes', 'Diciembre', waitForDependencies:false);
    await tester.tap(find.byKey(const Key('load-period')));
    await settle(tester);
    lateDepartments.complete(jsonReply({
      'data': [
        {'numero_departamento': '20', 'descripcion': 'Departamento anterior'}
      ],
      'next_cursor': null
    }));
    await settle(tester);
    final departmentsField = find.byWidgetPredicate((widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == 'Departamento *');
    await tester.ensureVisible(departmentsField);
    await tester.tap(departmentsField);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Departamento segundo'), findsOneWidget);
    expect(find.text('Departamento anterior'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('download-location')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'cambiar departamento resetea ubicación y descarta respuesta anterior',
      (tester) async {
    final lateLocations = Completer<http.Response>();
    final engine = await tester.runAsync(() => makeEngine((request) async {
          if (request.url.path.endsWith('/periods/lookup'))
            return jsonReply({
              'exists': true, 'period': fixturePeriod(),
              'can_create':false,'can_close':false,
            });
          if (request.url.path.endsWith('/departments'))
            return jsonReply({
              'data': [
                {
                  'numero_departamento': '20',
                  'descripcion': 'Departamento primero'
                },
                {
                  'numero_departamento': '21',
                  'descripcion': 'Departamento segundo'
                },
              ],
              'next_cursor': null
            });
          if (request.url.path.contains('/departments/20/locations'))
            return lateLocations.future;
          if (request.url.path.contains('/departments/21/locations'))
            return jsonReply({
              'data': [
                {
                  'id': '31',
                  'numero_departamento': '21',
                  'descripcion': 'Ubicación vigente'
                },
              ],
              'next_cursor': null
            });
          return jsonReply({}, 404);
        }));
    await show(tester, engine!);
    await choose(tester, 'Departamento', 'Departamento primero',
        waitForDependencies: false);
    await choose(tester, 'Departamento', 'Departamento segundo');
    lateLocations.complete(jsonReply({
      'data': [
        {
          'id': '30',
          'numero_departamento': '20',
          'descripcion': 'Ubicación anterior'
        }
      ],
      'next_cursor': null
    }));
    await settle(tester);
    final locationsField = find.byWidgetPredicate((widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == 'Ubicación *');
    await tester.ensureVisible(locationsField);
    await tester.tap(locationsField);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ubicación vigente'), findsOneWidget);
    expect(find.text('Ubicación anterior'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'revisor descarga sin catálogo de reasignación y abre el paquete publicado',
      (tester) async {
    final reviewer = MobileSession(
      userId: '7',
      deviceId: fixtureDeviceId,
      userName: 'Revisor',
      permissions: {'hacer_levantamiento'},
      commands: {'confirmar_revision'},
      offlineUntil: fixtureNow.add(const Duration(days: 1)),
    );
    FixturePackage? package;
    JsonMap? submitted;
    final engine = await tester.runAsync(() => makeEngine((request) async {
          if (request.url.path.endsWith('/session'))
            return jsonReply(sessionReply(reviewer));
          if (request.url.path.endsWith('/periods/lookup'))
            return jsonReply({'exists':true,'period':fixturePeriod(),'can_create':false,'can_close':false});
          if (request.url.path.endsWith('/periods'))
            return jsonReply({
              'data': [fixturePeriod()],
              'next_cursor': null
            });
          if (request.url.path.endsWith('/departments'))
            return jsonReply({
              'data': [
                {
                  'numero_departamento': '20',
                  'descripcion': 'Departamento prueba'
                }
              ],
              'next_cursor': null
            });
          if (request.url.path.endsWith('/locations'))
            return jsonReply({
              'data': [
                {
                  'id': '30',
                  'numero_departamento': '20',
                  'descripcion': 'Origen'
                }
              ],
              'next_cursor': null
            });
          if (request.method == 'POST' &&
              request.url.path.endsWith('/packages')) {
            submitted = jsonObject(jsonDecode(request.body));
            package =
                fixturePackage(packageId: submitted!['package_id'] as String);
            return jsonReply(package!.manifest.toJson(), 201);
          }
          if (request.url.path.contains('/pages/'))
            return http.Response.bytes(package!.pages[1]!, 200);
          return jsonReply({}, 404);
        }, session: reviewer));
    await show(tester, engine!);
    await choose(tester, 'Departamento', 'Departamento prueba');
    await choose(tester, 'Ubicación', 'Origen');
    await tester.ensureVisible(find.byKey(const ValueKey('download-location')));
    await tester.tap(find.byKey(const ValueKey('download-location')));
    await settle(tester,
        ready: () => find.byType(PantallaLevantamiento).evaluate().isNotEmpty);
    expect(submitted?['include_reassignment_catalogs'], false);
    expect(find.byType(PantallaLevantamiento), findsOneWidget);
    expect(await tester.runAsync(() => engine.repository.downloadedPackages()),
        hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('crear periodo requiere confirmación y conserva el año mes y nombre', (tester) async {
    final creates = <JsonMap>[];
    var exists = false;
    final engine = await tester.runAsync(() => makeEngine((request) async {
      if (request.url.path.endsWith('/periods/lookup')) return jsonReply({
        'exists': exists, 'period': exists ? fixturePeriod() : null,
        'can_create': !exists, 'can_close': exists,
      });
      if (request.method == 'POST' && request.url.path.endsWith('/periods')) {
        creates.add(jsonObject(jsonDecode(request.body)));
        exists = true;
        return jsonReply({'period': {...fixturePeriod(),'nombre':'Levantamiento anual 2026'}}, 201);
      }
      if (request.url.path.endsWith('/departments')) return jsonReply({'data': [],'next_cursor':null});
      return jsonReply({},404);
    }));
    await show(tester, engine!);
    expect(creates,isEmpty);
    await tester.enterText(find.byKey(const Key('period-name')), 'Levantamiento anual 2026');
    await tester.tap(find.byKey(const Key('load-period')));
    await settle(tester);
    expect(find.text('Crear periodo de levantamiento'), findsOneWidget);
    expect(creates,isEmpty);
    await tester.tap(find.text('Cancelar'));
    await settle(tester);
    expect(creates,isEmpty);
    await tester.tap(find.byKey(const Key('load-period')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('confirm-create-period')));
    await settle(tester);
    expect(creates.single, {'anio':2026,'mes':11,'nombre':'Levantamiento anual 2026'});
    expect(find.textContaining('Levantamiento anual 2026 · Abierto'), findsOneWidget);
    expect(find.byKey(const Key('close-period')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('capturista carga pero no crea un periodo inexistente', (tester) async {
    var writes = 0;
    final engine = await tester.runAsync(() => makeEngine((request) async {
      if (request.method != 'GET') writes++;
      return jsonReply({'exists':false,'period':null,'can_create':false,'can_close':false});
    }));
    await show(tester, engine!);
    await tester.enterText(find.byKey(const Key('period-name')), 'Periodo faltante');
    await tester.tap(find.byKey(const Key('load-period')));
    await settle(tester);
    expect(find.text('No existe el periodo de levantamiento. Consulta con el Administrador.'), findsOneWidget);
    expect(find.byKey(const Key('confirm-create-period')), findsNothing);
    expect(find.byKey(const Key('close-period')), findsNothing);
    expect(writes,0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cerrar periodo confirma, conserva pendientes y deshabilita descargas', (tester) async {
    final package = fixturePackage();
    var closed = false;
    var closes = 0;
    final engine = await tester.runAsync(() => makeEngine((request) async {
      if (request.url.path.contains('/pages/')) return http.Response.bytes(package.pages[1]!,200);
      if (request.url.path.endsWith('/periods/lookup')) return jsonReply({
        'exists':true,'period':{...fixturePeriod(),'estado':closed?'cerrado':'abierto','mobile_eligible':!closed},
        'can_create':false,'can_close':!closed,
      });
      if (request.url.path.endsWith('/close')) {
        closes++;
        closed = true;
        return jsonReply({'period':{...fixturePeriod(),'estado':'cerrado','mobile_eligible':false}});
      }
      if (request.url.path.endsWith('/departments')) return jsonReply({'data':[],'next_cursor':null});
      return jsonReply({},404);
    }));
    await tester.runAsync(() async {
      await engine!.repository.installPackage(package.manifest,period:fixturePeriod());
      await engine.repository.confirmReview(fixturePackageId,'1',observations:'Captura pendiente');
    });
    await show(tester, engine!);
    await tester.ensureVisible(find.byKey(const Key('close-period')));
    await tester.tap(find.byKey(const Key('close-period')));
    await settle(tester,ready:() => find.byKey(const Key('confirm-close-period')).evaluate().isNotEmpty);
    expect(find.textContaining('Hay 1 capturas por sincronizar'), findsOneWidget);
    expect(closes,0);
    await tester.tap(find.byKey(const Key('confirm-close-period')));
    await settle(tester,ready:() => find.textContaining('Periodo prueba · Cerrado').evaluate().isNotEmpty);
    expect(closes,1);
    final queue = await tester.runAsync(() => engine.repository.operations());
    expect(queue!.single.status, 'pending');
    expect(queue.single.operation['payload']['observaciones'],'Captura pendiente');
    expect((await tester.runAsync(() => engine.repository.periodForPackage(fixturePackageId)))!.state,'cerrado');
    expect(tester.widget<FilledButton>(find.byKey(const Key('download-location'))).onPressed,isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
