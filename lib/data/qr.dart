import 'dart:convert';

import 'models.dart';

enum QrLookupStatus { found, notAvailable, ambiguous }

class QrLookupResult {
  final QrLookupStatus status;
  final InventoryItem? item;
  const QrLookupResult(this.status, [this.item]);
  String get message => switch (status) {
        QrLookupStatus.found => 'Bien disponible',
        QrLookupStatus.notAvailable => 'No disponible en esta descarga',
        QrLookupStatus.ambiguous =>
          'Consecutivo ambiguo; usa un QR con ambos identificadores',
      };
}

/// Only whitespace outside the serialized QR is removed. Identity values inside
/// JSON stay literal; numeric JSON values are rejected to preserve leading zeros.
JsonMap parseInventoryQr(String raw) {
  final text = raw.trim();
  Object? decoded;
  if (RegExp(r'^(?:E?[0-9]+|E?[0-9]+-[0-9]+)$').hasMatch(text)) {
    decoded = text;
  } else {
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      try {
        decoded = jsonDecode(_decodeHtml(text));
      } on FormatException {
        decoded = text;
      }
    }
  }
  if (decoded is String && decoded.isNotEmpty) {
    if (!RegExp(r'^(?:E?[0-9]+|E?[0-9]+-[0-9]+)$').hasMatch(decoded)) {
      throw const DataContractException('QR no reconocido.');
    }
    return {
      decoded.contains('-')
          ? 'clave_activo_fijo'
          : 'numero_inventario_consecutivo': decoded
    };
  }
  if (decoded is! Map<String, dynamic>) {
    throw const DataContractException('QR no reconocido.');
  }
  final result = <String, dynamic>{};
  for (final key in ['clave_activo_fijo', 'numero_inventario_consecutivo']) {
    if (decoded.containsKey(key)) {
      final value = decoded[key];
      if (value is! String || value.isEmpty || value.runes.length > 255) {
        throw const DataContractException(
            'Identificador QR inválido; se requiere texto literal.');
      }
      result[key] = value;
    }
  }
  if (result.isEmpty)
    throw const DataContractException('El QR no contiene identificadores.');
  return result;
}

String _decodeHtml(String value) => value.replaceAllMapped(
        RegExp(r'&(?:quot|apos|amp|lt|gt|#[0-9]+|#x[0-9a-fA-F]+);'), (match) {
      final entity = match.group(0)!;
      const named = {
        '&quot;': '"',
        '&apos;': "'",
        '&amp;': '&',
        '&lt;': '<',
        '&gt;': '>'
      };
      if (named.containsKey(entity)) return named[entity]!;
      final hex = entity.startsWith('&#x');
      final number = int.tryParse(
          entity.substring(hex ? 3 : 2, entity.length - 1),
          radix: hex ? 16 : 10);
      return number == null ||
              number > 0x10ffff ||
              (number >= 0xd800 && number <= 0xdfff)
          ? entity
          : String.fromCharCode(number);
    });
