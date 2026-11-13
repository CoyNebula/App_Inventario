import 'package:flutter/material.dart';

import '../application/error_messages.dart';
import '../data/inventory_data.dart';

class PantallaReasignacion extends StatefulWidget {
  const PantallaReasignacion(
      {super.key,
      required this.engine,
      required this.packageId,
      required this.item,
      this.observations = ''});
  final InventoryDataEngine engine;
  final String packageId;
  final InventoryItem item;
  final String observations;
  @override
  State<PantallaReasignacion> createState() => _PantallaReasignacionState();
}

class _PantallaReasignacionState extends State<PantallaReasignacion> {
  final _form = GlobalKey<FormState>();
  final _search = TextEditingController();
  final _date = TextEditingController();
  final _observations = TextEditingController();
  List<Map<String, Object?>> _employees = [];
  List<Map<String, Object?>> _departments = [];
  List<Map<String, Object?>> _locations = [];
  Map<String, Object?>? _employee;
  String? _department;
  String? _location;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _allowPop = false;
  late final String _initialDate;
  InventoryRepository get _repo => widget.engine.repository;

  @override
  void initState() {
    super.initState();
    _date.text = _repo.clock().toIso8601String().substring(0, 10);
    _initialDate = _date.text;
    _observations.text = widget.observations;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _date.dispose();
    _observations.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await Future.wait([
        _repo.localEmployees(widget.packageId),
        _repo.localDepartments(widget.packageId),
        _repo.localLocations(widget.packageId)
      ]);
      if (!mounted) return;
      setState(() {
        _employees = rows[0];
        _departments = rows[1];
        _locations = rows[2];
        _loading = false;
        final current = widget.item.current?['numero_departamento'] as String?;
        _department =
            _departments.any((d) => d['numero_departamento'] == current)
                ? current
                : null;
        final currentLocation = widget.item.current?['ubicacion_id'] as String?;
        _location = _destinations.any((l) => l['id'] == currentLocation)
            ? currentLocation
            : null;
      });
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = inventoryErrorMessage(error);
          _loading = false;
        });
    }
  }

  List<Map<String, Object?>> get _destinations => _locations
      .where((row) => row['numero_departamento'] == _department)
      .toList();
  bool get _allowed =>
      _repo.session.permissions.contains('hacer_levantamiento') &&
      _repo.session.permissions.contains('asignar') &&
      _repo.session.commands
          .contains(SyncCommand.proposeReassignment.wireName) &&
      widget.item.editable &&
      !widget.item.restricted &&
      (!widget.item.reviewed ||
          widget.item.reviewedById == _repo.session.userId);

  Future<void> _chooseDate() async {
    final requested = DateTime.tryParse(_date.text);
    final date = await showDatePicker(
        context: context,
        initialDate: requested != null &&
                requested.year >= 1000 &&
                requested.year <= 9999
            ? requested
            : _repo.clock(),
        firstDate: DateTime(1000),
        lastDate: DateTime(9999, 12, 31));
    if (date != null && mounted)
      setState(() => _date.text = date.toIso8601String().substring(0, 10));
  }

  String? _validateDate(String? date) {
    if (date == null ||
        !RegExp(r'^[1-9][0-9]{3}-[0-9]{2}-[0-9]{2}$').hasMatch(date))
      return 'Usa el formato AAAA-MM-DD.';
    final parsed = DateTime.tryParse(date);
    return parsed == null || parsed.toIso8601String().substring(0, 10) != date
        ? 'La fecha no existe.'
        : null;
  }

  Future<void> _save() async {
    if (_saving || !_allowed || !(_form.currentState?.validate() ?? false))
      return;
    if (_employee == null) {
      setState(() => _error = 'Selecciona un empleado de la búsqueda.');
      return;
    }
    if (_employee!['clave_empleado'] ==
        widget.item.current?['resguardante']?['clave_empleado']) {
      setState(() => _error = 'El bien ya está asignado a este resguardante.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _repo.proposeReassignment(widget.packageId, widget.item.detailId,
          employeeId: _employee!['clave_empleado'] as String,
          date: _date.text,
          departmentNumber: _department!,
          locationId: _location!,
          observations: _observations.text);
      if (mounted) {
        setState(() {
          _saving = false;
          _allowPop = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } on Object catch (error) {
      if (mounted)
        setState(() {
          _error = inventoryErrorMessage(error);
          _saving = false;
        });
    }
  }

  bool get _hasDraft =>
      _employee != null ||
      _date.text != _initialDate ||
      _observations.text != widget.observations;

  Future<void> _back(bool didPop, Object? result) async {
    if (didPop || _saving) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Propuesta sin guardar'),
                content: const Text(
                    'Los cambios de este formulario aún no están guardados.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Seguir editando')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Descartar cambios')),
                ]));
    if (accepted != true || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final matches = query.runes.length < 3
        ? <Map<String, Object?>>[]
        : _employees
            .where((employee) =>
                '${employee['nombre_completo'] ?? ''} ${employee['clave_empleado']}'
                    .toLowerCase()
                    .contains(query))
            .toList();
    return PopScope(
        canPop: !_saving && (!_hasDraft || _allowPop),
        onPopInvokedWithResult: _back,
        child: Scaffold(
            appBar: AppBar(title: const Text('Proponer reasignación')),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : Form(
                    key: _form,
                    child:
                        ListView(padding: const EdgeInsets.all(16), children: [
                      Text('Inventario ${widget.item.identity.number}',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      const Text(
                          'La propuesta se guarda sin conexión. El servidor validará el movimiento al sincronizar.'),
                      if (!_allowed)
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                                'No tienes permiso para reasignar este bien.')),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 16),
                      TextField(
                          key: const Key('buscar_empleado'),
                          controller: _search,
                          enabled: !_saving && _allowed,
                          onChanged: (_) => setState(() => _employee = null),
                          decoration: const InputDecoration(
                              labelText: 'Buscar empleado',
                              helperText:
                                  'Escribe al menos 3 caracteres del nombre o la clave.',
                              border: OutlineInputBorder())),
                      if (query.runes.length >= 3 && _employee == null) ...[
                        if (matches.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                  'Sin coincidencias en el catálogo descargado.')),
                        for (final employee in matches.take(20))
                          ListTile(
                              key:
                                  Key('empleado_${employee['clave_empleado']}'),
                              title: Text(
                                  employee['nombre_completo'] as String? ??
                                      'Empleado ${employee['clave_empleado']}'),
                              subtitle:
                                  Text('Clave ${employee['clave_empleado']}'),
                              leading: const Icon(Icons.person_outline),
                              onTap: _saving || !_allowed
                                  ? null
                                  : () => setState(() {
                                        _employee = employee;
                                        final department =
                                            employee['numero_departamento']
                                                as String?;
                                        if (_departments.any((d) =>
                                                d['numero_departamento'] ==
                                                department) &&
                                            _locations.any((l) =>
                                                l['numero_departamento'] ==
                                                department)) {
                                          _department = department;
                                          _location = null;
                                        }
                                      })),
                        if (matches.length > 20)
                          const Text(
                              'Afina la búsqueda para ver más coincidencias.')
                      ],
                      if (_employee != null)
                        ListTile(
                            leading: const Icon(Icons.check_circle,
                                color: Colors.teal),
                            title: Text(
                                _employee!['nombre_completo'] as String? ??
                                    'Empleado ${_employee!['clave_empleado']}'),
                            subtitle:
                                Text('Clave ${_employee!['clave_empleado']}')),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                          key: ValueKey('departamento_${_department ?? ''}'),
                          initialValue: _department,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'Departamento destino',
                              border: OutlineInputBorder()),
                          items: _departments
                              .map((d) => DropdownMenuItem(
                                  value: d['numero_departamento'] as String,
                                  child: Text(
                                      d['descripcion'] as String? ??
                                          'Departamento ${d['numero_departamento']}',
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: _saving || !_allowed
                              ? null
                              : (value) => setState(() {
                                    _department = value;
                                    _location = null;
                                  }),
                          validator: (value) => value == null
                              ? 'Selecciona el departamento destino.'
                              : null),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                          key: ValueKey(
                              'ubicacion_${_department ?? ''}_${_location ?? ''}'),
                          initialValue: _location,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'Ubicación destino',
                              border: OutlineInputBorder()),
                          items: _destinations
                              .map((l) => DropdownMenuItem(
                                  value: l['id'] as String,
                                  child: Text(
                                      l['descripcion'] as String? ??
                                          'Ubicación ${l['id']}',
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: _saving || !_allowed
                              ? null
                              : (value) => setState(() => _location = value),
                          validator: (value) => value == null
                              ? 'Selecciona la ubicación destino.'
                              : null),
                      const SizedBox(height: 16),
                      TextFormField(
                          key: const Key('fecha_resguardo'),
                          controller: _date,
                          onChanged: (_) => setState(() {}),
                          enabled: !_saving && _allowed,
                          validator: _validateDate,
                          decoration: InputDecoration(
                              labelText: 'Fecha de resguardo (AAAA-MM-DD)',
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                  tooltip: 'Elegir fecha',
                                  onPressed:
                                      _saving || !_allowed ? null : _chooseDate,
                                  icon: const Icon(Icons.calendar_month)))),
                      const SizedBox(height: 16),
                      TextFormField(
                          key: const Key('observaciones_reasignacion'),
                          controller: _observations,
                          onChanged: (_) => setState(() {}),
                          enabled: !_saving && _allowed,
                          maxLength: 5000,
                          maxLines: 3,
                          decoration: const InputDecoration(
                              labelText: 'Observaciones',
                              border: OutlineInputBorder())),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                          key: const Key('guardar_reasignacion'),
                          onPressed: _saving || !_allowed ? null : _save,
                          icon: const Icon(Icons.save_outlined),
                          label: Text(
                              _saving ? 'Guardando…' : 'Guardar propuesta'))
                    ]))));
  }
}
