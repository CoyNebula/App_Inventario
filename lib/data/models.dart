import 'dart:convert';
import 'dart:math';

typedef JsonMap = Map<String, dynamic>;

class DataContractException implements Exception {
  final String message;
  const DataContractException(this.message);
  @override
  String toString() => message;
}

JsonMap jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const DataContractException('Se esperaba un objeto JSON.');
  }
  return value;
}

String textId(Object? value, {bool signed = false}) {
  final pattern = signed ? r'^-?(0|[1-9][0-9]*)$' : r'^[1-9][0-9]*$';
  if (value is! String || !RegExp(pattern).hasMatch(value) || value == '-0') {
    throw const DataContractException(
        'El identificador debe ser texto decimal.');
  }
  final parsed = BigInt.parse(value);
  if (signed
      ? parsed < BigInt.from(-2147483648) || parsed > BigInt.from(2147483647)
      : parsed > BigInt.parse('9223372036854775807')) {
    throw const DataContractException('Identificador fuera de rango.');
  }
  return value;
}

String? nullableId(Object? value, {bool signed = false}) =>
    value == null ? null : textId(value, signed: signed);

String uuidText(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(value)) {
    throw const DataContractException('Se esperaba un UUID v4.');
  }
  return value;
}

String newOperationUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20)
  ].join('-');
}

JsonMap copyJson(JsonMap value) => jsonObject(jsonDecode(jsonEncode(value)));

enum SyncCommand {
  confirmReview('confirmar_revision'),
  updateObservations('actualizar_observaciones'),
  proposeReassignment('proponer_reasignacion');

  final String wireName;
  const SyncCommand(this.wireName);
}

class MobileSession {
  final String userId;
  final String userName;
  final String deviceId;
  final Set<String> permissions;
  final Set<String> commands;
  final DateTime? offlineUntil;

  MobileSession(
      {required this.userId,
      required this.deviceId,
      required this.userName,
      required this.permissions,
      required this.commands,
      this.offlineUntil}) {
    textId(userId);
    uuidText(deviceId);
  }

  factory MobileSession.fromJson(JsonMap json) => MobileSession(
        userId: textId(jsonObject(json['user'])['id']),
        userName: jsonObject(json['user'])['name'] as String,
        deviceId: uuidText(jsonObject(json['device'])['id']),
        permissions: (json['permissions'] as List).cast<String>().toSet(),
        commands: (json['supported_commands'] as List).cast<String>().toSet(),
        offlineUntil: json['offline_authorized_until'] == null
            ? null
            : DateTime.parse(json['offline_authorized_until'] as String)
                .toUtc(),
      );
}

class AssetIdentity {
  final String key;
  final String number;
  const AssetIdentity(this.key, this.number);

  factory AssetIdentity.fromJson(JsonMap json) {
    final key = json['clave_activo_fijo'];
    final number = json['numero_inventario_consecutivo'];
    if (key is! String ||
        number is! String ||
        key.isEmpty ||
        number.isEmpty ||
        key.runes.length > 255 ||
        number.runes.length > 255) {
      throw const DataContractException('Identidad patrimonial inválida.');
    }
    return AssetIdentity(key, number);
  }

  JsonMap toJson() =>
      {'clave_activo_fijo': key, 'numero_inventario_consecutivo': number};
}

class PackagePageDescriptor {
  final int page;
  final int bytes;
  final String sha256;
  final Map<String, int> counts;
  PackagePageDescriptor.fromJson(JsonMap json)
      : page = json['page'] as int,
        bytes = json['bytes'] as int,
        sha256 = json['sha256'] as String,
        counts = Map<String, int>.from(jsonObject(json['counts'])) {
    if (page < 1 ||
        bytes < 1 ||
        bytes > 1048576 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const DataContractException('Descriptor de página inválido.');
    }
    validateCounts(counts);
    if (counts.values.fold<int>(0, (a, b) => a + b) > 250) {
      throw const DataContractException('La página excede 250 registros.');
    }
  }
}

const packageCollections = [
  'items',
  'departamentos',
  'ubicaciones',
  'empleados'
];

void validateCounts(Map<String, int> counts) {
  if (counts.length != 4 ||
      packageCollections.any((key) =>
          !counts.containsKey(key) ||
          counts[key]! < 0 ||
          counts[key]! > 10000)) {
    throw const DataContractException('Conteos del paquete inválidos.');
  }
}

