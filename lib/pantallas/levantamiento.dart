import 'package:flutter/material.dart';

import '../application/error_messages.dart';
import '../data/inventory_data.dart';
import 'escaner_qr.dart';
import 'reasignacion.dart';

class PantallaLevantamiento extends StatefulWidget {
  const PantallaLevantamiento(
      {super.key,
      required this.engine,
      required this.packageId,
      required this.onSignOut});
  final InventoryDataEngine engine;
  final String packageId;
  final Future<void> Function() onSignOut;
  @override
  State<PantallaLevantamiento> createState() => _PantallaLevantamientoState();
}

class _PantallaLevantamientoState extends State<PantallaLevantamiento> {
  late String _packageId;
  final _codigo = TextEditingController();
  final _observaciones = TextEditingController();
  final _codigoFocus = FocusNode();
  InventoryProgress? _progress;
  InventoryItem? _item;
  JsonMap? _manifest;
  InventoryPeriod? _period;
  List<Map<String, Object?>> _departments = [];
  List<Map<String, Object?>> _locations = [];
  List<QueuedOperation> _operations = [];
  String? _rawQr;
  String? _error;
  bool _loading = true;
  bool _lookingUp = false;
  bool _saving = false;
  bool _syncing = false;
  bool _allowPop = false;
  InventoryRepository get _repo => widget.engine.repository;

  @override
  void initState() {
    super.initState();
    _packageId = widget.packageId;
    _reload();
  }

