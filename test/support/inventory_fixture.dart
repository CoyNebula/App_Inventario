import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:inventario_app/data/models.dart';

final fixtureNow = DateTime.utc(2026, 11, 12, 12);
const fixturePackageId = '550e8400-e29b-41d4-a716-446655440001';
const fixtureDeviceId = '550e8400-e29b-41d4-a716-446655440000';

MobileSession fixtureSession(
        {String userId = '7', String deviceId = fixtureDeviceId}) =>
    MobileSession(
        userId: userId,
        userName: 'Revisor de prueba',
        deviceId: deviceId,
        permissions: {'hacer_levantamiento', 'asignar'},
        commands: SyncCommand.values.map((e) => e.wireName).toSet(),
        offlineUntil: fixtureNow.add(const Duration(days: 1)));

JsonMap fixtureItem(
        {int id = 1,
        String? number,
        bool reviewed = false,
        String? reviewer = '7'}) =>
    {
      'snapshot_id': (100 + id).toString(),
      'detalle_id': id.toString(),
      'bien': {
        'clave_activo_fijo': '5150-' + id.toString().padLeft(6, '0'),
        'numero_inventario_consecutivo': number ?? id.toString().padLeft(5, '0')
      },
      'numero_departamento_inicial': '20',
      'ubicacion_id_inicial': '30',
      'actual': {
        'descripcion': 'Activo de prueba',
        'numero_departamento': '20',
        'ubicacion_id': '30',
        'resguardante': {'clave_empleado': '150', 'nombre_completo': 'Anterior'}
      },
      'actual_restringido': false,
      'revisado': reviewed,
      'revisado_por_id': reviewed ? reviewer : null,
      'revisado_por_nombre': reviewed ? 'Revisor de prueba' : null,
      'fecha_revisado': reviewed ? '2026-11-11' : null,
      'observaciones': null,
      'editable': !reviewed || reviewer == '7',
      'version': {
        'detalle': '4',
        'inventario': '9',
        'resguardo_id': (820 + id).toString(),
        'resguardo': '3'
      },
    };

class FixturePackage {
  final PackageManifest manifest;
  final Map<int, List<int>> pages;
  FixturePackage(this.manifest, this.pages);
}

FixturePackage fixturePackage(
    {List<JsonMap>? items,
    String packageId = fixturePackageId,
    String userId = '7',
    String deviceId = fixtureDeviceId}) {
  final collections = <String, List<JsonMap>>{
    'items': items ?? [fixtureItem()],
    'departamentos': [
      {'numero_departamento': '20', 'descripcion': 'Departamento prueba'}
    ],
    'ubicaciones': [
      {'id': '30', 'numero_departamento': '20', 'descripcion': 'Origen'},
      {'id': '31', 'numero_departamento': '20', 'descripcion': 'Destino'}
    ],
    'empleados': [
      {
        'clave_empleado': '151',
        'numero_departamento': '20',
        'nombre_completo': 'Nuevo'
      }
    ],
  };
  final flat = <MapEntry<String, JsonMap>>[
    for (final collection in collections.entries)
      for (final row in collection.value) MapEntry(collection.key, row),
  ];
  final pages = <int, List<int>>{};
  final descriptors = <JsonMap>[];
  for (var offset = 0; offset < flat.length; offset += 250) {
    final number = pages.length + 1;
    final json = <String, dynamic>{
      'schema_version': '1',
      'package_id': packageId,
      'page': number,
      for (final key in packageCollections) key: <JsonMap>[]
    };
    for (final entry in flat.skip(offset).take(250)) {
      (json[entry.key] as List<JsonMap>).add(entry.value);
    }
    final bytes = utf8.encode(jsonEncode(json));
    pages[number] = bytes;
    descriptors.add({
      'page': number,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'counts': {
        for (final key in packageCollections) key: (json[key] as List).length
      }
    });
  }
  final manifest = PackageManifest.fromJson({
    'schema_version': '1',
    'package_id': packageId,
    'user_id': userId,
    'device_id': deviceId,
    'periodo_id': '12',
    'snapshot_completado_at': '2026-11-01T12:00:00Z',
    'numero_departamento_inicial': '20',
    'ubicacion_id_inicial': '30',
    'include_reassignment_catalogs': true,
    'generated_at': fixtureNow.toIso8601String(),
    'download_expires_at':
        fixtureNow.add(const Duration(days: 1)).toIso8601String(),
    'offline_authorized_until':
        fixtureNow.add(const Duration(days: 1)).toIso8601String(),
    'counts': {
      for (final key in packageCollections) key: collections[key]!.length
    },
    'total_bytes': pages.values.fold<int>(0, (n, b) => n + b.length),
    'pages': descriptors,
    'avance': {
      'total': collections['items']!.length,
      'revisados': 0,
      'pendientes': collections['items']!.length,
      'porcentaje': 0,
      'etiqueta': 'Avance',
      'heredado': false
    },
  });
  return FixturePackage(manifest, pages);
}

JsonMap fixturePeriod() => {
      'id': '12',
      'anio': 2026,
      'mes': 11,
      'nombre': 'Periodo prueba',
      'estado': 'abierto',
      'mobile_eligible': true
    };
