import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/engine.dart';
import '../data/models.dart';
import 'levantamiento.dart';

class PantallaSeleccion extends StatefulWidget {
  const PantallaSeleccion({
    super.key,
    required this.engine,
    required this.onSignOut,
  });

  final InventoryDataEngine engine;
  final Future<void> Function() onSignOut;

  @override
  State<PantallaSeleccion> createState() => _PantallaSeleccionState();
}

class _PantallaSeleccionState extends State<PantallaSeleccion> {
  final _periodForm = GlobalKey<FormState>();
  final _name = TextEditingController();
  late int _year;
  late int _month;
  InventoryPeriod? _period;
  bool _canClose = false;
  bool _closing = false;
  String? _periodMessage;
  List<Department> _departments = [];
  List<Location> _locations = [];
  List<_LocalPackage> _packages = [];
  String? _periodId;
  String? _departmentNumber;
  String? _locationId;
  String? _remoteError;
  String? _localError;
  String? _downloadError;
  bool _loadingPeriods = true;
  bool _loadingDepartments = false;
  bool _loadingLocations = false;
  bool _loadingLocal = true;
  bool _downloading = false;
  bool _opening = false;
  bool _signingOut = false;
  int _periodRequest = 0;
  int _departmentRequest = 0;
  int _locationRequest = 0;
  int _localRequest = 0;
  int _receivedPages = 0;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    final now = widget.engine.repository.clock();
    _year = now.year.clamp(2000, 2100).toInt();
    _month = now.month;
    unawaited(_loadLocal());
    unawaited(_loadPeriods());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _changeDate({int? year, int? month}) {
    _periodRequest++;
    _departmentRequest++;
    _locationRequest++;
    setState(() {
      _year = year ?? _year;
      _month = month ?? _month;
      _period = null;
      _periodId = _departmentNumber = _locationId = null;
      _departments = [];
      _locations = [];
      _canClose = false;
      _periodMessage = null;
      _remoteError = _downloadError = null;
      _loadingPeriods = _loadingDepartments = _loadingLocations = false;
    });
  }