class PackageManifest {
  final JsonMap _json;
  late final List<PackagePageDescriptor> pages;
  late final Map<String, int> counts;
  PackageManifest.fromJson(JsonMap json) : _json = copyJson(json) {
    if (json['schema_version'] != '1') {
      throw const DataContractException('Versión de paquete no compatible.');
    }
    uuidText(json['package_id']);
    uuidText(json['device_id']);
    textId(json['user_id']);
    textId(json['periodo_id']);
    textId(json['numero_departamento_inicial'], signed: true);
    nullableId(json['ubicacion_id_inicial']);
    DateTime.parse(json['offline_authorized_until'] as String);
    DateTime.parse(json['download_expires_at'] as String);
    counts = Map<String, int>.from(jsonObject(json['counts']));
    validateCounts(counts);
    pages = (json['pages'] as List)
        .map((e) => PackagePageDescriptor.fromJson(jsonObject(e)))
        .toList(growable: false);
    if (pages.isEmpty ||
        pages.length > 20000 ||
        totalBytes < 1 ||
        totalBytes > 20971520) {
      throw const DataContractException('Tamaño de paquete inválido.');
    }
    var bytes = 0;
    final totals = {for (final key in packageCollections) key: 0};
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].page != i + 1) {
        throw const DataContractException('Páginas no contiguas.');
      }
      bytes += pages[i].bytes;
      for (final key in packageCollections) {
        totals[key] = totals[key]! + pages[i].counts[key]!;
      }
    }
    if (bytes != totalBytes ||
        packageCollections.any((k) => totals[k] != counts[k])) {
      throw const DataContractException('Manifiesto inconsistente.');
    }
  }

  String get packageId => _json['package_id'] as String;
  String get userId => _json['user_id'] as String;
  String get deviceId => _json['device_id'] as String;
  String get periodId => _json['periodo_id'] as String;
  String get departmentNumber => _json['numero_departamento_inicial'] as String;
  String? get locationId => _json['ubicacion_id_inicial'] as String?;
  int get totalBytes => _json['total_bytes'] as int;
  DateTime get offlineUntil =>
      DateTime.parse(_json['offline_authorized_until'] as String).toUtc();
  DateTime get downloadExpiresAt =>
      DateTime.parse(_json['download_expires_at'] as String).toUtc();
  JsonMap toJson() => copyJson(_json);
}

class InventoryItem {
  final JsonMap _json;
  InventoryItem.fromJson(JsonMap json) : _json = copyJson(json) {
    textId(json['detalle_id']);
    textId(json['snapshot_id']);
    AssetIdentity.fromJson(jsonObject(json['bien']));
    nullableId(json['numero_departamento_inicial'], signed: true);
    nullableId(json['ubicacion_id_inicial']);
    nullableId(json['revisado_por_id']);
    if (json['revisado'] is! bool ||
        json['editable'] is! bool ||
        json['actual_restringido'] is! bool) {
      throw const DataContractException('Estado de revisión inválido.');
    }
    final version = jsonObject(json['version']);
    textId(version['detalle']);
    textId(version['inventario']);
    nullableId(version['resguardo_id'], signed: true);
    nullableId(version['resguardo']);
    if ((version['resguardo_id'] == null) != (version['resguardo'] == null)) {
      throw const DataContractException('Versión de resguardo incompleta.');
    }
    if (current != null) {
      textId(current!['numero_departamento'], signed: true);
      nullableId(current!['ubicacion_id']);
      if (current!['resguardante'] != null) {
        textId(jsonObject(current!['resguardante'])['clave_empleado'],
            signed: true);
      }
    }
    if (json['observaciones'] != null && json['observaciones'] is! String ||
        (json['observaciones'] is String &&
            (json['observaciones'] as String).runes.length > 5000)) {
      throw const DataContractException('Observaciones inválidas.');
    }
  }

