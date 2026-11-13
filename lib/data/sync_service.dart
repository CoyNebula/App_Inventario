
/* envia la cola pendiente a laravel por lotes y confirma la operacion */
import 'dart:convert';

import 'api_client.dart';
import 'database.dart';
import 'models.dart';

/// Uploads durable, immutable operations and only consumes individual receipts.
class InventorySyncService {
  InventorySyncService({
    required InventoryDatabase database,
    required MobileApiClient api,
    required MobileSession session,
    DateTime Function()? clock,
  })  : _database = database,
        _api = api,
        _session = session,
        _clock = clock ?? DateTime.now;

  final InventoryDatabase _database;
  final MobileApiClient _api;
  final MobileSession _session;
  final DateTime Function() _clock;
  Future<SyncReport>? _running;

  Future<SyncReport> synchronize({
    Future<String?> Function(String packageId)? refreshPackage,
  }) =>
      _running ??= _synchronize(refreshPackage).whenComplete(() {
        _running = null;
      });

  Future<SyncReport> _synchronize(
    Future<String?> Function(String packageId)? refreshPackage,
  ) async {
    final report = SyncReport();
    try {
      // All operations in this run use the bearer whose identity was checked.
      // A later account switch must not assign old UUIDs to the new account.
      final api = await _api.credentialSnapshot();
      final remote = await api.getSession();
      if (remote.userId != _session.userId ||
          remote.deviceId != _session.deviceId) {
        throw const DataContractException(
          'La sesión del servidor pertenece a otra cuenta o dispositivo.',
        );
      }
      final rows = await _pending();
      final due = <_QueuedOperation>[];
      for (final row in rows) {
        try {
          final next = row['next_attempt_at'];
          if (next != null &&
              DateTime.parse(next as String).isAfter(_clock().toUtc())) {
            continue;
          }
          due.add(_QueuedOperation.fromRow(row, _session));
        } on Object catch (error) {
          report.errors.add('Operación local pendiente: $error');
          await _recordError([row['operation_uuid'] as String], '$error');
        }
      }

      // A snapshot of the queue makes every operation eligible at most once in
      // this run. Retryable outcomes are scheduled for a future invocation.
      while (due.isNotEmpty) {
        final batch = _takeBatch(due, report);
        if (batch.isEmpty) continue;
        try {
          final submitted = batch.where((op) => op.submitted).toList();
          final resend = batch.where((op) => !op.submitted).toList();
          if (submitted.isNotEmpty) {
            final recovered = await api.syncResults(
              submitted.map((op) => op.id).toList(),
            );
            final recovery = _recovery(recovered, submitted);
            await _apply(recovery.receipts, report);
            resend.addAll(
                submitted.where((op) => recovery.unknown.contains(op.id)));
            await _missing(recovery.missing, report);
          }
          if (resend.isEmpty) continue;
          final batchId = uuidText(newOperationUuid());
          // Persist intent before the request. A lost reply must be recovered
          // through results before considering another upload.
          await _markSubmitted(resend);
          final response = await api.sync(
            batchId,
            resend.map((op) => op.json).toList(),
          );
          final outcomes = _response(response, batchId, resend);
          await _apply(outcomes.receipts, report);
          await _missing(outcomes.missing, report);
        } on Object catch (error) {
          report.errors.add('No se completó la sincronización: $error');
          await _recordError(
            batch.map((op) => op.id).toList(),
            '$error',
            retrySeconds:
                error is MobileApiException ? error.retryAfterSeconds : null,
          );
          // Avoid repeating network/authentication failures for every batch.
          break;
        }
      }
      if (refreshPackage != null) {
        await _refresh(refreshPackage, report);
      }
    } on Object catch (error) {
      report.errors.add('No se pudo iniciar la sincronización: $error');
    } finally {
      try {
        report.pending = (await _pending()).length;
      } on Object catch (error) {
        report.errors.add('No se pudo consultar la cola local: $error');
      }
    }
    return report;
  }

