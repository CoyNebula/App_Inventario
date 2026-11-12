import 'api_client.dart';
import 'database.dart';
import 'inventory_repository.dart';
import 'models.dart';
import 'sync_service.dart';

/// Composition root for the UI in phase 3. Keep one instance per signed-in
/// account/device. Signing in as another account creates a separate engine;
/// old pending operations remain in SQLite and are never uploaded as that user.
class InventoryDataEngine {
  final InventoryDatabase database;
  late final MobileApiClient api;
  late final InventoryRepository repository;
  late final InventorySyncService sync;

  InventoryDataEngine({required Uri baseUri, required MobileSession session,
      required Future<String?> Function() tokenProvider,
      InventoryDatabase? database, bool allowLocalHttp = false})
      : database = database ?? InventoryDatabase.shared {
    api = MobileApiClient(baseUri: baseUri, tokenProvider: tokenProvider,
      allowLocalHttp: allowLocalHttp);
    repository = InventoryRepository(database: this.database, api: api, session: session);
    sync = InventorySyncService(database: this.database, api: api, session: session);
  }

  Future<SyncReport> synchronize({bool refreshSnapshots = true}) => sync.synchronize(
      refreshPackage: refreshSnapshots ? repository.refreshPackage : null);

  void closeNetwork() => api.close();
}
