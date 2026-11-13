import 'package:inventario_app/application/session_vault.dart';
import 'package:inventario_app/data/models.dart';
import 'inventory_fixture.dart';

class MemorySessionVault implements SessionVault {
  SavedInventorySession? value;
  int saves = 0;
  final _devices = <String, String>{};
  MemorySessionVault([this.value]);
  @override
  Future<SavedInventorySession?> restore() async => value;
  @override
  Future<void> save(SavedInventorySession session) async {
    value = session;
    saves++;
  }

  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<String> deviceId(Uri baseUri, String email) async =>
      _devices.putIfAbsent(baseUri.toString() + email.toLowerCase(),
          () => _devices.isEmpty ? fixtureDeviceId : newOperationUuid());
}