  Future<List<Map<String, Object?>>> _pending() async {
    final db = await _database.database;
    return db.rawQuery('''
      SELECT q.* FROM sync_queue q
      JOIN packages p ON p.package_id = q.package_id
      WHERE q.status = 'pending' AND p.user_id = ? AND p.device_id = ?
      ORDER BY q.created_at, q.operation_uuid
    ''', [_session.userId, _session.deviceId]);
  }

  List<_QueuedOperation> _takeBatch(
    List<_QueuedOperation> remaining,
    SyncReport report,
  ) {
    final selected = <_QueuedOperation>[];
    final details = <String>{};
    var index = 0;
    // UUIDs have a fixed byte length; the actual new batch ID is generated
    // later without changing the size of this envelope.
    while (index < remaining.length && selected.length < 100) {
      final op = remaining[index];
      if (details.contains(op.detailId)) {
        index++;
        continue;
      }
      final size = utf8
          .encode(jsonEncode({
            'batch_id': '00000000-0000-4000-8000-000000000000',
            'operations': [...selected.map((value) => value.json), op.json],
          }))
          .length;
      if (size > 1048576) {
        if (selected.isEmpty) {
          // Keep the original record. It needs explicit correction rather than
          // silently dropping data or sending an oversized request.
          report.errors
              .add('La operación ${op.id} excede 1 MiB y sigue pendiente.');
          remaining.removeAt(index);
          continue;
        }
        break;
      }
      selected.add(op);
      details.add(op.detailId);
      remaining.removeAt(index);
    }
    return selected;
  }

