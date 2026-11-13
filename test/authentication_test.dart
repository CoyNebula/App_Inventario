import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventario_app/application/session_vault.dart';
import 'package:inventario_app/data/api_client.dart';
import 'package:inventario_app/data/models.dart';
import 'package:inventario_app/pantallas/login.dart';

import 'support/inventory_fixture.dart';
import 'support/session_vault_fake.dart';

JsonMap _authResult() => {
      'status': 'authenticated',
      'token_type': 'Bearer',
      'access_token': 'test-bearer',
      'session': {
        'user': {'id': '7', 'name': 'Revisor de prueba'},
        'device': {'id': fixtureDeviceId},
        'permissions': ['hacer_levantamiento', 'asignar'],
        'supported_commands':
            SyncCommand.values.map((c) => c.wireName).toList(),
        'offline_authorized_until': '2026-11-13T12:00:00Z',
      }
    };

void main() {
  test('login and factor are unauthenticated and preserve password bytes',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(_authResult()), 200);
    });
    addTearDown(client.close);
    final api = MobileApiClient(
        baseUri: Uri.parse('https://test.invalid/api/v1/mobile'),
        tokenProvider: () async => throw StateError('No token before login'),
        client: client);
    await api.login(
        email: 'revisor@test.invalid',
        password: ' contraseña con espacios ',
        deviceId: fixtureDeviceId,
        deviceName: 'Prueba');
    expect(requests.single.headers.containsKey('Authorization'), false);
    expect(jsonDecode(requests.single.body)['password'],
        ' contraseña con espacios ');
    await api.completeTwoFactor(
        challengeToken: 'challenge-test-token-123456', code: '001234');
    expect(requests.last.url.path, '/api/v1/mobile/auth/two-factor');
    expect(jsonDecode(requests.last.body)['code'], '001234');
    expect(requests.last.headers.containsKey('Authorization'), false);
  });

  test('saved session serializes identity and bearer without passwords',
      () async {
    final session = SavedInventorySession.fromLogin(
        Uri.parse('https://test.invalid/api/v1/mobile'), _authResult());
    final restored = SavedInventorySession.fromJson(
        jsonObject(jsonDecode(jsonEncode(session.toJson()))));
    expect(restored.session.userId, '7');
    expect(restored.session.deviceId, fixtureDeviceId);
    expect(restored.accessToken, 'test-bearer');
    expect(session.toJson().containsKey('password'), false);
    expect(
        () => SavedInventorySession.fromLogin(
            session.baseUri, {'status': 'two_factor_required'}),
        throwsA(isA<DataContractException>()));
  });

  Future<void> showLogin(WidgetTester tester, http.Client client,
      Future<void> Function(SavedInventorySession) onAuthenticated) async {
    await tester.pumpWidget(MaterialApp(
        home: PantallaLogin(
            vault: MemorySessionVault(),
            client: client,
            onAuthenticated: onAuthenticated)));
    await tester.enterText(
        find.byKey(const Key('login-email')), 'revisor@test.invalid');
    await tester.enterText(
        find.byKey(const Key('login-password')), 'UnaContraseña');
    await tester.ensureVisible(find.byKey(const Key('login-submit')));
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('login verifies with Laravel before opening inventory',
      (tester) async {
    SavedInventorySession? authenticated;
    final client = MockClient(
        (request) async => http.Response(jsonEncode(_authResult()), 200));
    addTearDown(client.close);
    await showLogin(tester, client, (session) async {
      authenticated = session;
    });
    await submit(tester);
    expect(authenticated?.session.userId, '7');
    expect(authenticated?.accessToken, 'test-bearer');
  });

  testWidgets('legacy username without @ reaches Laravel unchanged',
      (tester) async {
    JsonMap? sent;
    SavedInventorySession? authenticated;
    final client = MockClient((request) async {
      sent = jsonObject(jsonDecode(request.body));
      return http.Response(jsonEncode(_authResult()), 200);
    });
    addTearDown(client.close);
    await showLogin(tester, client, (session) async {
      authenticated = session;
    });
    await tester.enterText(find.byKey(const Key('login-email')), 'jclemente');
    await tester.enterText(
        find.byKey(const Key('login-password')), '123456789');
    await submit(tester);
    expect(sent?['email'], 'jclemente');
    expect(sent?['password'], '123456789');
    expect(authenticated?.session.userId, '7');
  });

  testWidgets('empty login name does not send credentials', (tester) async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(jsonEncode(_authResult()), 200);
    });
    addTearDown(client.close);
    await showLogin(tester, client, (_) async {
      fail('An empty login name must not authenticate.');
    });
    await tester.enterText(find.byKey(const Key('login-email')), '   ');
    await submit(tester);
    expect(
        find.text('Escribe tu usuario o correo electrónico.'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets(
      'device awaiting authorization keeps login and explains the reason',
      (tester) async {
    var entered = false;
    final client = MockClient((request) async => http.Response(
        jsonEncode({
          'error': {'code': 'DEVICE_PENDING_AUTHORIZATION', 'retryable': false}
        }),
        403));
    addTearDown(client.close);
    await showLogin(tester, client, (_) async {
      entered = true;
    });
    await submit(tester);
    expect(entered, false);
    expect(find.textContaining('pendiente de autorización'), findsOneWidget);
  });

  testWidgets(
      'two-factor challenge must complete before authenticated callback',
      (tester) async {
    var entered = false;
    var count = 0;
    final client = MockClient((request) async {
      count++;
      if (request.url.path.endsWith('two-factor')) {
        expect(jsonDecode(request.body)['code'], '001234');
        return http.Response(jsonEncode(_authResult()), 200);
      }
      return http.Response(
          jsonEncode({
            'status': 'two_factor_required',
            'challenge_token': 'challenge-test-token-123456'
          }),
          202);
    });
    addTearDown(client.close);
    await showLogin(tester, client, (_) async {
      entered = true;
    });
    await submit(tester);
    expect(entered, false);
    await tester.enterText(find.byKey(const Key('login-factor')), '001234');
    await tester.ensureVisible(find.byKey(const Key('login-submit')));
    await submit(tester);
    expect(entered, true);
    expect(count, 2);
  });
}
