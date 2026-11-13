// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/application/session_vault.dart';
import 'package:inventario_app/data/database.dart';
import 'package:inventario_app/data/models.dart';

import 'package:inventario_app/main.dart';
import 'package:inventario_app/pantallas/seleccion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/inventory_fixture.dart';
import 'support/session_vault_fake.dart';

class _FailingSessionVault extends MemorySessionVault {
  int clearAttempts = 0;

  @override
  Future<SavedInventorySession?> restore() async =>
      throw const DataContractException(
          'No se pudo leer el almacenamiento seguro.');

  @override
  Future<void> clear() async {
    clearAttempts++;
    throw const DataContractException(
        'No se pudo limpiar el almacenamiento seguro.');
  }
}

void main() {
  testWidgets('La aplicación inicia en el acceso a inventario',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(InventarioApp(vault: MemorySessionVault()));
    await tester.pumpAndSettle();

    expect(find.text('Sistema de Inventario'), findsOneWidget);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsOneWidget);
    expect(find.text('INGRESAR'), findsOneWidget);
  });

  testWidgets(
      'fallos al restaurar y borrar la sesión se muestran sin excepción no manejada',
      (tester) async {
    final vault = _FailingSessionVault();
    await tester.pumpWidget(InventarioApp(vault: vault));
    await tester.pumpAndSettle();
    expect(
        find.text('No se pudo leer el almacenamiento seguro.'), findsOneWidget);

    await tester.tap(find.text('Volver a iniciar sesión'));
    await tester.pumpAndSettle();

    expect(vault.clearAttempts, 1);
    expect(find.text('No se pudo limpiar el almacenamiento seguro.'),
        findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restaura una sesión guardada sin exigir una autenticación HTTP',
      (tester) async {
    sqfliteFfiInit();
    final database = InventoryDatabase(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    await tester.runAsync(() => database.database);
    final saved = SavedInventorySession(
      baseUri: Uri.parse('https://inventory.test/api/v1/mobile'),
      accessToken: 'saved-token',
      sessionJson: {
        'user': {'id': '7', 'name': 'Revisor guardado'},
        'device': {'id': fixtureDeviceId},
        'permissions': ['hacer_levantamiento'],
        'supported_commands': ['confirmar_revision'],
        'offline_authorized_until':
            fixtureNow.add(const Duration(days: 1)).toIso8601String(),
      },
    );
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      throw http.ClientException('Sin conexión');
    });
    addTearDown(() async {
      client.close();
      await database.close();
    });
    await tester.pumpWidget(InventarioApp(
        vault: MemorySessionVault(saved),
        database: database,
        client: client,
        clock: () => fixtureNow));
    for (var attempt = 0;
        attempt < 10 && find.byType(PantallaSeleccion).evaluate().isEmpty;
        attempt++) {
      await tester.pump();
    }
    expect(find.byType(PantallaSeleccion), findsOneWidget);
    expect(find.text('Revisor guardado'), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsNothing);
    // Finish the real SQLite query before disposing the screen. Advancing fake
    // animation time alone does not let FFI I/O complete or cancel its lock timer.
    final emptyDownloads =
        find.text('Aún no hay ubicaciones descargadas en este dispositivo.');
    for (var attempt = 0;
        attempt < 100 && emptyDownloads.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(emptyDownloads, findsOneWidget);
    expect(requests.any((uri) => uri.path.contains('/auth/')), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