  Future<void> _markSubmitted(List<_QueuedOperation> operations) async {
    final db = await _database.database;
    final now = _clock().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final op in operations) {
        await txn.rawUpdate('''
          UPDATE sync_queue SET attempts = attempts + 1,
            submitted_at = COALESCE(submitted_at, ?),
            next_attempt_at = NULL, last_error = NULL
          WHERE operation_uuid = ? AND status = 'pending'
        ''', [now, op.id]);
      }
    });
  }

  _Outcomes _response(
    JsonMap response,
    String batchId,
    List<_QueuedOperation> operations,
  ) {
    if (uuidText(response['batch_id']) != batchId ||
        response['results'] is! List) {
      throw const DataContractException('Respuesta de lote inválida.');
    }
    final allowed = operations.map((op) => op.id).toSet();
    final receipts = _receipts(response['results'] as List, allowed);
    return _Outcomes(receipts, allowed.difference(receipts.keys.toSet()));
  }

  _Recovery _recovery(JsonMap response, List<_QueuedOperation> operations) {
    if (response['receipts'] is! List ||
        response['unknown_operation_ids'] is! List) {
      throw const DataContractException('Consulta de acuses inválida.');
    }
    final allowed = operations.map((op) => op.id).toSet();
    final receipts = _receipts(
      response['receipts'] as List,
      allowed,
      terminalOnly: true,
    );
    final unknown = <String>{};
    for (final value in response['unknown_operation_ids'] as List) {
      final id = uuidText(value);
      if (!allowed.contains(id) ||
          receipts.containsKey(id) ||
          !unknown.add(id)) {
        throw const DataContractException(
            'Identidad de recuperación inválida.');
      }
    }
    return _Recovery(
      receipts,
      unknown,
      allowed.difference({...receipts.keys, ...unknown}),
    );
  }

  Map<String, JsonMap> _receipts(
    List<dynamic> values,
    Set<String> allowed, {
    bool terminalOnly = false,
  }) {
    final receipts = <String, JsonMap>{};
    for (final value in values) {
      final receipt = jsonObject(value);
      final id = uuidText(receipt['operation_id']);
      if (!allowed.contains(id) || receipts.containsKey(id)) {
        throw const DataContractException(
            'Acuse ajeno o duplicado en la respuesta.');
      }
      _validateReceipt(receipt, terminalOnly: terminalOnly);
      receipts[id] = receipt;
    }
    return receipts;
  }

  void _validateReceipt(JsonMap receipt, {required bool terminalOnly}) {
    final state = receipt['estado'];
    final code = receipt['code'];
    if (code is! String || code.isEmpty) {
      throw const DataContractException('Código de acuse inválido.');
    }
    if (!terminalOnly && state == 'reintentar') {
      final seconds = receipt['retry_after_seconds'];
      if (receipt['retryable'] != true ||
          seconds is! int ||
          seconds < 1 ||
          !['SERVER_BUSY', 'SERVER_NOT_READY', 'INTERNAL_ERROR', 'RATE_LIMITED']
              .contains(code)) {
        throw const DataContractException('Demora de reintento inválida.');
      }
      return;
    }
    if (!terminalOnly &&
        state == 'rechazada' &&
        code == 'IDEMPOTENCY_KEY_REUSED') {
      if (receipt['retryable'] != false) {
        throw const DataContractException('Colisión de UUID inválida.');
      }
      return;
    }
    if (!['aplicada', 'conflicto', 'rechazada'].contains(state) ||
        receipt['replayed'] is! bool ||
        !receipt.containsKey('incidencia_id')) {
      throw const DataContractException('Estado terminal de acuse inválido.');
    }
    nullableId(receipt['incidencia_id']);
    final received = _instant(receipt['received_at']);
    final committed = _instant(receipt['committed_at']);
    if (committed.isBefore(received)) {
      throw const DataContractException('Fechas de acuse inconsistentes.');
    }
    if (state == 'aplicada') {
      if (code != 'APPLIED') {
        throw const DataContractException(
            'Una operación aplicada requiere APPLIED.');
      }
      _version(receipt['resulting_version']);
    } else if (!receipt.containsKey('resulting_version') ||
        receipt['resulting_version'] != null ||
        code == 'APPLIED') {
      throw const DataContractException('Versión terminal inconsistente.');
    } else if (state == 'conflicto' &&
        !['VERSION_CONFLICT', 'REVIEW_OWNED_BY_OTHER', 'ALREADY_REVIEWED']
            .contains(code)) {
      throw const DataContractException('Conflicto terminal no reconocido.');
    } else if (state == 'rechazada' &&
        ![
          'PERMISSION_DENIED',
          'SCOPE_FORBIDDEN',
          'PERIOD_CLOSED',
          'SNAPSHOT_REQUIRED',
          'PACKAGE_MISMATCH',
          'DETAIL_NOT_IN_PERIOD',
          'IDENTITY_MISMATCH',
          'QR_AMBIGUOUS',
          'PATRIMONIAL_INTEGRITY_ERROR',
          'FIRST_ASSIGNMENT_FORBIDDEN',
          'SAME_CUSTODIAN',
          'INVALID_DESTINATION',
          'REVIEW_REQUIRED',
          'VALIDATION_FAILED'
        ].contains(code)) {
      throw const DataContractException('Rechazo terminal no reconocido.');
    }
  }

  DateTime _instant(Object? value) {
    if (value is! String || value.length > 80) {
      throw const DataContractException('Fecha de acuse inválida.');
    }
    final match = RegExp(
      r'^([1-9][0-9]{3})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?([Zz]|([+-])([0-9]{2}):([0-9]{2}))$',
    ).firstMatch(value);
    if (match == null || match.end != value.length) {
      throw const DataContractException('Fecha de acuse inválida.');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final hour = int.parse(match[4]!);
    final minute = int.parse(match[5]!);
    final second = int.parse(match[6]!);
    final microseconds = int.parse((match[7] ?? '').padRight(6, '0').substring(0, 6));
    final offsetHours = int.parse(match[10] ?? '0');
    final offsetMinutes = int.parse(match[11] ?? '0');
    if (month < 1 || month > 12 || day < 1 || day > 31 ||
        hour > 23 || minute > 59 || second > 59 ||
        offsetHours > 23 || offsetMinutes > 59) {
      throw const DataContractException('Fecha de acuse fuera de rango.');
    }
    final local = DateTime.utc(year, month, day, hour, minute, second,
      microseconds ~/ 1000, microseconds % 1000);
    // DateTime normalizes impossible calendar dates. Compare components before
    // applying the explicit offset rather than trusting parse().
    if (local.year != year || local.month != month || local.day != day) {
      throw const DataContractException('Día de acuse inexistente en el calendario.');
    }
    final offset = Duration(hours: offsetHours, minutes: offsetMinutes);
    final utc = match[9] == '+' ? local.subtract(offset) : local.add(offset);
    if (utc.year < 1000 || utc.year > 9999) {
      throw const DataContractException('Fecha UTC de acuse fuera de rango.');
    }
    return utc;
  }

  JsonMap _version(Object? value) {
    final version = jsonObject(value);
    if (version.length != 4) {
      throw const DataContractException('Versión de acuse incompleta.');
    }
    textId(version['detalle']);
    textId(version['inventario']);
    if (!version.containsKey('resguardo_id') ||
        !version.containsKey('resguardo')) {
      throw const DataContractException('Versión de resguardo ausente.');
    }
    nullableId(version['resguardo_id'], signed: true);
    nullableId(version['resguardo']);
    if ((version['resguardo_id'] == null) != (version['resguardo'] == null)) {
      throw const DataContractException('Versión de resguardo inconsistente.');
    }
    return version;
  }

  Future<void> _apply(Map<String, JsonMap> receipts, SyncReport report) async {
    final db = await _database.database;
    var applied = 0;
    var conflicts = 0;
    var rejected = 0;
    await db.transaction((txn) async {
      for (final entry in receipts.entries) {
        final rows = await txn.rawQuery('''
          SELECT q.* FROM sync_queue q JOIN packages p ON p.package_id = q.package_id
          WHERE q.operation_uuid = ? AND q.status = 'pending'
            AND p.user_id = ? AND p.device_id = ?
        ''', [entry.key, _session.userId, _session.deviceId]);
        if (rows.isEmpty) continue;
        final row = rows.single;
        final receipt = entry.value;
        if (receipt['estado'] == 'reintentar') {
          await txn.update(
              'sync_queue',
              {
                'last_error': receipt['code'],
                'next_attempt_at': _clock()
                    .toUtc()
                    .add(Duration(
                      seconds: receipt['retry_after_seconds'] as int,
                    ))
                    .toIso8601String(),
              },
              where: 'operation_uuid = ?',
              whereArgs: [entry.key]);
          continue;
        }
        final state = receipt['estado'];
        final status = state == 'aplicada'
            ? 'synced'
            : state == 'conflicto'
                ? 'conflict'
                : 'error';
        await txn.update(
            'sync_queue',
            {
              'status': status,
              'receipt_json': jsonEncode(receipt),
              'last_error': state == 'aplicada' ? null : receipt['code'],
              'next_attempt_at': null,
              'synced_at': state == 'aplicada'
                  ? _clock().toUtc().toIso8601String()
                  : null,
            },
            where: 'operation_uuid = ?',
            whereArgs: [entry.key]);
        final changes = <String, Object?>{'needs_refresh': 1};
        if (state == 'aplicada') {
          final items = await txn.query(
            'items',
            columns: ['current_json', 'original_json'],
            where: 'package_id = ? AND detalle_id = ?',
            whereArgs: [row['package_id'], row['detalle_id']],
          );
          final item = items.single;
          final current = jsonObject(jsonDecode(
            (item['current_json'] ?? item['original_json']) as String,
          ));
          current['version'] = receipt['resulting_version'];
          changes['current_json'] = jsonEncode(current);
          changes['version_json'] = jsonEncode(receipt['resulting_version']);
          applied++;
        } else if (state == 'conflicto') {
          conflicts++;
        } else {
          rejected++;
        }
        await txn.update(
          'items',
          changes,
          where: 'package_id = ? AND detalle_id = ?',
          whereArgs: [row['package_id'], row['detalle_id']],
        );
      }
    });
    report.applied += applied;
    report.conflicts += conflicts;
    report.rejected += rejected;
  }

  Future<void> _missing(Set<String> missing, SyncReport report) async {
    if (missing.isEmpty) return;
    const message =
        'La respuesta no incluyó un acuse; la operación sigue pendiente.';
    report.errors.add(message);
    await _recordError(missing.toList(), message);
  }

  Future<void> _recordError(
    List<String> ids,
    String message, {
    int? retrySeconds,
  }) async {
    final db = await _database.database;
    for (final id in ids) {
      await db.rawUpdate('''
        UPDATE sync_queue SET last_error = ?, next_attempt_at = ?
        WHERE operation_uuid = ? AND status = 'pending' AND package_id IN (
          SELECT package_id FROM packages WHERE user_id = ? AND device_id = ?
        )
      ''', [
        message,
        retrySeconds != null && retrySeconds > 0
            ? _clock()
                .toUtc()
                .add(Duration(seconds: retrySeconds))
                .toIso8601String()
            : null,
        id,
        _session.userId,
        _session.deviceId
      ]);
    }
  }

  Future<void> _refresh(
    Future<String?> Function(String packageId) refreshPackage,
    SyncReport report,
  ) async {
    final db = await _database.database;
    final packages = await db.rawQuery('''
      SELECT p.package_id FROM packages p
      WHERE p.user_id = ? AND p.device_id = ? AND p.status = 'ready' AND p.active = 1
        AND EXISTS (SELECT 1 FROM items i WHERE i.package_id = p.package_id AND i.needs_refresh = 1)
        AND NOT EXISTS (
          SELECT 1 FROM sync_queue q WHERE q.package_id = p.package_id
            AND (q.status = 'pending' OR (q.status IN ('conflict', 'error') AND q.resolved_at IS NULL))
        )
      ORDER BY p.created_at
    ''', [_session.userId, _session.deviceId]);
    for (final package in packages) {
      final id = package['package_id'] as String;
      try {
        final replacement = await refreshPackage(id);
        if (replacement != null)
          report.refreshedPackages[id] = uuidText(replacement);
      } on Object catch (error) {
        report.errors.add('No se pudo refrescar el paquete: $error');
      }
    }
  }
}

