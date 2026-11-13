import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models.dart';

/// Only authentication metadata and bearer go in platform secure storage.
/// Passwords are never saved. Inventory and pending operations stay in SQLite.
class SavedInventorySession {
  final Uri baseUri;
  final String accessToken;
  final JsonMap sessionJson;
  MobileSession get session => MobileSession.fromJson(sessionJson);

  SavedInventorySession(
      {required this.baseUri,
      required this.accessToken,
      required JsonMap sessionJson})
      : sessionJson = copyJson(sessionJson) {
    if (!baseUri.hasAuthority ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        !['http', 'https'].contains(baseUri.scheme) ||
        accessToken.isEmpty) {
      throw const DataContractException('Datos de acceso inválidos.');
    }
    MobileSession.fromJson(this.sessionJson);
  }

  factory SavedInventorySession.fromLogin(Uri baseUri, JsonMap json) {
    if (json['status'] != 'authenticated' ||
        json['token_type'] != 'Bearer' ||
        json['access_token'] is! String) {
      throw const DataContractException('Laravel no confirmó el acceso.');
    }
    return SavedInventorySession(
        baseUri: baseUri,
        accessToken: json['access_token'] as String,
        sessionJson: jsonObject(json['session']));
  }

  factory SavedInventorySession.fromJson(JsonMap json) => SavedInventorySession(
      baseUri: Uri.parse(json['base_uri'] as String),
      accessToken: json['access_token'] as String,
      sessionJson: jsonObject(json['session']));

  JsonMap toJson() => {
        'base_uri': baseUri.toString(),
        'access_token': accessToken,
        'session': copyJson(sessionJson)
      };
}

abstract class SessionVault {
  Future<SavedInventorySession?> restore();
  Future<void> save(SavedInventorySession session);
  Future<void> clear();
  Future<String> deviceId(Uri baseUri, String email);
}

class SecureSessionVault implements SessionVault {
  final FlutterSecureStorage _storage;
  SecureSessionVault({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _sessionKey = 'inventory.auth.session.v1';

  @override
  Future<SavedInventorySession?> restore() async {
    final value = await _storage.read(key: _sessionKey);
    if (value == null) return null;
    return SavedInventorySession.fromJson(jsonObject(jsonDecode(value)));
  }

  @override
  Future<void> save(SavedInventorySession session) =>
      _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _sessionKey);

  @override
  Future<String> deviceId(Uri baseUri, String email) async {
    final origin = baseUri
        .replace(path: baseUri.path.replaceFirst(RegExp(r'/+$'), ''))
        .toString();
    final digest =
        sha256.convert(utf8.encode(origin + '\n' + email.trim().toLowerCase()));
    final key = 'inventory.device.' + digest.toString();
    final existing = await _storage.read(key: key);
    if (existing != null) return uuidText(existing);
    final id = newOperationUuid();
    await _storage.write(key: key, value: id);
    return id;
  }
}