  String get detailId => _json['detalle_id'] as String;
  String get snapshotId => _json['snapshot_id'] as String;
  AssetIdentity get identity =>
      AssetIdentity.fromJson(jsonObject(_json['bien']));
  bool get reviewed => _json['revisado'] as bool;
  bool get editable => _json['editable'] as bool;
  bool get restricted => _json['actual_restringido'] as bool;
  String? get reviewedById => _json['revisado_por_id'] as String?;
  String? get reviewerName => _json['revisado_por_nombre'] as String?;
  String? get observations => _json['observaciones'] as String?;
  JsonMap get version => copyJson(jsonObject(_json['version']));
  JsonMap? get current =>
      _json['actual'] == null ? null : copyJson(jsonObject(_json['actual']));
  JsonMap toJson() => copyJson(_json);
  JsonMap originalValues() => {
        'revisado': reviewed,
        'revisado_por_id': reviewedById,
        'observaciones': observations,
        'numero_departamento': current?['numero_departamento'],
        'ubicacion_id': current?['ubicacion_id'],
        'resguardante_id': current?['resguardante'] == null
            ? null
            : jsonObject(current!['resguardante'])['clave_empleado'],
      };

  Map<String, Object?> toDatabaseRow(String packageId,
      {InventoryItem? original, bool needsRefresh = false}) {
    final data = current;
    final custodian = data?['resguardante'] == null
        ? null
        : jsonObject(data!['resguardante']);
    return {
      'package_id': packageId,
      'detalle_id': detailId,
      'snapshot_id': snapshotId,
      'clave_activo_fijo': identity.key,
      'numero_inventario_consecutivo': identity.number,
      'numero_departamento_inicial': _json['numero_departamento_inicial'],
      'ubicacion_id_inicial': _json['ubicacion_id_inicial'],
      'numero_departamento_actual': data?['numero_departamento'],
      'ubicacion_id_actual': data?['ubicacion_id'],
      'revisado': reviewed ? 1 : 0,
      'revisado_por_id': reviewedById,
      'revisado_por_nombre': reviewerName,
      'observaciones': observations,
      'resguardante_id': custodian?['clave_empleado'],
      'resguardante_nombre': custodian?['nombre_completo'],
      'version_json': jsonEncode(version),
      'original_json': jsonEncode((original ?? this).toJson()),
      'current_json': jsonEncode(toJson()),
      'needs_refresh': needsRefresh ? 1 : 0,
    };
  }
}

class InventoryProgress {
  final int total;
  final int reviewed;
  int get pending => total - reviewed;
  double? get percentage => total == 0 ? null : reviewed * 100 / total;
  const InventoryProgress({required this.total, required this.reviewed});
}

class SyncReport {
  int applied = 0;
  int conflicts = 0;
  int rejected = 0;
  int pending = 0;
  final List<String> errors = [];
  final Map<String, String> refreshedPackages = {};
}

class InventoryPeriod {
  final String id;
  final String name;
  final int year;
  final int month;
  final String state;
  final bool mobileEligible;
  InventoryPeriod.fromJson(JsonMap json)
    : id = textId(json['id']), name = json['nombre'] as String,
      year = json['anio'] as int, month = json['mes'] as int,
      state = json['estado'] as String, mobileEligible = json['mobile_eligible'] == true;
}

class Department {
  final String number;
  final String? description;
  Department.fromJson(JsonMap json)
    : number = textId(json['numero_departamento'], signed: true),
      description = json['descripcion'] as String?;
}

class Location {
  final String id;
  final String? departmentNumber;
  final String? description;
  Location.fromJson(JsonMap json)
    : id = textId(json['id']),
      departmentNumber = nullableId(json['numero_departamento'], signed: true),
      description = json['descripcion'] as String?;
}

class Employee {
  final String id;
  final String departmentNumber;
  final String? name;
  Employee.fromJson(JsonMap json)
    : id = textId(json['clave_empleado'], signed: true),
      departmentNumber = textId(json['numero_departamento'], signed: true),
      name = json['nombre_completo'] as String?;
}

class QueuedOperation {
  final String uuid;
  final String packageId;
  final String detailId;
  final String type;
  final String status;
  final int attempts;
  final String? lastError;
  final JsonMap operation;
  final JsonMap? receipt;
  final DateTime? resolvedAt;
  QueuedOperation.fromRow(Map<String, Object?> row)
    : uuid = uuidText(row['operation_uuid']), packageId = uuidText(row['package_id']),
      detailId = textId(row['detalle_id']), type = row['type'] as String,
      status = row['status'] as String, attempts = row['attempts'] as int,
      lastError = row['last_error'] as String?,
      operation = jsonObject(jsonDecode(row['operation_json'] as String)),
      receipt = row['receipt_json'] == null ? null : jsonObject(jsonDecode(row['receipt_json'] as String)),
      resolvedAt = row['resolved_at'] == null ? null : DateTime.parse(row['resolved_at'] as String).toUtc();
}