class _QueuedOperation {
  const _QueuedOperation(this.id, this.detailId, this.json, this.submitted);
  final String id;
  final String detailId;
  final JsonMap json;
  final bool submitted;

  factory _QueuedOperation.fromRow(
      Map<String, Object?> row, MobileSession session) {
    final id = uuidText(row['operation_uuid']);
    final operation = jsonObject(jsonDecode(row['operation_json'] as String));
    final detailId = textId(row['detalle_id']);
    if (uuidText(operation['operation_id']) != id ||
        operation['user_id'] != session.userId ||
        operation['device_id'] != session.deviceId ||
        uuidText(operation['package_id']) != row['package_id'] ||
        textId(operation['detalle_id']) != detailId ||
        operation['type'] != row['type']) {
      throw const DataContractException(
          'La identidad del sobre local no coincide con su propietario.');
    }
    return _QueuedOperation(
        id, detailId, operation, row['submitted_at'] != null);
  }
}

class _Outcomes {
  const _Outcomes(this.receipts, this.missing);
  final Map<String, JsonMap> receipts;
  final Set<String> missing;
}

class _Recovery {
  const _Recovery(this.receipts, this.unknown, this.missing);
  final Map<String, JsonMap> receipts;
  final Set<String> unknown;
  final Set<String> missing;
}