  @override
  void dispose() {
    _codigo.dispose();
    _observaciones.dispose();
    _codigoFocus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final draft = _dirty ? _observaciones.text : null;
    final draftDetail = _item?.detailId;
    try {
      final data = await Future.wait<Object?>([
        _repo.progress(_packageId),
        _repo.downloadedPackages(),
        _repo.operations(),
        _repo.localDepartments(_packageId),
        _repo.localLocations(_packageId),
        _repo.periodForPackage(_packageId),
      ]);
      final packages = data[1] as List<JsonMap>;
      final selected = packages.where((p) => p['package_id'] == _packageId);
      if (selected.length != 1) {
        throw const DataContractException(
            'Esta descarga ya no está activa. Vuelve a seleccionar la ubicación.');
      }
      final item =
          _item == null ? null : await _repo.item(_packageId, _item!.detailId);
      if (!mounted) return;
      setState(() {
        _progress = data[0] as InventoryProgress;
        _manifest = selected.single;
        _operations = data[2] as List<QueuedOperation>;
        _departments = data[3] as List<Map<String, Object?>>;
        _locations = data[4] as List<Map<String, Object?>>;
        _period = data[5] as InventoryPeriod?;
        _item = item;
        _loading = false;
        _error = null;
        if (item != null)
          _observaciones.text = draft != null && item.detailId == draftDetail
              ? draft
              : item.observations ?? '';
      });
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = inventoryErrorMessage(error);
          _loading = false;
        });
    }
  }

  bool get _offlineAuthorized {
    final sessionUntil = _repo.session.offlineUntil;
    final raw = _manifest?['offline_authorized_until'];
    final packageUntil = raw is String ? DateTime.tryParse(raw) : null;
    final now = _repo.clock().toUtc();
    return (sessionUntil ?? packageUntil)?.isAfter(now) == true &&
        packageUntil != null &&
        packageUntil.isAfter(now);
  }

  bool _unresolved(QueuedOperation op) =>
      op.status == 'pending' ||
      (['conflict', 'error'].contains(op.status) && op.resolvedAt == null);
  bool get _itemPending =>
      _item != null &&
      _operations
          .any((op) => op.detailId == _item!.detailId && _unresolved(op));
  bool get _itemNeedsRefresh =>
      _item != null &&
      _operations.any((op) =>
          op.packageId == _packageId &&
          op.detailId == _item!.detailId &&
          op.status != 'pending');
  bool get _canCapture =>
      _item != null &&
      !_saving &&
      !_syncing &&
      _offlineAuthorized &&
      _period?.state != 'cerrado' &&
      _item!.editable &&
      !_item!.restricted &&
      (!_item!.reviewed || _item!.reviewedById == _repo.session.userId) &&
      !_itemPending &&
      !_itemNeedsRefresh &&
      _repo.session.permissions.contains('hacer_levantamiento');
  bool get _dirty =>
      _item != null && _observaciones.text != (_item!.observations ?? '');

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _lookup(String raw) async {
    if (_lookingUp || _saving || _syncing || raw.trim().isEmpty) return;
    if (_dirty) {
      _notify(
          'Guarda las observaciones o limpia la ficha antes de buscar otro bien.');
      return;
    }
    setState(() {
      _lookingUp = true;
      _error = null;
    });
    try {
      final result = await _repo.findByQr(_packageId, raw);
      if (!mounted) return;
      if (result.status != QrLookupStatus.found) {
        setState(() {
          _item = null;
          _rawQr = null;
          _observaciones.clear();
        });
        _notify(result.message);
      } else {
        setState(() {
          _item = result.item;
          _rawQr = raw;
          _observaciones.text = result.item!.observations ?? '';
        });
      }
    } on Object catch (error) {
      _notify(inventoryErrorMessage(error));
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  Future<void> _scan() async {
    if (_dirty) {
      _notify(
          'Guarda las observaciones o limpia la ficha antes de escanear otro bien.');
      return;
    }
    final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const PantallaEscanerQr()));
    if (!mounted) return;
    if (raw != null) {
      _codigo.text = raw;
      await _lookup(raw);
    } else {
      _codigoFocus.requestFocus();
    }
  }

  Future<void> _save() async {
    if (!_canCapture) return;
    final item = _item!;
    setState(() => _saving = true);
    try {
      if (item.reviewed) {
        await _repo.updateObservations(_packageId, item.detailId,
            observations: _observaciones.text);
      } else {
        await _repo.confirmReview(_packageId, item.detailId,
            observations: _observaciones.text, rawQr: _rawQr);
      }
      await _reload();
      _notify('Guardado en este dispositivo. Pendiente de sincronizar.');
    } on Object catch (error) {
      _notify(inventoryErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reassign() async {
    if (!_canCapture) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => PantallaReasignacion(
            engine: widget.engine,
            packageId: _packageId,
            item: _item!,
            observations: _observaciones.text)));
    if (saved == true && mounted) {
      await _reload();
      _notify(
          'Propuesta guardada en este dispositivo. Pendiente de sincronizar.');
    }
  }

  Future<void> _synchronize() async {
    if (_syncing || _saving) return;
    if (_dirty) {
      _notify(
          'Guarda las observaciones con Ok o Actualizar antes de sincronizar.');
      return;
    }
    setState(() => _syncing = true);
    try {
      final report = await widget.engine.synchronize();
      if (!mounted) return;
      setState(() =>
          _packageId = report.refreshedPackages[_packageId] ?? _packageId);
      await _reload();
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Resultado de sincronización'),
                  content: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Text(
                            '${report.applied} enviados · ${report.pending} pendientes'),
                        const SizedBox(height: 8),
                        Text(
                            '${report.conflicts} conflictos · ${report.rejected} rechazados'),
                        if (report.refreshedPackages.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Text(
                              'Se actualizaron las descargas con los datos del servidor.')
                        ],
                        for (final error in report.errors)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_syncMessage(error))),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cerrar'))
                  ]));
    } on Object catch (error) {
      _notify(inventoryErrorMessage(error));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _resolve(QueuedOperation operation) async {
    if (_syncing || _saving) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Resolver respuesta del servidor'),
                content: Text(
                    '${_reason(operation.lastError ?? operation.receipt?['code'] as String?)}\n\n'
                    'La captura y la respuesta se conservarán en el historial. Se intentará actualizar la descarga '
                    'antes de permitir una nueva captura sobre este bien.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Volver')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Resolver y actualizar'))
                ]));
    if (accepted != true || !mounted) return;
    try {
      await _repo.resolveRejectedOperation(operation.uuid);
      await _reload();
      await _synchronize();
    } on Object catch (error) {
      _notify(inventoryErrorMessage(error));
    }
  }

  Future<bool> _discardDraft() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Observaciones sin guardar'),
                    content: const Text(
                        'Este texto aún no está guardado en el dispositivo.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Seguir editando')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Descartar texto')),
                    ])) ??
        false;
  }

  Future<void> _back(bool didPop, Object? result) async {
    if (didPop || _saving || _syncing) return;
    if (!await _discardDraft() || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _signOut() async {
    if (!await _discardDraft() || !mounted) return;
    setState(() => _observaciones.text = _item?.observations ?? '');
    try {
      await widget.onSignOut();
    } on Object catch (error) {
      _notify(inventoryErrorMessage(error));
    }
  }

  Future<void> _clearItem() async {
    if (!await _discardDraft() || !mounted) return;
    setState(() {
      _item = null;
      _rawQr = null;
      _observaciones.clear();
      _codigo.clear();
    });
  }

  String _syncMessage(String error) {
    if (error.contains('TOKEN_EXPIRED_OR_REVOKED') ||
        error.contains('AUTH_REQUIRED')) {
      return inventoryErrorMessage(
          const MobileApiException(401, 'AUTH_REQUIRED'));
    }
    if (error.contains('SERVER_NOT_READY')) {
      return inventoryErrorMessage(
          const MobileApiException(503, 'SERVER_NOT_READY'));
    }
    return 'No se completó una parte de la sincronización. Las capturas pendientes siguen guardadas; revisa la conexión y vuelve a intentar.';
  }

  String _department(Object? id) {
    if (id == null) return 'Sin departamento registrado';
    for (final row in _departments) {
      if (row['numero_departamento'] == id)
        return row['descripcion'] as String? ?? 'Departamento $id';
    }
    return 'Departamento $id';
  }

  String _location(Object? id) {
    if (id == null) return 'Sin ubicación registrada';
    for (final row in _locations) {
      if (row['id'] == id)
        return row['descripcion'] as String? ?? 'Ubicación $id';
    }
    return 'Ubicación $id';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final unresolved = _operations.where(_unresolved).toList();
    final pendingCount =
        unresolved.where((op) => op.status == 'pending').length;
    final conflictCount =
        unresolved.where((op) => op.status == 'conflict').length;
    final rejectedCount = unresolved.where((op) => op.status == 'error').length;
    return PopScope(
        canPop: !_saving && !_syncing && (!_dirty || _allowPop),
        onPopInvokedWithResult: _back,
        child: Scaffold(
            appBar: AppBar(
                title: const Text('Levantamiento de inventario'),
                actions: [
                  IconButton(
                      tooltip: 'Cerrar sesión',
                      onPressed: _saving || _syncing ? null : _signOut,
                      icon: const Icon(Icons.logout))
                ]),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _reload,
                    child:
                        ListView(padding: const EdgeInsets.all(16), children: [
                      Text(_repo.session.userName,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      if (_manifest != null)
                        Text('Periodo ${_manifest!['periodo_id']} · '
                            '${_department(_manifest!['numero_departamento_inicial'])} · '
                            '${_location(_manifest!['ubicacion_id_inicial'])}'),
                      const SizedBox(height: 12),
                      if (_period?.state == 'cerrado')
                        _notice(
                            'Periodo cerrado. Esta descarga está disponible para consulta.',
                            Icons.lock_outline,
                            Colors.orange),
                      _notice(
                          _offlineAuthorized
                              ? 'Captura disponible sin conexión'
                              : 'Autorización offline vencida. Conecta para renovar el acceso.',
                          _offlineAuthorized
                              ? Icons.offline_pin
                              : Icons.lock_clock,
                          _offlineAuthorized ? Colors.teal : Colors.orange),
                      if (_error != null)
                        _notice(_error!, Icons.error_outline, Colors.red),
                      if (progress != null) _progressCard(progress),
                      const SizedBox(height: 12),
                      Text(
                          '$pendingCount pendientes · $conflictCount conflictos · $rejectedCount rechazados',
                          key: const Key('sync-summary'),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                          key: const Key('sincronizar'),
                          onPressed: _syncing || _saving ? null : _synchronize,
                          icon: _syncing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.sync),
                          label: Text(_syncing
                              ? 'Sincronizando…'
                              : 'Sincronizar con el servidor')),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                              'La captura se guarda en este dispositivo. Sincroniza cuando tengas internet.')),
                      _scannerCard(),
                      if (_item != null) _itemCard(_item!),
                      const SizedBox(height: 12),
                      _queueCard(unresolved),
                    ]))));
  }

  Widget _progressCard(InventoryProgress progress) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Avance del levantamiento',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Wrap(spacing: 24, runSpacing: 12, children: [
              _metric('TOTAL', '${progress.total}'),
              _metric('REVISADOS', '${progress.reviewed}'),
              _metric('PENDIENTES', '${progress.pending}'),
              _metric(
                  'PORCENTAJE',
                  progress.percentage == null
                      ? 'Sin bienes'
                      : '${progress.percentage!.toStringAsFixed(0)}%')
            ]),
            const SizedBox(height: 12),
            LinearProgressIndicator(
                value: progress.total == 0
                    ? 0
                    : progress.reviewed / progress.total),
            const SizedBox(height: 6),
            const Text('Incluye capturas guardadas en este dispositivo.')
          ])));

  Widget _metric(String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.labelSmall)
      ]);

  Widget _scannerCard() => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Buscar un bien',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: _lookingUp || _saving || _syncing ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Escanear QR')),
            const SizedBox(height: 12),
            TextField(
                key: const Key('codigo_manual'),
                controller: _codigo,
                focusNode: _codigoFocus,
                enabled: !_lookingUp && !_saving && !_syncing,
                decoration: const InputDecoration(
                    labelText: 'QR o número de inventario',
                    helperText:
                        'También puedes escribir la clave o pegar el contenido del QR.',
                    border: OutlineInputBorder()),
                onSubmitted: _lookup),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
                key: const Key('buscar_bien'),
                onPressed: _lookingUp || _saving || _syncing
                    ? null
                    : () => _lookup(_codigo.text),
                icon: const Icon(Icons.search),
                label:
                    Text(_lookingUp ? 'Buscando…' : 'Buscar en esta descarga'))
          ])));

  Widget _itemCard(InventoryItem item) {
    final actual = item.current;
    final custodian = actual?['resguardante'] == null
        ? null
        : jsonObject(actual!['resguardante']);
    final ownReview =
        item.reviewed && item.reviewedById == _repo.session.userId;
    final command =
        ownReview ? SyncCommand.updateObservations : SyncCommand.confirmReview;
    final commandAllowed = _repo.session.commands.contains(command.wireName);
    return Card(
        key: const Key('ficha_bien'),
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text('Ficha del bien',
                            style: Theme.of(context).textTheme.titleMedium)),
                    TextButton.icon(
                        onPressed: _saving || _syncing ? null : _clearItem,
                        icon: const Icon(Icons.clear),
                        label: const Text('Limpiar'))
                  ]),
                  _data('Clave activo fijo', item.identity.key),
                  _data('No. inventario', item.identity.number),
                  if (item.restricted)
                    _notice(
                        'Los datos actuales de este bien están restringidos. Solo lectura.',
                        Icons.lock_outline,
                        Colors.orange)
                  else ...[
                    _data(
                        'Descripción',
                        actual?['descripcion'] as String? ??
                            'Sin descripción registrada'),
                    _data(
                        'Resguardante',
                        custodian?['nombre_completo'] as String? ??
                            (custodian == null
                                ? 'Sin resguardante registrado'
                                : 'Empleado ${custodian['clave_empleado']}')),
                    _data('Departamento actual',
                        _department(actual?['numero_departamento'])),
                    _data(
                        'Ubicación actual', _location(actual?['ubicacion_id']))
                  ],
                  if (item.reviewed) ...[
                    _data(
                        'Revisado por',
                        item.reviewerName ??
                            'Usuario ${item.reviewedById ?? 'sin identificar'}'),
                    _data(
                        'Fecha de revisión',
                        item.toJson()['fecha_revisado'] as String? ??
                            'Pendiente de confirmación del servidor')
                  ],
                  if (_itemPending)
                    _notice(
                        'Este bien tiene una operación pendiente. Puedes escanear otros bienes.',
                        Icons.schedule,
                        Colors.orange)
                  else if (_itemNeedsRefresh)
                    _notice(
                        'Actualiza la descarga desde el servidor antes de volver a editar este bien.',
                        Icons.refresh,
                        Colors.orange)
                  else if (item.reviewed && !ownReview)
                    _notice(
                        'Solo lectura: este bien fue revisado por otro usuario.',
                        Icons.lock_outline,
                        Colors.blueGrey)
                  else if (!item.editable)
                    _notice(
                        'Este bien está disponible en modo de solo lectura.',
                        Icons.lock_outline,
                        Colors.blueGrey),
                  const SizedBox(height: 12),
                  TextField(
                      key: const Key('observaciones_bien'),
                      controller: _observaciones,
                      onChanged: (_) => setState(() {}),
                      readOnly: !_canCapture || !commandAllowed,
                      maxLines: 3,
                      maxLength: 5000,
                      decoration: const InputDecoration(
                          labelText: 'Observaciones',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                      key: const Key('guardar_bien'),
                      onPressed: _canCapture && commandAllowed ? _save : null,
                      icon: const Icon(Icons.check),
                      label: Text(_saving
                          ? 'Guardando…'
                          : ownReview
                              ? 'Actualizar observaciones'
                              : 'Ok · Confirmar revisión')),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                      key: const Key('reasignar_bien'),
                      onPressed: _canCapture &&
                              _repo.session.permissions.contains('asignar') &&
                              _repo.session.commands.contains(
                                  SyncCommand.proposeReassignment.wireName) &&
                              item.version['resguardo_id'] != null
                          ? _reassign
                          : null,
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Reasignar')),
                  const SizedBox(height: 6),
                  const Text('¿El bien está con otra persona? Pulsa Reasignar.')
                ])));
  }

  Widget _data(String title, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value)
      ]));

  Widget _notice(String message, IconData icon, MaterialColor color) =>
      Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: color.shade50, borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: color.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(message))
          ]));

  Widget _queueCard(List<QueuedOperation> unresolved) => Card(
      child: ExpansionTile(
          initiallyExpanded: unresolved.isNotEmpty,
          title: Text(
              'Capturas por sincronizar o resolver (${unresolved.length})'),
          subtitle: const Text(
              'Se conservan aunque cierres la aplicación o la sesión.'),
          children: unresolved.isEmpty
              ? [
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No hay operaciones pendientes.'))
                ]
              : unresolved.map((op) {
                  final identity = jsonObject(op.operation['bien']);
                  final pending = op.status == 'pending';
                  return ListTile(
                      isThreeLine: true,
                      leading: Icon(
                          pending ? Icons.schedule : Icons.error_outline,
                          color: pending ? Colors.orange : Colors.red),
                      title: Text(
                          '${identity['numero_inventario_consecutivo']} · ${_commandName(op.type)}'),
                      subtitle: Text(
                          '${pending ? 'Pendiente de envío o acuse' : op.status == 'conflict' ? 'Conflicto' : 'Rechazado'}'
                          '\n${op.lastError == null ? identity['clave_activo_fijo'] : _reason(op.lastError)}'),
                      trailing: pending || op.receipt == null
                          ? null
                          : TextButton(
                              onPressed: _syncing || _saving
                                  ? null
                                  : () => _resolve(op),
                              child: const Text('Resolver')));
                }).toList()));

  String _commandName(String command) => switch (command) {
        'confirmar_revision' => 'Revisión',
        'actualizar_observaciones' => 'Observaciones',
        'proponer_reasignacion' => 'Reasignación',
        _ => command
      };
  String _reason(String? code) => switch (code) {
        'VERSION_CONFLICT' => 'El registro cambió en el servidor.',
        'REVIEW_OWNED_BY_OTHER' => 'Otro usuario revisó este bien.',
        'ALREADY_REVIEWED' => 'El bien ya aparece revisado en el servidor.',
        'PERIOD_CLOSED' => 'El periodo fue cerrado en el servidor.',
        'SCOPE_FORBIDDEN' =>
          'La ubicación ya no está autorizada para esta cuenta.',
        'PERMISSION_DENIED' =>
          'La cuenta ya no tiene permiso para esta acción.',
        'SAME_CUSTODIAN' => 'El bien ya está asignado al resguardante elegido.',
        'INVALID_DESTINATION' =>
          'El empleado o la ubicación de destino cambió.',
        'FIRST_ASSIGNMENT_FORBIDDEN' =>
          'Este bien requiere una primera asignación administrativa.',
        'SERVER_BUSY' =>
          'El servidor está ocupado. La captura sigue pendiente.',
        null => 'Revisa la respuesta antes de volver a capturar.',
        _ =>
          'No se completó esta acción. La captura sigue guardada para su revisión.'
      };
}