  Future<void> _loadPeriods({bool allowCreate = false}) async {
    if (allowCreate && !(_periodForm.currentState?.validate() ?? false)) return;
    final request = ++_periodRequest;
    final year = _year;
    final month = _month;
    final name = _name.text.trim();
    setState(() {
      _loadingPeriods = true;
      _remoteError = null;
      _periodMessage = null;
    });
    try {
      final lookup = await widget.engine.api.lookupPeriod(year: year, month: month);
      if (!mounted || request != _periodRequest) return;
      InventoryPeriod? period = lookup.period;
      if (period == null && allowCreate && lookup.canCreate) {
        final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Crear periodo de levantamiento'),
          content: Text('No existe el periodo $month/$year. ¿Crear "$name" con los bienes actuales del sistema?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(key: const Key('confirm-create-period'), onPressed: () => Navigator.pop(context, true), child: const Text('Crear periodo')),
          ],
        ));
        if (!mounted || request != _periodRequest) return;
        if (accepted == true) {
          period = await widget.engine.api.createPeriod(year: year, month: month, name: name);
        }
      }
      if (!mounted || request != _periodRequest) return;
      if (period != null) {
        final selected = period;
        setState(() {
          _name.text = selected.name;
          _canClose = lookup.canClose || (lookup.canCreate && selected.state == 'abierto');
        });
        await _selectPeriod(selected);
      } else {
        await _selectPeriod(null);
        if (mounted) setState(() => _periodMessage = lookup.canCreate
            ? 'No existe un periodo para este año y mes. Escribe el nombre y pulsa Crear/Cargar periodo.'
            : 'No existe el periodo de levantamiento. Consulta con el Administrador.');
      }
    } on Object catch (error) {
      if (!mounted || request != _periodRequest) return;
      setState(() {
        _remoteError = _message(error);
      });
    } finally {
      if (mounted && request == _periodRequest) setState(() => _loadingPeriods = false);
    }
  }

  Future<void> _selectPeriod(InventoryPeriod? period) async {
    final request = ++_departmentRequest;
    _locationRequest++;
    final id = period?.id;
    setState(() {
      _period = period;
      _periodId = id;
      _departmentNumber = _locationId = null;
      _departments = [];
      _locations = [];
      _remoteError = _downloadError = null;
      _loadingDepartments = id != null && period?.state == 'abierto';
      _loadingLocations = false;
    });
    if (period != null) await widget.engine.repository.updatePeriodState(period);
    if (id == null || period?.state != 'abierto') return;
    try {
      final rows = await widget.engine.repository.departments(id);
      final departments = rows.map(Department.fromJson).toList(growable: false);
      if (!mounted || request != _departmentRequest || _periodId != id) return;
      setState(() {
        _departments = departments;
        _loadingDepartments = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _departmentRequest) return;
      setState(() {
        _loadingDepartments = false;
        _remoteError = _message(error);
      });
    }
  }

  Future<void> _closePeriod() async {
    final period = _period;
    if (period == null || !_canClose || _closing || _downloading || _loadingPeriods) return;
    setState(() => _closing = true);
    try {
      final queue = await widget.engine.repository.operations();
      final pending = queue.where((op) => op.operation['periodo_id'] == period.id && op.status != 'synced' && op.resolvedAt == null).length;
      if (!mounted) return;
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Cerrar levantamiento'),
        content: Text('¿Cerrar "${period.name}"? El periodo no podrá recibir más revisiones.'
          '${pending > 0 ? '\n\nHay $pending capturas por sincronizar o resolver. Se conservarán en el dispositivo, pero el servidor puede rechazarlas después del cierre.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirm-close-period'), onPressed: () => Navigator.pop(context, true), child: const Text('Cerrar levantamiento')),
        ],
      ));
      if (accepted != true || !mounted) return;
      final closed = await widget.engine.api.closePeriod(period.id);
      if (!mounted) return;
      setState(() => _canClose = false);
      await _selectPeriod(closed);
      await _loadLocal();
    } on Object catch (error) {
      if (mounted) setState(() => _remoteError = _message(error));
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  Future<void> _selectDepartment(String? number) async {
    final request = ++_locationRequest;
    final period = _periodId;
    setState(() {
      _departmentNumber = number;
      _locationId = null;
      _locations = [];
      _remoteError = _downloadError = null;
      _loadingLocations = number != null && period != null;
    });
    if (number == null || period == null) return;
    try {
      final rows = await widget.engine.repository.locations(period, number);
      final locations = rows.map(Location.fromJson).toList(growable: false);
      if (locations.any((location) => location.departmentNumber != number)) {
        throw const DataContractException(
            'El servicio devolvió ubicaciones de otro departamento.');
      }
      if (!mounted ||
          request != _locationRequest ||
          period != _periodId ||
          number != _departmentNumber) {
        return;
      }
      setState(() {
        _locations = locations;
        _loadingLocations = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _locationRequest) return;
      setState(() {
        _loadingLocations = false;
        _remoteError = _message(error);
      });
    }
  }

  Future<void> _loadLocal() async {
    final request = ++_localRequest;
    if (mounted) {
      setState(() {
        _loadingLocal = true;
        _localError = null;
      });
    }
    try {
      final repository = widget.engine.repository;
      final manifests = await repository.downloadedPackages();
      final operations = await repository.operations();
      final packages = await Future.wait(manifests.map((manifest) async {
        final id = uuidText(manifest['package_id']);
        final departments = await repository.localDepartments(id);
        final locations = await repository.localLocations(id);
        final progress = await repository.progress(id);
        final metadata = await (await widget.engine.database.database).query(
          'packages',
          columns: ['period_json'],
          where: 'package_id=?',
          whereArgs: [id],
        );
        JsonMap? period;
        if (metadata.isNotEmpty && metadata.single['period_json'] is String) {
          period =
              jsonObject(jsonDecode(metadata.single['period_json'] as String));
        }
        final department = departments.where((row) =>
            row['numero_departamento'] ==
            manifest['numero_departamento_inicial']);
        final location = locations
            .where((row) => row['id'] == manifest['ubicacion_id_inicial']);
        return _LocalPackage(
          id: id,
          period: period?['nombre'] as String? ??
              'Periodo ${manifest['periodo_id']}',
          department: department.isNotEmpty
              ? department.first['descripcion'] as String?
              : null,
          departmentNumber: manifest['numero_departamento_inicial'] as String,
          location: location.isNotEmpty
              ? location.first['descripcion'] as String?
              : null,
          locationId: manifest['ubicacion_id_inicial'] as String?,
          progress: progress,
          pending: operations
              .where((op) =>
                  op.packageId == id &&
                  op.status != 'synced' &&
                  op.resolvedAt == null)
              .length,
        );
      }));
      if (!mounted || request != _localRequest) return;
      setState(() {
        _packages = packages;
        _loadingLocal = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _localRequest) return;
      setState(() {
        _loadingLocal = false;
        _localError = _message(error);
      });
    }
  }

  Future<void> _download() async {
    final period = _periodId;
    final department = _departmentNumber;
    final location = _locationId;
    if (_downloading || _closing || _period?.state != 'abierto' ||
        period == null ||
        department == null ||
        location == null) {
      return;
    }
    setState(() {
      _downloading = true;
      _downloadError = null;
      _receivedPages = _totalPages = 0;
    });
    try {
      final session = widget.engine.repository.session;
      final id = await widget.engine.repository.downloadLocation(
        periodId: period,
        departmentNumber: department,
        locationId: location,
        includeReassignmentCatalogs: session.permissions.contains('asignar') &&
            session.commands.contains(SyncCommand.proposeReassignment.wireName),
        onDownloadProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedPages = received;
            _totalPages = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
      });
      await _loadLocal();
      if (mounted) await _openPackage(id);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadError = _message(error);
      });
      await _loadLocal();
    }
  }

  Future<void> _openPackage(String id) async {
    if (_opening || _downloading || _signingOut) return;
    setState(() {
      _opening = true;
    });
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PantallaLevantamiento(
              engine: widget.engine,
              packageId: id,
              onSignOut: widget.onSignOut)));
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
        });
        await _loadLocal();
      }
    }
  }

  Future<void> _signOut() async {
    if (_signingOut || _downloading) return;
    setState(() {
      _signingOut = true;
    });
    try {
      await widget.onSignOut();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _remoteError = _message(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _signingOut = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    unawaited(_loadLocal());
    await _loadPeriods();
  }

  String _message(Object error) {
    if (error is DataContractException) return error.message;
    if (error is TimeoutException) {
      return 'La conexión tardó demasiado. Intenta de nuevo.';
    }
    if (error is MobileApiException) {
      return switch (error.code) {
        'AUTH_REQUIRED' ||
        'TOKEN_EXPIRED_OR_REVOKED' =>
          'La sesión en línea venció. Puedes abrir tus descargas guardadas.',
        'SERVER_NOT_READY' =>
          'El servicio de inventario no está disponible en este momento.',
        'DEVICE_PENDING_AUTHORIZATION' =>
          'El dispositivo está pendiente de autorización.',
        'SCOPE_FORBIDDEN' ||
        'PERMISSION_DENIED' =>
          'No tienes autorización para esta ubicación o acción.',
        'PERIOD_CLOSED' => 'El periodo está cerrado. Selecciona otro periodo.',
        _ => 'No se pudo consultar el servicio. Intenta de nuevo.',
      };
    }
    return 'No se pudo completar la operación. Revisa la conexión e inténtalo de nuevo.';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xfff3f6f9),
      appBar: AppBar(
        title: const Text('Preparar levantamiento'),
        actions: [
          IconButton(
              tooltip: 'Actualizar',
              onPressed: _downloading || _signingOut || _closing || _loadingPeriods ? null : _reload,
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: 'Cerrar sesión',
              onPressed: _downloading || _signingOut || _closing || _loadingPeriods ? null : _signOut,
              icon: const Icon(Icons.logout)),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
                padding: EdgeInsets.all(constraints.maxWidth < 600 ? 16 : 28),
                child: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                      color: colors.primaryContainer,
                                      borderRadius: BorderRadius.circular(20)),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            widget.engine.repository.session
                                                .userName,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 8),
                                        Text(
                                            'Descarga una ubicación antes de salir',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                        const SizedBox(height: 8),
                                        const Text(
                                            'Con internet, selecciona el periodo y el lugar. Después podrás revisar los bienes por QR y guardar el avance sin conexión.'),
                                      ])),
                              const SizedBox(height: 24),
                              if (constraints.maxWidth >= 900)
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: _downloadCard()),
                                      const SizedBox(width: 24),
                                      Expanded(child: _localCard()),
                                    ])
                              else ...[
                                _downloadCard(),
                                const SizedBox(height: 20),
                                _localCard()
                              ],
                            ]))),
              )),
    );
  }

  Widget _downloadCard() {
    final enabled = !_downloading && !_signingOut && !_closing;
    return _card('Nueva descarga', Icons.cloud_download_outlined, [
      const Text('Requiere conexión con el servicio de inventario.'),
      const SizedBox(height: 20),
      if (_loadingPeriods)
        const LinearProgressIndicator(key: ValueKey('period-loading')),
      Form(key: _periodForm, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: DropdownButtonFormField<int>(
            key: const Key('period-year'),
            initialValue: _year,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Año', border: OutlineInputBorder()),
            items: List.generate(101, (index) => 2000 + index).map((year) => DropdownMenuItem(value: year, child: Text('$year'))).toList(),
            onChanged: enabled ? (year) { if (year != null) _changeDate(year: year); } : null,
          )),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<int>(
            key: const Key('period-month'),
            initialValue: _month,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Mes', border: OutlineInputBorder()),
            items: const ['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'].asMap().entries.map((entry) => DropdownMenuItem(value: entry.key + 1, child: Text(entry.value, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: enabled ? (month) { if (month != null) _changeDate(month: month); } : null,
          )),
        ]),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('period-name'),
          controller: _name,
          enabled: enabled && !_loadingPeriods,
          maxLength: 255,
          decoration: const InputDecoration(labelText: 'Nombre', border: OutlineInputBorder()),
          validator: (value) => value == null || value.trim().isEmpty ? 'Escribe el nombre del levantamiento.' : null,
        ),
        FilledButton.icon(
          key: const Key('load-period'),
          onPressed: enabled && !_loadingPeriods ? () => _loadPeriods(allowCreate: true) : null,
          icon: const Icon(Icons.event),
          label: Text(_loadingPeriods ? 'Consultando periodo…' : 'Crear/Cargar periodo'),
        ),
      ])),
      if (_periodMessage != null) _notice(_periodMessage!),
      if (_period != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(
        '${_period!.name} · ${_period!.state == 'abierto' ? 'Abierto' : 'Cerrado'}',
        key: const Key('loaded-period'),
        style: Theme.of(context).textTheme.titleMedium,
      )),
      if (_period?.state == 'cerrado') const Padding(padding: EdgeInsets.only(top: 8), child: Text(
        'Este levantamiento está cerrado. Puedes consultar las descargas guardadas; no admite nuevas capturas.'
      )),
      if (_canClose || widget.engine.session.canManagePeriods) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('close-period'),
          onPressed: enabled && !_loadingPeriods && _canClose && _period?.state == 'abierto' ? _closePeriod : null,
          icon: const Icon(Icons.lock_outline),
          label: Text(_closing ? 'Cerrando…' : 'Cerrar levantamiento'),
        ),
      ],
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey('department-selector-$_departmentNumber'),
        initialValue: _departmentNumber,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Departamento *', border: OutlineInputBorder()),
        hint: Text(_loadingDepartments
            ? 'Cargando departamentos…'
            : 'Selecciona un departamento'),
        items: _departments
            .map((department) => DropdownMenuItem(
                value: department.number,
                child: Text(
                    department.description ??
                        'Departamento ${department.number}',
                    overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: enabled && !_loadingPeriods && _period?.state == 'abierto' && _periodId != null && !_loadingDepartments
            ? _selectDepartment
            : null,
      ),
      if (_periodId != null &&
          !_loadingDepartments &&
          _remoteError == null &&
          _departments.isEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No hay departamentos registrados.')),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey('location-selector-$_locationId'),
        initialValue: _locationId,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Ubicación *', border: OutlineInputBorder()),
        hint: Text(_loadingLocations
            ? 'Cargando ubicaciones…'
            : 'Selecciona una ubicación'),
        items: _locations
            .map((location) => DropdownMenuItem(
                value: location.id,
                child: Text(location.description ?? 'Ubicación ${location.id}',
                    overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: enabled && !_loadingPeriods && _period?.state == 'abierto' && _departmentNumber != null && !_loadingLocations
            ? (id) => setState(() {
                  _locationId = id;
                  _downloadError = null;
                })
            : null,
      ),
      if (_departmentNumber != null &&
          !_loadingLocations &&
          _remoteError == null &&
          _locations.isEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child:
                Text('No hay ubicaciones registradas en este departamento.')),
      if (_remoteError != null) _notice(_remoteError!),
      if (_downloadError != null) _notice(_downloadError!),
      const SizedBox(height: 20),
      if (_downloading) ...[
        LinearProgressIndicator(
            key: const ValueKey('download-progress'),
            value: _totalPages == 0 ? null : _receivedPages / _totalPages),
        const SizedBox(height: 10),
        Text(_totalPages == 0
            ? 'Preparando descarga…'
            : 'Verificando páginas: $_receivedPages de $_totalPages'),
        const SizedBox(height: 12),
      ],
      FilledButton.icon(
          key: const ValueKey('download-location'),
          onPressed: enabled &&
                  !_loadingPeriods &&
                  _period?.state == 'abierto' &&
                  !_loadingDepartments &&
                  !_loadingLocations &&
                  _periodId != null &&
                  _departmentNumber != null &&
                  _locationId != null
              ? _download
              : null,
          icon: const Icon(Icons.download),
          label: Text(_downloading ? 'Descargando…' : 'Descargar y abrir')),
    ]);
  }

  Widget _localCard() =>
      _card('Disponibles sin conexión', Icons.offline_pin_outlined, [
        const Text(
            'Puedes abrir estas ubicaciones aunque el servicio no esté disponible.'),
        const SizedBox(height: 16),
        if (_loadingLocal)
          const LinearProgressIndicator(key: ValueKey('local-loading')),
        if (_localError != null) _notice(_localError!),
        if (!_loadingLocal && _packages.isEmpty && _localError == null)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                  'Aún no hay ubicaciones descargadas en este dispositivo.')),
        for (final package in _packages)
          Container(
              key: ValueKey('cached-${package.id}'),
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        package.location ??
                            (package.locationId == null
                                ? 'Departamento completo'
                                : 'Ubicación ${package.locationId}'),
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(package.department ??
                        'Departamento ${package.departmentNumber}'),
                    Text(package.period,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Text(
                        '${package.progress.reviewed} de ${package.progress.total} revisados · ${package.pending} por sincronizar'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                        key: ValueKey('open-${package.id}'),
                        onPressed: _downloading || _opening || _signingOut || _closing
                            ? null
                            : () => _openPackage(package.id),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Abrir sin conexión')),
                  ])),
      ]);

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(icon, color: const Color(0xff166a73)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(title,
                            style: Theme.of(context).textTheme.titleLarge))
                  ]),
                  const SizedBox(height: 16),
                  ...children,
                ])),
      );

  Widget _notice(String message) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Text(message,
          style: TextStyle(color: Theme.of(context).colorScheme.error)));
}

class _LocalPackage {
  const _LocalPackage(
      {required this.id,
      required this.period,
      required this.department,
      required this.departmentNumber,
      required this.location,
      required this.locationId,
      required this.progress,
      required this.pending});
  final String id;
  final String period;
  final String? department;
  final String departmentNumber;
  final String? location;
  final String? locationId;
  final InventoryProgress progress;
  final int pending;
}
