import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class MobileApiException implements Exception {
  final int status;
  final String code;
  final bool retryable;
  final int? retryAfterSeconds;
  const MobileApiException(this.status, this.code,
      {this.retryable = false, this.retryAfterSeconds});
  @override
  String toString() =>
      'API móvil: ' + code + ' (HTTP ' + status.toString() + ')';
}

/// The caller supplies the current bearer from secure storage. It is never
/// persisted in SQLite, included in URLs, or written to logs by this client.
class MobileApiClient {
  final Uri baseUri;
  final Future<String?> Function() tokenProvider;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  MobileApiClient(
      {required Uri baseUri,
      required this.tokenProvider,
      http.Client? client,
      this.timeout = const Duration(seconds: 30),
      bool allowLocalHttp = false})
      : baseUri = baseUri.replace(
            path:
                baseUri.path.endsWith('/') ? baseUri.path : baseUri.path + '/'),
        _client = client ?? http.Client(),
        _ownsClient = client == null {
    if (!baseUri.hasAuthority ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        (baseUri.scheme != 'https' &&
            !(allowLocalHttp && baseUri.scheme == 'http'))) {
      throw ArgumentError(
          'Usa una URL HTTPS; HTTP requiere allowLocalHttp para desarrollo.');
    }
  }

  Future<http.Response> _request(String method, String path,
      {Map<String, String>? query,
      JsonMap? body,
      int maxBytes = 1048576}) async {
    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      throw const MobileApiException(401, 'AUTH_REQUIRED');
    }
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(
          {'Accept': 'application/json', 'Authorization': 'Bearer ' + token});
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
      if (request.bodyBytes.length > 1048576) {
        throw const DataContractException('El lote excede 1 MiB.');
      }
    }
    final response = await (() async {
      final stream = await _client.send(request);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream.stream) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw const DataContractException(
              'La respuesta excede el límite de tamaño.');
        }
      }
      return http.Response.bytes(bytes.takeBytes(), stream.statusCode,
          headers: stream.headers, request: request);
    })()
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      JsonMap error = {};
      try {
        final decoded = jsonObject(jsonDecode(utf8.decode(response.bodyBytes)));
        if (decoded['error'] is Map<String, dynamic>)
          error = jsonObject(decoded['error']);
      } on Object {
        // HTML errors and redirects are not accepted as successful API replies.
      }
      throw MobileApiException(response.statusCode,
          error['code'] is String ? error['code'] as String : 'HTTP_ERROR',
          retryable: error['retryable'] == true ||
              response.statusCode == 429 ||
              response.statusCode >= 500,
          retryAfterSeconds:
              int.tryParse(response.headers['retry-after'] ?? ''));
    }
    return response;
  }

  Future<JsonMap> _json(String method, String path,
      {Map<String, String>? query, JsonMap? body}) async {
    final response = await _request(method, path, query: query, body: body);
    try {
      return jsonObject(jsonDecode(utf8.decode(response.bodyBytes)));
    } on FormatException {
      throw const DataContractException('La API no devolvió un objeto JSON válido.');
    }
  }

  Future<MobileSession> getSession() async =>
      MobileSession.fromJson(await _json('GET', 'session'));

  /// Bind a multi-request operation to one credential. Replacing the signed-in
  /// account while a batch is in flight must not upload another user's queue.
  Future<MobileApiClient> credentialSnapshot() async {
    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      throw const MobileApiException(401, 'AUTH_REQUIRED');
    }
    return MobileApiClient(baseUri: baseUri, tokenProvider: () async => token,
      client: _client, timeout: timeout, allowLocalHttp: baseUri.scheme == 'http');
  }

  Future<List<JsonMap>> _listing(
      String path, Map<String, String> filters) async {
    final result = <JsonMap>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await _json('GET', path,
          query: {...filters, if (cursor != null) 'cursor': cursor});
      if (page['data'] is! List)
        throw const DataContractException('Listado inválido.');
      result.addAll((page['data'] as List).map(jsonObject));
      cursor = page['next_cursor'] as String?;
      if (result.length > 10000 || (cursor != null && !seen.add(cursor))) {
        throw const DataContractException(
            'Paginación inválida o demasiado extensa.');
      }
    } while (cursor != null);
    return result;
  }

  Future<List<JsonMap>> periods() => _listing('periods', {'estado': 'abierto'});

  Future<List<JsonMap>> departments(String periodId) =>
      _listing('departments', {'periodo_id': textId(periodId)});

  Future<List<JsonMap>> locations(String periodId, String departmentNumber) =>
      _listing(
          'departments/' +
              Uri.encodeComponent(textId(departmentNumber, signed: true)) +
              '/locations',
          {'periodo_id': textId(periodId)});

  Future<PackageManifest> createPackage(
          {required String packageId,
          required String periodId,
          required String departmentNumber,
          required String locationId,
          required bool includeReassignmentCatalogs}) async =>
      PackageManifest.fromJson(await _json('POST', 'packages', body: {
        'package_id': uuidText(packageId),
        'periodo_id': textId(periodId),
        'numero_departamento': textId(departmentNumber, signed: true),
        'ubicacion_id': textId(locationId),
        'include_reassignment_catalogs': includeReassignmentCatalogs,
      }));

  Future<PackageManifest> manifest(String packageId) async =>
      PackageManifest.fromJson(
          await _json('GET', 'packages/' + uuidText(packageId)));

  Future<Uint8List> packagePage(String packageId, int page) async =>
      (await _request('GET',
              'packages/' + uuidText(packageId) + '/pages/' + page.toString()))
          .bodyBytes;

  Future<JsonMap> sync(String batchId, List<JsonMap> operations) =>
      _json('POST', 'sync',
          body: {'batch_id': uuidText(batchId), 'operations': operations});

  Future<JsonMap> syncResults(List<String> operationIds) =>
      _json('POST', 'sync/results',
          body: {'operation_ids': operationIds.map(uuidText).toList()});

  void close() {
    if (_ownsClient) _client.close();
  }
}
