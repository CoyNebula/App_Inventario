import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/data/inventory_data.dart';
import 'package:inventario_app/pantallas/levantamiento.dart';
import 'package:inventario_app/pantallas/reasignacion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/inventory_fixture.dart';

void main() {
  sqfliteFfiInit();
  late InventoryDatabase database;
  late InventoryDataEngine engine;
  late MockClient client;
  late FixturePackage package;
  late bool allowNetwork;
  late int requests;
  late Future<http.Response> Function(http.Request) online;

  http.Response jsonResponse(JsonMap value, [int status = 200]) =>
      http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  setUp(() {
    allowNetwork = true;
    requests = 0;
    package = fixturePackage();
    online = (_) async => jsonResponse({
          'error': {'code': 'AUTH_REQUIRED'}
        }, 401);
    database = InventoryDatabase(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    client = MockClient((request) async {
      requests++;
      if (!allowNetwork)
        throw StateError('La pantalla offline intentó usar HTTP.');
      if (request.url.path.contains('/pages/') &&
          request.url.path.contains(fixturePackageId)) {
        return http.Response.bytes(
            package.pages[int.parse(request.url.pathSegments.last)]!, 200);
      }
      return online(request);
    });
    engine = InventoryDataEngine(
        baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
        session: fixtureSession(),
        tokenProvider: () async => 'test-token',
        database: database,
        client: client,
        clock: () => fixtureNow);
  });
  tearDown(() async {
    engine.closeNetwork();
    client.close();
    await database.close();
  });

  Future<void> settle(WidgetTester tester, {Finder? until}) async {
    // SQLite FFI uses real I/O while widget animations use fake time.
    var readyFrames = 0;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
      final ready = until != null
          ? until.evaluate().isNotEmpty
          : find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.text('Guardando…').evaluate().isEmpty &&
              find.text('Buscando…').evaluate().isEmpty;
      readyFrames = ready ? readyFrames + 1 : 0;
      if (readyFrames >= 3) {
        await tester.pump(const Duration(milliseconds: 350));
        return;
      }
    }
    throw TestFailure('La pantalla no completó su operación asíncrona.');
  }

  Future<void> showScreen(WidgetTester tester,
      {Future<void> Function()? signOut,
      Future<void> Function()? beforeOpen,
      Size size = const Size(1100, 1200)}) async {
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => engine.repository
        .installPackage(package.manifest, period: fixturePeriod()));
    if (beforeOpen != null) await tester.runAsync(beforeOpen);
    requests = 0;
    allowNetwork = false;
    await tester.pumpWidget(RepaintBoundary(
        key: const Key('screen_capture'),
        child: MaterialApp(
            home: PantallaLevantamiento(
                engine: engine,
                packageId: fixturePackageId,
                onSignOut: signOut ?? () async {}))));
    await settle(tester);
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(target, 280,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  Future<void> lookup(WidgetTester tester, [String qr = '00001']) async {
    await reveal(tester, find.byKey(const Key('codigo_manual')));
    await tester.enterText(find.byKey(const Key('codigo_manual')), qr);
    await tester.tap(find.byKey(const Key('buscar_bien')));
    await settle(tester);
  }

  testWidgets(
      'entrada manual confirma offline, muestra avance y bloquea duplicado',
      (tester) async {
    await showScreen(tester);
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.text('REVISADOS'), findsOneWidget);
    await lookup(tester,
        '{"clave_activo_fijo":"5150-000001","numero_inventario_consecutivo":"00001"}');
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    await tester.enterText(
        find.byKey(const Key('observaciones_bien')), '  Nota de campo  ');
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    await tester.tap(find.byKey(const Key('guardar_bien')));
    await settle(tester);
    final operations =
        await tester.runAsync(() => engine.repository.operations());
    expect(operations, hasLength(1));
    expect(operations!.single.status, 'pending');
    expect(operations.single.operation['original']['revisado'], false);
    expect(operations.single.operation['payload']['observaciones'],
        '  Nota de campo  ');
    expect(requests, 0);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('guardar_bien')))
            .onPressed,
        null);
    final progress = await tester
        .runAsync(() => engine.repository.progress(fixturePackageId));
    expect(progress!.reviewed, 1);
  });

  testWidgets('QR fuera de descarga no inventa una ficha ni una captura',
      (tester) async {
    await showScreen(tester);
    await lookup(tester, '99999');
    expect(find.text('No disponible en esta descarga'), findsOneWidget);
    expect(find.byKey(const Key('ficha_bien')), findsNothing);
    expect(
        await tester.runAsync(() => engine.repository.operations()), isEmpty);
    expect(requests, 0);
  });

  testWidgets('otro revisor queda solo lectura y muestra su nombre real',
      (tester) async {
    final item = fixtureItem(reviewed: true, reviewer: '8')
      ..['revisado_por_nombre'] = 'Revisor externo';
    package = fixturePackage(items: [item]);
    await showScreen(tester);
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    expect(find.text('Revisor externo'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('observaciones_bien')))
            .readOnly,
        true);
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('guardar_bien')))
            .onPressed,
        null);
    expect(
        await tester.runAsync(() => engine.repository.operations()), isEmpty);
    expect(requests, 0);
  });

  testWidgets('revisión propia permite actualizar observaciones offline',
      (tester) async {
    package = fixturePackage(items: [fixtureItem(reviewed: true)]);
    await showScreen(tester);
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    await tester.enterText(
        find.byKey(const Key('observaciones_bien')), 'Nota corregida');
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    expect(find.text('Actualizar observaciones'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guardar_bien')));
    await settle(tester);
    final rows = await tester.runAsync(() => engine.repository.operations());
    expect(rows!.single.type, 'actualizar_observaciones');
    expect(rows.single.operation['original']['revisado'], true);
    expect(rows.single.operation['expected_version']['detalle'], '4');
    expect(rows.single.operation['payload']['observaciones'], 'Nota corregida');
    expect(requests, 0);
  });

  testWidgets(
      'reasignación usa búsqueda local y valida fecha antes de guardar propuesta',
      (tester) async {
    await showScreen(tester);
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('reasignar_bien')));
    await tester.tap(find.byKey(const Key('reasignar_bien')));
    await settle(tester);
    expect(find.byType(PantallaReasignacion), findsOneWidget);
    await tester.enterText(find.byKey(const Key('buscar_empleado')), 'Nu');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('empleado_151')), findsNothing);
    await tester.enterText(find.byKey(const Key('buscar_empleado')), 'Nue');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('empleado_151')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ubicacion_20_')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destino').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('fecha_resguardo')), '2026-02-30');
    await reveal(tester, find.byKey(const Key('guardar_reasignacion')));
    await tester.tap(find.byKey(const Key('guardar_reasignacion')));
    await tester.pumpAndSettle();
    expect(find.text('La fecha no existe.'), findsOneWidget);
    expect(
        await tester.runAsync(() => engine.repository.operations()), isEmpty);
    await reveal(tester, find.byKey(const Key('fecha_resguardo')));
    await tester.enterText(
        find.byKey(const Key('fecha_resguardo')), '2026-11-12');
    await tester.enterText(find.byKey(const Key('observaciones_reasignacion')),
        'Cambio de resguardante');
    await reveal(tester, find.byKey(const Key('guardar_reasignacion')));
    await tester.tap(find.byKey(const Key('guardar_reasignacion')));
    await settle(tester,
        until: find.text(
            'Propuesta guardada en este dispositivo. Pendiente de sincronizar.'));
    await tester.pumpAndSettle();
    final rows = await tester.runAsync(() => engine.repository.operations());
    expect(rows!.single.type, 'proponer_reasignacion');
    expect(rows.single.operation['payload']['empleado_id'], '151');
    expect(rows.single.operation['payload']['ubicacion_id'], '31');
    expect(rows.single.operation['original']['resguardante_id'], '150');
    expect(requests, 0);
    expect(find.byType(PantallaReasignacion), findsNothing);
  });

  testWidgets(
      'sincroniza y continúa la ficha en el paquete nuevo con datos oficiales',
      (tester) async {
    await showScreen(tester);
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    await tester.tap(find.byKey(const Key('guardar_bien')));
    await settle(tester);
    FixturePackage? replacement;
    online = (request) async {
      if (request.url.path.endsWith('/session'))
        return jsonResponse({
          'user': {'id': '7', 'name': 'Revisor de prueba'},
          'device': {'id': fixtureDeviceId},
          'permissions': ['hacer_levantamiento', 'asignar'],
          'supported_commands':
              SyncCommand.values.map((cmd) => cmd.wireName).toList(),
          'offline_authorized_until':
              fixtureNow.add(const Duration(days: 1)).toIso8601String()
        });
      if (request.url.path.endsWith('/sync')) {
        final body = jsonObject(jsonDecode(request.body));
        final op = jsonObject((body['operations'] as List).single);
        return jsonResponse({
          'batch_id': body['batch_id'],
          'results': [
            {
              'operation_id': op['operation_id'],
              'estado': 'aplicada',
              'code': 'APPLIED',
              'received_at': fixtureNow.toIso8601String(),
              'committed_at':
                  fixtureNow.add(const Duration(seconds: 1)).toIso8601String(),
              'resulting_version': {
                'detalle': '5',
                'inventario': '9',
                'resguardo_id': '821',
                'resguardo': '3'
              },
              'replayed': false,
              'incidencia_id': null
            }
          ]
        });
      }
      if (request.url.path.endsWith('/periods'))
        return jsonResponse({
          'data': [fixturePeriod()],
          'next_cursor': null
        });
      if (request.url.path.endsWith('/packages')) {
        final id = jsonObject(jsonDecode(request.body))['package_id'] as String;
        replacement = fixturePackage(packageId: id, items: [
          fixtureItem(reviewed: true)
            ..['observaciones'] = 'Observación oficial'
            ..['fecha_revisado'] = '2026-11-12'
            ..['version'] = {
              'detalle': '5',
              'inventario': '9',
              'resguardo_id': '821',
              'resguardo': '3'
            }
        ]);
        return jsonResponse(replacement!.manifest.toJson());
      }
      if (request.url.path.contains('/pages/'))
        return http.Response.bytes(replacement!.pages[1]!, 200);
      throw StateError('Solicitud no prevista');
    };
    allowNetwork = true;
    await reveal(tester, find.byKey(const Key('sincronizar')));
    await tester.tap(find.byKey(const Key('sincronizar')));
    await settle(tester, until: find.text('Resultado de sincronización'));
    expect(find.text('Resultado de sincronización'), findsOneWidget);
    expect(find.text('1 enviados · 0 pendientes'), findsOneWidget);
    await tester.tap(find.text('Cerrar').last);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    final field =
        tester.widget<TextField>(find.byKey(const Key('observaciones_bien')));
    expect(field.controller!.text, 'Observación oficial');
    final active =
        await tester.runAsync(() => engine.repository.downloadedPackages());
    expect(active!.single['package_id'], replacement!.manifest.packageId);
    expect(
        (await tester.runAsync(() => engine.repository.operations()))!
            .single
            .status,
        'synced');
  });

  testWidgets(
      'salir con observaciones sin guardar permite seguir editando sin perder texto',
      (tester) async {
    var signedOut = false;
    await showScreen(tester, signOut: () async {
      signedOut = true;
    });
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    await tester.enterText(
        find.byKey(const Key('observaciones_bien')), 'Borrador sin guardar');
    await tester.tap(find.byTooltip('Cerrar sesión'));
    await tester.pumpAndSettle();
    expect(find.text('Observaciones sin guardar'), findsOneWidget);
    await tester.tap(find.text('Seguir editando'));
    await tester.pumpAndSettle();
    expect(signedOut, false);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('observaciones_bien')))
            .controller!
            .text,
        'Borrador sin guardar');
    expect(
        await tester.runAsync(() => engine.repository.operations()), isEmpty);
    expect(requests, 0);
  });

  testWidgets(
      'resolver conflicto exige acción explícita y conserva evidencia si sesión venció',
      (tester) async {
    late String operationId;
    final receipt = <String, dynamic>{};
    await showScreen(tester, beforeOpen: () async {
      operationId =
          await engine.repository.confirmReview(fixturePackageId, '1');
      receipt.addAll({
        'operation_id': operationId,
        'estado': 'conflicto',
        'code': 'VERSION_CONFLICT',
        'received_at': fixtureNow.toIso8601String(),
        'committed_at': fixtureNow.toIso8601String(),
        'resulting_version': null,
        'replayed': false,
        'incidencia_id': null
      });
      final db = await database.database;
      await db.update(
          'sync_queue',
          {
            'status': 'conflict',
            'last_error': 'VERSION_CONFLICT',
            'receipt_json': jsonEncode(receipt)
          },
          where: 'operation_uuid=?',
          whereArgs: [operationId]);
      await db.update('items', {'needs_refresh': 1},
          where: 'package_id=? AND detalle_id=?',
          whereArgs: [fixturePackageId, '1']);
    });
    await reveal(tester, find.text('Resolver'));
    await tester.tap(find.text('Resolver'));
    await tester.pumpAndSettle();
    expect(find.text('Resolver respuesta del servidor'), findsOneWidget);
    await tester.tap(find.text('Volver'));
    await tester.pumpAndSettle();
    var operation =
        (await tester.runAsync(() => engine.repository.operations()))!.single;
    expect(operation.resolvedAt, null);
    allowNetwork = true;
    await tester.tap(find.text('Resolver'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resolver y actualizar'));
    await settle(tester, until: find.text('Resultado de sincronización'));
    expect(
        find.textContaining('Renueva tu sesión con internet'), findsOneWidget);
    operation =
        (await tester.runAsync(() => engine.repository.operations()))!.single;
    expect(operation.uuid, operationId);
    expect(operation.status, 'conflict');
    expect(operation.resolvedAt, isNotNull);
    expect(operation.receipt, receipt);
    expect(
        (await tester.runAsync(() => engine.repository.downloadedPackages()))!
            .single['package_id'],
        fixturePackageId);
  });

  testWidgets(
      'teléfono 360x800 permite buscar, guardar y consultar avance sin desbordes',
      (tester) async {
    await showScreen(tester, size: const Size(360, 800));
    expect(tester.takeException(), null);
    await lookup(tester, '00001');
    await reveal(tester, find.byKey(const Key('observaciones_bien')));
    await tester.enterText(find.byKey(const Key('observaciones_bien')),
        'Verificado sin conexión en teléfono');
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    await tester.tap(find.byKey(const Key('guardar_bien')));
    await settle(tester);
    expect(tester.takeException(), null);
    final queue = await tester.runAsync(() => engine.repository.operations());
    expect(queue, hasLength(1));
    expect(queue!.single.status, 'pending');
    expect(queue.single.operation['payload']['observaciones'],
        'Verificado sin conexión en teléfono');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('guardar_bien')))
            .onPressed,
        null);
    await tester.scrollUntilVisible(find.text('TOTAL'), -280,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.text('REVISADOS'), findsOneWidget);
    expect(find.text('PENDIENTES'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final progress = await tester
        .runAsync(() => engine.repository.progress(fixturePackageId));
    expect([progress!.total, progress.reviewed, progress.pending], [1, 1, 0]);
    expect(requests, 0);
    expect(tester.takeException(), null);

    // Optional artifact requested for visual inspection. It uses the same
    // rendered phone viewport and requires no screenshot package.
    if (const bool.fromEnvironment('CAPTURE_SCREENSHOT')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('screen_capture')));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes != null) {
            final file = File('build/levantamiento-phone-360x800.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes.buffer.asUint8List());
          }
        } finally {
          image.dispose();
        }
      });
    }
  });

  testWidgets('un periodo cerrado conocido conserva consulta y bloquea captura',
      (tester) async {
    await showScreen(tester,
        beforeOpen: () => engine.repository.updatePeriodState(
            InventoryPeriod.fromJson(
                {...fixturePeriod(), 'estado': 'cerrado'})));
    expect(find.textContaining('Periodo cerrado.'), findsOneWidget);
    await lookup(tester);
    await reveal(tester, find.byKey(const Key('guardar_bien')));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('guardar_bien')))
            .onPressed,
        isNull);
    expect(
        await tester.runAsync(() => engine.repository.operations()), isEmpty);
    expect(requests, 0);
  });
}
