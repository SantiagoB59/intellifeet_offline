import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/storage/preoperacional_local_db.dart';
import 'sincronizacion_service.dart';

class PreoperacionalPage extends StatefulWidget {
  final Map<String, dynamic> activo;
  final Map<String, dynamic> plantilla;
  final String? idLocal;
  final Map<String, dynamic>? borrador;

  const PreoperacionalPage({
    super.key,
    required this.activo,
    required this.plantilla,
    this.idLocal,
    this.borrador,
  });

  @override
  State<PreoperacionalPage> createState() => _PreoperacionalPageState();
}

class _PreoperacionalPageState extends State<PreoperacionalPage> {
  final Map<int, String> _respuestas = {};
  final Map<int, TextEditingController> _observaciones = {};
  final Map<int, List<Map<String, dynamic>>> _fotosPreguntas = {};

  static const int _maxFotosPorPregunta = 3;

  final ImagePicker _imagePicker = ImagePicker();

  bool _preguntasCompletadas = false;
  bool _guardando = false;
  bool _guardandoLocal = false;
  bool _sincronizando = false;
  bool _cerrada = false;
  bool _cargandoEstado = true;

  String _idLocal = '';
  String _estadoGuardado = 'Preparando inspección...';

  bool get _soloLectura => _cerrada || _cargandoEstado || _preguntasCompletadas;

  String get _tipoMedicion =>
      widget.plantilla['tipo_medicion']?.toString().toUpperCase() ?? 'NINGUNO';

  String get _unidad => _tipoMedicion == 'HOROMETRO' ? 'h' : 'km';

  @override
  void initState() {
    super.initState();

    _idLocal = widget.idLocal ?? _generarUuid();
    _restaurarBorrador();
    _inicializarEstadoLocal();
  }

