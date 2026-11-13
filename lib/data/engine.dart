/* orquestador principal del sistema de inventario */

import 'api_client.dart';
import 'database.dart';
import 'inventory_repository.dart';
import 'models.dart';
import 'sync_service.dart';
import 'package:http/http.dart' as http;

class InventoryDataEngine {
  final InventoryDatabase database;
  final MobileSession session;
  late final MobileApiClient api;
  late final InventoryRepository repository;
  late final InventorySyncService sync;

  InventoryDataEngine(
      {required Uri baseUri,
      required this.session,
      required Future<String?> Function() tokenProvider,
      InventoryDatabase? database,
      bool allowLocalHttp = false,
      http.Client? client,
      DateTime Function()? clock})
      : database = database ?? InventoryDatabase.shared {
    api = MobileApiClient(
        baseUri: baseUri,
        tokenProvider: tokenProvider,
        allowLocalHttp: allowLocalHttp,
        client: client);
    repository = InventoryRepository(
        database: this.database, api: api, session: session, clock: clock);
    sync = InventorySyncService(
        database: this.database, api: api, session: session, clock: clock);
  }

  Future<SyncReport> synchronize({bool refreshSnapshots = true}) =>
      sync.synchronize(
          refreshPackage: refreshSnapshots ? repository.refreshPackage : null);

  void closeNetwork() => api.close();
}