  String _generarUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  Future<void> _inicializarEstadoLocal() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _cargandoEstado = false;
          _estadoGuardado = 'El almacenamiento local requiere Android.';
        });
      }
      return;
    }

    try {
      final registro = await PreoperacionalLocalDb.instance.obtenerPorId(
        _idLocal,
      );

      if (!mounted) return;

      if (registro != null) {
        final estado = registro['estado']?.toString() ?? '';

        if (estado == PreoperacionalLocalDb.estadoCerradaPendienteSync ||
            estado == PreoperacionalLocalDb.estadoSincronizado) {
          setState(() {
            _cerrada = true;
            _estadoGuardado = estado == PreoperacionalLocalDb.estadoSincronizado
                ? 'Inspección sincronizada'
                : 'Finalizada; pendiente de sincronización';
          });
        } else if (estado == PreoperacionalLocalDb.estadoPreguntasCompletadas) {
          setState(() {
            _preguntasCompletadas = true;
            _estadoGuardado = 'Cuestionario completado; cierre pendiente';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _estadoGuardado = 'No se pudo consultar el estado local: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _cargandoEstado = false);
      }
    }

    if (!_cerrada && !_preguntasCompletadas) {
      await _guardarBorradorLocal();
    }
  }

  String _formatearFechaHora(DateTime fecha) {
    final local = fecha.toLocal();

    final dia = local.day.toString().padLeft(2, '0');
    final mes = local.month.toString().padLeft(2, '0');
    final anio = local.year.toString();
    final hora = local.hour.toString().padLeft(2, '0');
    final minuto = local.minute.toString().padLeft(2, '0');
    final segundo = local.second.toString().padLeft(2, '0');

    return '$dia/$mes/$anio $hora:$minuto:$segundo';
  }

  void _restaurarBorrador() {
    final borrador = widget.borrador;
    if (borrador == null) return;

    final respuestasGuardadas = borrador['respuestas'];

    if (respuestasGuardadas is List) {
      for (final elemento in respuestasGuardadas) {
        if (elemento is! Map) continue;

        final dato = Map<String, dynamic>.from(elemento);
        final id = int.tryParse(dato['item_id']?.toString() ?? '');

        if (id == null) continue;

        final respuesta = dato['respuesta']?.toString();

        if (respuesta != null && respuesta.isNotEmpty) {
          _respuestas[id] = respuesta;
        }

        final observacion = dato['observacion']?.toString() ?? '';

        if (observacion.isNotEmpty) {
          _controlObservacion(id).text = observacion;
        }

        final fotosRestauradas = <Map<String, dynamic>>[];
        final fotosGuardadas = dato['fotos'];

        if (fotosGuardadas is List) {
          for (final elementoFoto in fotosGuardadas.take(
            _maxFotosPorPregunta,
          )) {
            if (elementoFoto is! Map) continue;

            final fotoDato = Map<String, dynamic>.from(elementoFoto);
            final base64 = fotoDato['foto_base64']?.toString();

            if (base64 == null || base64.isEmpty) continue;

            try {
              fotosRestauradas.add({
                'bytes': base64Decode(base64),
                'capturada_en':
                    fotoDato['capturada_en']?.toString() ??
                    DateTime.now().toIso8601String(),
              });
            } catch (e) {
              debugPrint('Error al restaurar una foto de la pregunta $id: $e');
            }
          }
        } else {
          final fotoBase64 = dato['foto_base64']?.toString();

          if (fotoBase64 != null && fotoBase64.isNotEmpty) {
            try {
              fotosRestauradas.add({
                'bytes': base64Decode(fotoBase64),
                'capturada_en': DateTime.now().toIso8601String(),
              });
            } catch (e) {
              debugPrint('Error al restaurar foto de pregunta $id: $e');
            }
          }
        }

        if (fotosRestauradas.isNotEmpty) {
          _fotosPreguntas[id] = fotosRestauradas;
        }
      }
    }

    _estadoGuardado = 'Borrador recuperado del dispositivo';
  }

  List<Map<String, dynamic>> get _categorias {
    final raw = widget.plantilla['categorias'];
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> _itemsDe(Map<String, dynamic> categoria) {
    final raw = categoria['items'];
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  int get _totalPreguntas => _categorias.fold<int>(
    0,
    (total, categoria) => total + _itemsDe(categoria).length,
  );

  int get _respondidas =>
      _respuestas.values.where((respuesta) => respuesta.isNotEmpty).length;

  TextEditingController _controlObservacion(int id) =>
      _observaciones.putIfAbsent(id, () => TextEditingController());

  bool _esObligatorio(Map<String, dynamic> item) => item['obligatorio'] == true;

  bool _permiteNa(Map<String, dynamic> item) => item['permite_na'] == true;

  bool _requiereFoto(Map<String, dynamic> item) {
    final id = int.tryParse(item['id']?.toString() ?? '');

    return item['requiere_foto'] == true ||
        (item['foto_si_falla'] == true &&
            id != null &&
            _respuestas[id] == 'NO');
  }

  bool _requiereObservacion(Map<String, dynamic> item) {
    final id = int.tryParse(item['id']?.toString() ?? '');

    return item['requiere_observacion'] == true &&
        id != null &&
        _respuestas[id] == 'NO';
  }

  num _obtenerLecturaInicial() {
    final valor =
        widget.activo['lectura_inicial'] ?? widget.activo['lectura_actual'];

    if (valor is num) return valor;

    return num.tryParse(valor?.toString().replaceAll(',', '.') ?? '') ?? 0;
  }

  List<Map<String, dynamic>> _construirRespuestas() {
    final resultado = <Map<String, dynamic>>[];

    for (final categoria in _categorias) {
      for (final item in _itemsDe(categoria)) {
        final id = int.tryParse(item['id']?.toString() ?? '');
        if (id == null) continue;

        final fotos = _fotosPreguntas[id] ?? [];

        resultado.add({
          'item_id': id,
          'categoria_id': categoria['id'],
          'respuesta': _respuestas[id],
          'observacion': _observaciones[id]?.text.trim() ?? '',
          'fotos': fotos.map((foto) {
            final bytes = foto['bytes'] as Uint8List;

            return {
              'foto_base64': base64Encode(bytes),
              'capturada_en': foto['capturada_en'],
            };
          }).toList(),
          'foto_base64': fotos.isNotEmpty
              ? base64Encode(fotos.first['bytes'] as Uint8List)
              : null,
        });
      }
    }

    return resultado;
  }

  Future<bool> _guardarBorradorLocal() async {
    if (kIsWeb || _cerrada || _preguntasCompletadas || _cargandoEstado) {
      return false;
    }

    if (_guardandoLocal) return false;

    _guardandoLocal = true;

    try {
      final activoSinFoto = Map<String, dynamic>.from(widget.activo)
        ..remove('foto_inicial_bytes');

      final foto = widget.activo['foto_inicial_bytes'];

      final Uint8List? fotoInicial = foto is Uint8List
          ? foto
          : foto is List<int>
          ? Uint8List.fromList(foto)
          : null;

      await PreoperacionalLocalDb.instance.guardarBorrador(
        id: _idLocal,
        activo: activoSinFoto,
        plantilla: widget.plantilla,
        lecturaInicial: _obtenerLecturaInicial(),
        respuestas: _construirRespuestas(),
        fotoInicial: fotoInicial,
        fotoCapturadaEn: widget.activo['foto_inicial_capturada_en']?.toString(),
      );

      if (mounted) {
        setState(() {
          _estadoGuardado = 'Borrador guardado en este dispositivo';
        });
      }

      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _estadoGuardado = 'Error al guardar el borrador';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar localmente: $e')),
        );
      }

      return false;
    } finally {
      _guardandoLocal = false;
    }
  }

  Future<void> _tomarFotoPregunta(int id) async {
    if (_soloLectura || _guardando) return;

    final fotosActuales = _fotosPreguntas[id] ?? [];

    if (fotosActuales.length >= _maxFotosPorPregunta) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Esta pregunta ya tiene las 3 fotografías permitidas.'),
        ),
      );
      return;
    }

    try {
      final archivo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (archivo == null || !mounted) return;

      final bytes = await archivo.readAsBytes();

      if (bytes.isEmpty) {
        throw Exception('La fotografía está vacía.');
      }

      final fechaCaptura = DateTime.now().toIso8601String();

      setState(() {
        final fotos = List<Map<String, dynamic>>.from(
          _fotosPreguntas[id] ?? [],
        );

        if (fotos.length < _maxFotosPorPregunta) {
          fotos.add({'bytes': bytes, 'capturada_en': fechaCaptura});

          _fotosPreguntas[id] = fotos;
        }
      });

      final guardado = await _guardarBorradorLocal();

      if (!guardado && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'La foto se capturó, pero no se pudo guardar el borrador.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo capturar la fotografía: $e')),
      );
    }
  }

  Future<void> _eliminarFotoPregunta(int id, int indice) async {
    if (_soloLectura || _guardando) return;

    final fotos = List<Map<String, dynamic>>.from(_fotosPreguntas[id] ?? []);

    if (indice < 0 || indice >= fotos.length) return;

    setState(() {
      fotos.removeAt(indice);

      if (fotos.isEmpty) {
        _fotosPreguntas.remove(id);
      } else {
        _fotosPreguntas[id] = fotos;
      }
    });

    await _guardarBorradorLocal();
  }

  Future<void> _mostrarPendientes(List<String> pendientes) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Faltan datos'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Completa los siguientes campos antes de continuar:',
                ),
                const SizedBox(height: 12),
                ...pendientes
                    .take(12)
                    .map(
                      (pendiente) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $pendiente'),
                      ),
                    ),
                if (pendientes.length > 12)
                  Text('Y ${pendientes.length - 12} campos más.'),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Volver'),
          ),
        ],
      ),
    );
  }

  Future<void> _finalizarRevision() async {
    if (_soloLectura || _guardando) return;

    final pendientes = <String>[];

    for (final categoria in _categorias) {
      for (final item in _itemsDe(categoria)) {
        final id = int.tryParse(item['id']?.toString() ?? '');
        if (id == null) continue;

        final etiqueta =
            item['codigo']?.toString() ??
            item['descripcion']?.toString() ??
            'Pregunta $id';

        final respuesta = _respuestas[id];

        if (_esObligatorio(item) && (respuesta == null || respuesta.isEmpty)) {
          pendientes.add(etiqueta);
          continue;
        }

        if (_requiereObservacion(item) &&
            (_observaciones[id]?.text.trim().isEmpty ?? true)) {
          pendientes.add('Observación: $etiqueta');
        }

        if (_requiereFoto(item) && (_fotosPreguntas[id] ?? []).isEmpty) {
          pendientes.add('Fotografía obligatoria: $etiqueta');
        }
      }
    }

    if (pendientes.isNotEmpty) {
      await _mostrarPendientes(pendientes);
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finalizar cuestionario'),
        content: const Text(
          'Se guardarán las respuestas de esta inspección. '
          'La lectura final y la firma se registrarán después '
          'desde el menú principal. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Continuar revisando'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Guardar y volver'),
          ),
        ],
      ),
    );

    if (confirmar != true || !mounted) return;

    setState(() => _guardando = true);

    try {
      final borradorGuardado = await _guardarBorradorLocal();

      if (!borradorGuardado) {
        throw Exception(
          'No se pudieron guardar las respuestas en el dispositivo.',
        );
      }

      await PreoperacionalLocalDb.instance.marcarPreguntasCompletadas(_idLocal);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cuestionario guardado. Continúa con la lectura final '
            'y la firma desde el menú principal.',
          ),
        ),
      );

      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar el cuestionario: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  Future<void> _sincronizarPendientes() async {
    if (_sincronizando || kIsWeb) return;

    setState(() => _sincronizando = true);

    try {
      final resultado = await SincronizacionService().sincronizarPendientes();

      if (!mounted) return;

      final total = resultado['total'] as int? ?? 0;
      final sincronizados = resultado['sincronizados'] as int? ?? 0;
      final fallidos = resultado['fallidos'] as int? ?? 0;
      final errores = resultado['errores'];

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Resultado de sincronización'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Pendientes encontrados: $total'),
                Text('Sincronizados: $sincronizados'),
                Text('Fallidos: $fallidos'),
                if (errores is List && errores.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Detalles de los errores:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ...errores.take(5).map((error) {
                    if (error is! Map) {
                      return const SizedBox.shrink();
                    }

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('${error['id']}: ${error['mensaje']}'),
                    );
                  }),
                  if (errores.length > 5)
                    Text('Y ${errores.length - 5} errores más.'),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );

      if (mounted) {
        setState(() {
          _estadoGuardado = total == 0
              ? 'No hay inspecciones pendientes'
              : fallidos == 0
              ? 'Solicitud de sincronización completada'
              : 'Hay inspecciones pendientes de sincronizar';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('No se pudo sincronizar: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _sincronizando = false);
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _observaciones.values) {
      controller.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nombreActivo = widget.activo['nombre']?.toString() ?? 'Activo';
    final lectura = _obtenerLecturaInicial();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preoperacional'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar inspecciones pendientes',
            onPressed: _sincronizando || kIsWeb ? null : _sincronizarPendientes,
            icon: _sincronizando
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: const Color(0xFF101B33),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nombreActivo,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Lectura inicial: $lectura $_unidad',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.plantilla['nombre']?.toString() ?? '',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _totalPreguntas == 0
                          ? 0
                          : (_respondidas / _totalPreguntas).clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                      color: const Color(0xFFE0B323),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Respondidas: $_respondidas de $_totalPreguntas',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _cargandoEstado
                          ? 'Consultando estado local...'
                          : _estadoGuardado,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_cerrada)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFE8F5E9),
                  padding: const EdgeInsets.all(12),
                  child: const Row(
                    children: [
                      Icon(Icons.lock, color: Colors.green),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Inspección finalizada. '
                          'El formulario está bloqueado.',
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _cargandoEstado
                    ? const Center(child: CircularProgressIndicator())
                    : _categorias.isEmpty
                    ? const Center(
                        child: Text('La plantilla no contiene categorías.'),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (!_preguntasCompletadas && !_cerrada) ...[
                            for (final categoria in _categorias)
                              _construirCategoria(categoria),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 52,
                              child: FilledButton.icon(
                                onPressed: _guardando
                                    ? null
                                    : _finalizarRevision,
                                icon: _guardando
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.check_circle_outline),
                                label: Text(
                                  _guardando
                                      ? 'Guardando...'
                                      : 'Finalizar cuestionario',
                                ),
                              ),
                            ),
                          ] else ...[
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      _cerrada
                                          ? Icons.check_circle
                                          : Icons.assignment_turned_in,
                                      size: 36,
                                      color: _cerrada
                                          ? Colors.green
                                          : const Color(0xFF101B33),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _cerrada
                                          ? 'Inspección finalizada'
                                          : 'Cuestionario completado',
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _cerrada
                                          ? 'El formulario está bloqueado.'
                                          : 'Las respuestas están guardadas. '
                                                'Continúa el cierre desde '
                                                'el menú principal.',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _construirCategoria(Map<String, dynamic> categoria) {
    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              categoria['nombre']?.toString() ?? 'Categoría',
              style: const TextStyle(
                color: Color(0xFF101B33),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            for (final item in _itemsDe(categoria)) _construirPregunta(item),
          ],
        ),
      ),
    );
  }

  Widget _construirPregunta(Map<String, dynamic> item) {
    final id = int.tryParse(item['id']?.toString() ?? '');
    if (id == null) return const SizedBox.shrink();

    final respuesta = _respuestas[id];
    final observacionController = _controlObservacion(id);
    final mostrarObservacion = _requiereObservacion(item);
    final mostrarAvisoFoto = _requiereFoto(item);

    final opciones = <String>['SI', 'NO'];
    if (_permiteNa(item)) opciones.add('NA');

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.only(bottom: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item['descripcion']?.toString() ?? 'Pregunta',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: opciones.map((opcion) {
              return ChoiceChip(
                label: Text(
                  opcion == 'SI'
                      ? 'Sí'
                      : opcion == 'NO'
                      ? 'No'
                      : 'N/A',
                ),
                selected: respuesta == opcion,
                selectedColor: const Color(0xFFFFE9A0),
                onSelected: _soloLectura || _guardando
                    ? null
                    : (seleccionado) {
                        setState(() {
                          if (seleccionado) {
                            _respuestas[id] = opcion;
                          } else {
                            _respuestas.remove(id);
                          }
                        });

                        _guardarBorradorLocal();
                      },
              );
            }).toList(),
          ),
          if (mostrarObservacion) ...[
            const SizedBox(height: 10),
            TextField(
              controller: observacionController,
              enabled: !_soloLectura && !_guardando,
              maxLines: 2,
              onChanged: (_) => _guardarBorradorLocal(),
              decoration: const InputDecoration(
                labelText: 'Describe la novedad *',
                hintText: 'Explica qué encontraste...',
                prefixIcon: Icon(Icons.notes),
              ),
            ),
          ],
          if (mostrarAvisoFoto) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Evidencias fotográficas '
                    '(${(_fotosPreguntas[id] ?? []).length}/'
                    '$_maxFotosPorPregunta)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if ((_fotosPreguntas[id] ?? []).length < _maxFotosPorPregunta)
                  OutlinedButton.icon(
                    onPressed: _soloLectura || _guardando
                        ? null
                        : () => _tomarFotoPregunta(id),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Agregar foto'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (
              var indice = 0;
              indice < (_fotosPreguntas[id] ?? []).length;
              indice++
            )
              Builder(
                builder: (context) {
                  final foto = _fotosPreguntas[id]![indice];
                  final bytes = foto['bytes'] as Uint8List;

                  final fecha = DateTime.tryParse(
                    foto['capturada_en']?.toString() ?? '',
                  );

                  final fechaTexto = fecha != null
                      ? _formatearFechaHora(fecha)
                      : 'Fecha y hora no disponibles';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.memory(
                          bytes,
                          height: 200,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return const SizedBox(
                              height: 120,
                              child: Center(
                                child: Text(
                                  'No se pudo mostrar esta fotografía.',
                                ),
                              ),
                            );
                          },
                        ),
                        Container(
                          padding: const EdgeInsets.all(10),
                          color: const Color(0xFF101B33),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.access_time,
                                color: Color(0xFFE0B323),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Foto ${indice + 1} • $fechaTexto',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              if (!_soloLectura && !_guardando)
                                IconButton(
                                  tooltip: 'Eliminar fotografía',
                                  onPressed: () =>
                                      _eliminarFotoPregunta(id, indice),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.white,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if ((_fotosPreguntas[id] ?? []).isEmpty)
              const Text(
                'Puedes adjuntar hasta 3 fotografías como evidencia.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
          ],
          if (item['bloquea_operacion'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Este ítem está marcado como crítico para la operación.',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
