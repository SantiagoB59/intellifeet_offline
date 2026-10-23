import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/network/inspecciones_api.dart';
import '../../core/storage/preoperacional_local_db.dart';
import '../autenticacion/auth_service.dart';
import '../autenticacion/login_page.dart';
import 'cierre_preoperacional_page.dart';
import 'inicio_preoperacional_dialog.dart';
import 'preoperacional_page.dart';
import 'sincronizacion_service.dart';

/// Pantalla principal después del inicio de sesión.
///
/// Permite seleccionar un activo y una plantilla, diligenciar
/// inspecciones offline, registrar el cierre y sincronizar.
///
/// Los datos locales se consultan y modifican únicamente
/// dentro del contexto del usuario autenticado.
class HomePage extends StatefulWidget {
  final Map<String, dynamic> usuario;
  final bool modoOffline;

  const HomePage({super.key, required this.usuario, this.modoOffline = false});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _auth = AuthService();
  final _api = InspeccionesApi();
  final _connectivity = ConnectivityService();

  final _baseLocal = PreoperacionalLocalDb.instance;
  final _sincronizacionService = SincronizacionService();

  StreamSubscription<bool>? _suscripcionConexion;

  Map<String, dynamic>? _configuracion;
  Map<String, dynamic>? _activoSeleccionado;
  Map<String, dynamic>? _plantillaSeleccionada;

  List<Map<String, dynamic>> _inspeccionesLocales = [];

  bool _enLinea = true;
  bool _cargando = false;
  bool _sincronizando = false;

  String? _error;
  String? _mensaje;
  int _anomaliasPendientes = 0;

  /// ID de la cuenta que inició sesión.
  ///
  /// Si no existe o no es válido, las operaciones locales
  /// protegidas deben detenerse.
  int? get _usuarioId {
    final id = int.tryParse(widget.usuario['id']?.toString() ?? '');

    if (id == null || id <= 0) {
      return null;
    }

    return id;
  }

  String get _nombreOperador =>
      widget.usuario['nombre']?.toString() ??
      widget.usuario['username']?.toString() ??
      'Operador';

  int get _pendientesSincronizar {
    final inspeccionesPendientes = _inspeccionesLocales.where((inspeccion) {
      final estado = inspeccion['estado']?.toString();
      final avanceSincronizado = inspeccion['avance_sincronizado'] == 1;

      final avancePendiente =
          !avanceSincronizado &&
          (estado == PreoperacionalLocalDb.estadoPendiente ||
              estado == PreoperacionalLocalDb.estadoSincronizadoParcial ||
              estado == PreoperacionalLocalDb.estadoPreguntasCompletadas);

      final cierrePendiente =
          estado == PreoperacionalLocalDb.estadoCerradaPendienteSync;

      return avancePendiente || cierrePendiente;
    }).length;

    return inspeccionesPendientes + _anomaliasPendientes;
  }

  List<Map<String, dynamic>> get _activos {
    final lista = _configuracion?['activos'];
    if (lista is! List) return [];

    return lista
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<Map<String, dynamic>> get _plantillas {
    final lista = _configuracion?['plantillas'];
    if (lista is! List) return [];

    return lista
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _inicializar();
  }

  @override
  void dispose() {
    _suscripcionConexion?.cancel();
    super.dispose();
  }

  Future<void> _inicializar() async {
    final usuarioId = _usuarioId;

    if (usuarioId == null) {
      if (mounted) {
        setState(() {
          _error =
              'No se pudo identificar al usuario autenticado. '
              'Cierra sesión e ingresa nuevamente.';
        });
      }
      return;
    }

    try {
      _enLinea = await _connectivity.hayConexion();

      _suscripcionConexion = _connectivity.cambiosConexion.listen((enLinea) {
        if (!mounted) return;

        setState(() => _enLinea = enLinea);

        if (enLinea) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Conexión restablecida. Ya puedes sincronizar '
                'los avances y las inspecciones cerradas.',
              ),
              duration: Duration(seconds: 3),
            ),
          );
        }
      });

      await _cargarConfiguracionLocal();
      await _cargarInspeccionesLocales();

      // Descargar la configuración si no existe una caché
      // correspondiente a la cuenta que inició sesión.
      if (_enLinea && _configuracion == null) {
        await _descargarConfiguracion(silencioso: true);
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error =
            'No se pudo inicializar la aplicación: '
            '${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  // ==========================================================
  // CONFIGURACIÓN: ACTIVOS Y PLANTILLAS
  // ==========================================================

  Future<void> _cargarConfiguracionLocal() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return;

    try {
      final cache = await _baseLocal.obtenerConfiguracion(usuarioId: usuarioId);

      if (!mounted) return;

      setState(() {
        _configuracion = cache;
        _seleccionarPrimeraOpcionValida();
      });
    } catch (_) {
      // La caché es opcional. El usuario puede descargar
      // la configuración cuando tenga conexión.
    }
  }

  Future<void> _descargarConfiguracion({bool silencioso = false}) async {
    final usuarioId = _usuarioId;

    if (usuarioId == null) {
      if (mounted) {
        setState(() {
          _error =
              'No se pudo identificar al usuario autenticado. '
              'Vuelve a iniciar sesión.';
        });
      }
      return;
    }

    final token = await _auth.obtenerToken();

    if (!mounted) return;

    if (token == null || token.isEmpty) {
      setState(() {
        _error =
            'La sesión no tiene un token válido. Cierra sesión '
            'e ingresa nuevamente con internet.';
      });
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
      if (!silencioso) _mensaje = null;
    });

    try {
      // 1. Descargar la configuración.
      final resultado = await _api.obtenerConfiguracion(token: token);

      if (!mounted) return;

      final data = resultado['data'] ?? resultado;

      if (data is! Map ||
          data['activos'] is! List ||
          data['plantillas'] is! List) {
        throw Exception(
          'La configuración recibida no contiene activos y plantillas válidos.',
        );
      }

      final activos = (data['activos'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      final plantillas = (data['plantillas'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      await _baseLocal.guardarConfiguracion(
        usuarioId: usuarioId,
        activos: activos,
        plantillas: plantillas,
      );

      // 2. Descargar el historial del usuario autenticado.
      final resultadoHistorial = await _api.obtenerHistorialInspecciones(
        token: token,
      );

      final dataHistorial = resultadoHistorial['data'] ?? resultadoHistorial;

      if (dataHistorial is! Map || dataHistorial['inspecciones'] is! List) {
        throw Exception('El servidor no devolvió un historial válido.');
      }

      final inspeccionesServidor = (dataHistorial['inspecciones'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      debugPrint(
        'HISTORIAL: ${inspeccionesServidor.length} inspecciones recibidas.',
      );

      // 3. Importar el historial del servidor a SQLite.
      final importadas = await _baseLocal.importarHistorialServidor(
        usuarioId: usuarioId,
        inspecciones: inspeccionesServidor,
      );

      // 4. Recargar el historial local.
      await _cargarInspeccionesLocales();

      debugPrint('HISTORIAL: $importadas inspecciones importadas.');

      final cache = await _baseLocal.obtenerConfiguracion(usuarioId: usuarioId);

      if (!mounted) return;

      setState(() {
        _configuracion = cache;
        _seleccionarPrimeraOpcionValida();
        _mensaje =
            'Configuración actualizada. '
            'Historial recibido: ${inspeccionesServidor.length}. '
            'Nuevas inspecciones importadas: $importadas.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  void _seleccionarPrimeraOpcionValida() {
    final activos = _activos;
    final activoActual = _activoSeleccionado;

    final activoValido =
        activoActual != null &&
        activos.any(
          (activo) =>
              activo['id']?.toString() == activoActual['id']?.toString() &&
              activo['tipo']?.toString() == activoActual['tipo']?.toString(),
        );

    if (!activoValido) {
      _activoSeleccionado = activos.isNotEmpty ? activos.first : null;
      _plantillaSeleccionada = null;
    }

    final activo = _activoSeleccionado;

    if (activo == null) {
      _plantillaSeleccionada = null;
      return;
    }

    final plantillaActual = _plantillaSeleccionada;

    final plantillaValida =
        plantillaActual != null &&
        _plantillas.any(
          (plantilla) =>
              plantilla['id']?.toString() ==
                  plantillaActual['id']?.toString() &&
              plantilla['activa'] == true &&
              plantilla['tipo_activo']?.toString() ==
                  activo['tipo']?.toString() &&
              (activo['tipo'] != 'VEHICULO' ||
                  plantilla['tipo_vehiculo_id']?.toString() ==
                      activo['tipo_id']?.toString()) &&
              (activo['tipo'] != 'MAQUINARIA' ||
                  plantilla['tipo_maquinaria_id']?.toString() ==
                      activo['tipo_id']?.toString()),
        );

    if (!plantillaValida) {
      _plantillaSeleccionada = _buscarPlantillaParaActivo(activo);
    }
  }

  Map<String, dynamic>? _buscarPlantillaParaActivo(
    Map<String, dynamic> activo,
  ) {
    for (final plantilla in _plantillas) {
      if (plantilla['activa'] != true) continue;

      if (plantilla['tipo_activo'] != activo['tipo']) continue;

      if (activo['tipo'] == 'MAQUINARIA' &&
          plantilla['tipo_maquinaria_id']?.toString() !=
              activo['tipo_id']?.toString()) {
        continue;
      }

      if (activo['tipo'] == 'VEHICULO' &&
          plantilla['tipo_vehiculo_id']?.toString() !=
              activo['tipo_id']?.toString()) {
        continue;
      }

      return plantilla;
    }

    return null;
  }

  // ==========================================================
  // INSPECCIONES LOCALES
  // ==========================================================

  Future<void> _cargarInspeccionesLocales() async {
    final usuarioId = _usuarioId;

    if (usuarioId == null) {
      if (!mounted) return;

      setState(() {
        _inspeccionesLocales = [];
        _anomaliasPendientes = 0;
        _error = 'No se pudo identificar al usuario autenticado.';
      });
      return;
    }

    try {
      final inspecciones = await _baseLocal.obtenerInspeccionesLocales(
        usuarioId: usuarioId,
      );

      final anomaliasPendientes = await _baseLocal
          .contarAnomaliasPendientesSync(usuarioId: usuarioId);

      for (final inspeccion in inspecciones) {
        debugPrint(
          'DEBUG PENDIENTES: '
          'id=${inspeccion['id']}, '
          'estado=${inspeccion['estado']}',
        );
      }

      debugPrint('DEBUG ANOMALIAS PENDIENTES: $anomaliasPendientes');

      if (!mounted) return;

      setState(() {
        _inspeccionesLocales = inspecciones;
        _anomaliasPendientes = anomaliasPendientes;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _inspeccionesLocales = [];
        _error =
            'No se pudieron cargar los datos locales: '
            '${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  Map<String, dynamic>? _obtenerInspeccionDelDia({
    required Map<String, dynamic> activo,
    required Map<String, dynamic> plantilla,
  }) {
    final ahora = DateTime.now();
    final hoy = DateTime(ahora.year, ahora.month, ahora.day);

    // Esta lista ya está filtrada por el usuario autenticado.
    for (final inspeccion in _inspeccionesLocales) {
      final activoInspeccion =
          (inspeccion['activo'] as Map?)?.cast<String, dynamic>() ?? {};

      final plantillaInspeccion =
          (inspeccion['plantilla'] as Map?)?.cast<String, dynamic>() ?? {};

      final mismoActivo =
          activoInspeccion['id']?.toString() == activo['id']?.toString() &&
          activoInspeccion['tipo']?.toString() == activo['tipo']?.toString();

      final mismaPlantilla =
          plantillaInspeccion['id']?.toString() == plantilla['id']?.toString();

      if (!mismoActivo || !mismaPlantilla) continue;

      final fechaRaw =
          inspeccion['fecha_inicio'] ??
          inspeccion['fecha_creacion'] ??
          inspeccion['creado_en'] ??
          inspeccion['actualizado_en'];

      if (fechaRaw == null) continue;

      final fecha = DateTime.tryParse(fechaRaw.toString());
      if (fecha == null) continue;

      final fechaLocal = fecha.toLocal();
      final diaInspeccion = DateTime(
        fechaLocal.year,
        fechaLocal.month,
        fechaLocal.day,
      );

      if (diaInspeccion == hoy) {
        return inspeccion;
      }
    }

    return null;
  }

  void _seleccionarActivo(Map<String, dynamic> activo) {
    setState(() {
      _activoSeleccionado = activo;
      _plantillaSeleccionada = _buscarPlantillaParaActivo(activo);
      _error = null;
      _mensaje = 'Activo seleccionado: ${activo['nombre']}.';
    });
  }

  void _seleccionarPlantilla(Map<String, dynamic> plantilla) {
    setState(() {
      _plantillaSeleccionada = plantilla;
      _mensaje = 'Plantilla seleccionada: ${plantilla['nombre']}.';
      _error = null;
    });
  }

  /// Convierte el valor almacenado en SQLite en bytes utilizables.
  Uint8List? _convertirFoto(dynamic valor) {
    if (valor is Uint8List) return valor;
    if (valor is List<int>) return Uint8List.fromList(valor);
    return null;
  }

  // ==========================================================
  // INICIAR O CONTINUAR PREOPERACIONAL
  // ==========================================================

  Future<void> _comenzarPreoperacional() async {
    final usuarioId = _usuarioId;

    if (usuarioId == null) {
      setState(() {
        _error =
            'No se pudo identificar al usuario autenticado. '
            'Vuelve a iniciar sesión.';
      });
      return;
    }

    if (_activoSeleccionado == null || _plantillaSeleccionada == null) {
      setState(() {
        _error = 'Selecciona un activo y una plantilla compatible.';
      });
      return;
    }

    setState(() {
      _error = null;
      _mensaje = null;
      _cargando = true;
    });

    final activo = Map<String, dynamic>.from(_activoSeleccionado!);
    final plantilla = Map<String, dynamic>.from(_plantillaSeleccionada!);

    try {
      // Buscar un borrador perteneciente a la cuenta activa.
      final borrador = await _baseLocal.obtenerBorradorPorActivoPlantilla(
        usuarioId: usuarioId,
        activo: activo,
        plantilla: plantilla,
      );

      if (!mounted) return;

      Map<String, dynamic>? datosInicio;
      String? idLocal;
      Map<String, dynamic>? borradorParaPagina;

      if (borrador != null) {
        final foto = _convertirFoto(borrador['foto_inicial']);

        datosInicio = {
          'lecturaInicial': borrador['lectura_inicial'],
          'fotoBytes': foto,
          'capturadaEn': borrador['foto_capturada_en'],
        };

        idLocal = borrador['id']?.toString();
        borradorParaPagina = borrador;

        setState(() {
          _mensaje =
              'Se encontró una inspección pendiente. '
              'Se recuperará el borrador guardado.';
        });
      } else {
        datosInicio = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => InicioPreoperacionalDialog(
            activo: activo,
            plantilla: plantilla,
            operadorNombre: _nombreOperador,
          ),
        );

        if (!mounted || datosInicio == null) return;
      }

      final datos = datosInicio;

      final lecturaInicial = datos['lecturaInicial'];
      final fotoInicial = _convertirFoto(datos['fotoBytes']);
      final fechaCaptura = datos['capturadaEn']?.toString();

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreoperacionalPage(
            usuarioId: usuarioId,
            activo: {
              ...activo,
              'lectura_inicial': lecturaInicial,
              'foto_inicial_bytes': fotoInicial,
              'foto_inicial_capturada_en': fechaCaptura,
            },
            plantilla: plantilla,
            idLocal: idLocal,
            borrador: borradorParaPagina,
          ),
        ),
      );

      await _cargarInspeccionesLocales();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error =
            'No se pudo abrir el preoperacional: '
            '${e.toString().replaceFirst('Exception: ', '')}';
      });
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  /// Reabre un borrador local de la cuenta autenticada.
  Future<void> _continuarBorrador(Map<String, dynamic> inspeccion) async {
    final usuarioId = _usuarioId;
    final id = inspeccion['id']?.toString();

    if (usuarioId == null) {
      setState(() {
        _error = 'No se pudo identificar al usuario autenticado.';
      });
      return;
    }

    if (id == null || id.isEmpty) return;

    setState(() {
      _cargando = true;
      _error = null;
    });

    try {
      // No recuperar un detalle sin filtrar por usuario.
      final detalle = await _baseLocal.obtenerDetallePorId(
        id: id,
        usuarioId: usuarioId,
      );

      if (!mounted) return;

      if (detalle == null) {
        throw Exception(
          'No se encontró el borrador de este usuario en el dispositivo.',
        );
      }

      final activo = (detalle['activo'] as Map?)?.cast<String, dynamic>() ?? {};

      final plantilla =
          (detalle['plantilla'] as Map?)?.cast<String, dynamic>() ?? {};

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreoperacionalPage(
            usuarioId: usuarioId,
            activo: {
              ...activo,
              'lectura_inicial': detalle['lectura_inicial'],
              'foto_inicial_bytes': _convertirFoto(detalle['foto_inicial']),
              'foto_inicial_capturada_en': detalle['foto_capturada_en'],
            },
            plantilla: plantilla,
            idLocal: id,
            borrador: detalle,
          ),
        ),
      );

      await _cargarInspeccionesLocales();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  /// Genera un UUID v4 para identificar la anomalía localmente y al sincronizar.
  String _generarUuidV4() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Abre un formulario independiente para reportar una anomalía
  /// asociada a una inspección que ya completó sus preguntas.
  Future<void> _reportarAnomalia(Map<String, dynamic> inspeccion) async {
    final usuarioId = _usuarioId;
    final inspeccionId = inspeccion['id']?.toString();

    if (usuarioId == null || inspeccionId == null || inspeccionId.isEmpty) {
      setState(() {
        _error = 'No se pudo identificar el usuario o la inspección.';
      });
      return;
    }

    final tituloController = TextEditingController();
    final descripcionController = TextEditingController();
    final picker = ImagePicker();
    final fotos = <Uint8List>[];
    String prioridad = 'MEDIA';
    bool guardando = false;
    String? errorFormulario;

    Future<void> agregarFoto(ImageSource source, StateSetter actualizar) async {
      try {
        if (source == ImageSource.camera) {
          final foto = await picker.pickImage(
            source: ImageSource.camera,
            imageQuality: 75,
            maxWidth: 1600,
          );
          if (foto != null) {
            final bytes = await foto.readAsBytes();
            if (fotos.length < 5) fotos.add(bytes);
          }
        } else {
          final seleccionadas = await picker.pickMultiImage(
            imageQuality: 75,
            maxWidth: 1600,
          );
          for (final foto in seleccionadas) {
            if (fotos.length >= 5) break;
            fotos.add(await foto.readAsBytes());
          }
        }
        actualizar(() => errorFormulario = null);
      } catch (e) {
        actualizar(
          () => errorFormulario = 'No se pudieron cargar las fotos: $e',
        );
      }
    }

    try {
      final guardada = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, actualizar) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.report_problem_outlined, color: Color(0xFFB45309)),
                SizedBox(width: 10),
                Expanded(child: Text('Reportar anomalía')),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Inspección: ${inspeccion['id']}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: tituloController,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Título de la anomalía *',
                        hintText: 'Ej. Luz trasera dañada',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descripcionController,
                      maxLines: 3,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Descripción *',
                        hintText: 'Describe la novedad encontrada',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: prioridad,
                      decoration: const InputDecoration(
                        labelText: 'Prioridad',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'BAJA', child: Text('Baja')),
                        DropdownMenuItem(value: 'MEDIA', child: Text('Media')),
                        DropdownMenuItem(value: 'ALTA', child: Text('Alta')),
                        DropdownMenuItem(
                          value: 'CRITICA',
                          child: Text('Crítica'),
                        ),
                      ],
                      onChanged: guardando
                          ? null
                          : (valor) =>
                                actualizar(() => prioridad = valor ?? 'MEDIA'),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Fotografías (máximo 5)',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Tomar fotografía',
                          onPressed: guardando || fotos.length >= 5
                              ? null
                              : () =>
                                    agregarFoto(ImageSource.camera, actualizar),
                          icon: const Icon(Icons.photo_camera_outlined),
                        ),
                        IconButton(
                          tooltip: 'Seleccionar fotografías',
                          onPressed: guardando || fotos.length >= 5
                              ? null
                              : () => agregarFoto(
                                  ImageSource.gallery,
                                  actualizar,
                                ),
                          icon: const Icon(Icons.photo_library_outlined),
                        ),
                      ],
                    ),
                    if (fotos.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < fotos.length; i++)
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    fotos[i],
                                    width: 76,
                                    height: 76,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: IconButton.filledTonal(
                                    tooltip: 'Quitar fotografía',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: guardando
                                        ? null
                                        : () => actualizar(
                                            () => fotos.removeAt(i),
                                          ),
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                    if (errorFormulario != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorFormulario!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: guardando
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: guardando
                    ? null
                    : () async {
                        final titulo = tituloController.text.trim();
                        final descripcion = descripcionController.text.trim();
                        if (titulo.isEmpty || descripcion.isEmpty) {
                          actualizar(
                            () => errorFormulario =
                                'Completa el título y la descripción.',
                          );
                          return;
                        }

                        actualizar(() {
                          guardando = true;
                          errorFormulario = null;
                        });

                        try {
                          final uuid = _generarUuidV4();
                          await _baseLocal.guardarAnomaliaLocal(
                            id: uuid,
                            inspeccionId: inspeccionId,
                            usuarioId: usuarioId,
                            uuidSync: uuid,
                            titulo: titulo,
                            descripcion: descripcion,
                            prioridad: prioridad,
                            fotos: List<Uint8List>.from(fotos),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          actualizar(() {
                            guardando = false;
                            errorFormulario =
                                'No se pudo guardar la anomalía: $e';
                          });
                        }
                      },
                icon: guardando
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(guardando ? 'Guardando...' : 'Guardar anomalía'),
              ),
            ],
          ),
        ),
      );

      if (!mounted) return;

      if (guardada == true) {
        await _cargarInspeccionesLocales();

        if (!mounted) return;

        setState(() {
          _mensaje = 'Anomalía guardada en el dispositivo. Se podrá sincronizar después.';
          _error = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Anomalía guardada localmente.')),
        );
      }
    } finally {
      tituloController.dispose();
      descripcionController.dispose();
    }
  }

  /// Abre el cierre de una inspección del usuario autenticado.
  Future<void> _registrarCierre(Map<String, dynamic> inspeccion) async {
    final usuarioId = _usuarioId;
    final id = inspeccion['id']?.toString();

    if (usuarioId == null) {
      setState(() {
        _error = 'No se pudo identificar al usuario autenticado.';
      });
      return;
    }

    if (id == null || id.isEmpty) return;

    final cerrada = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CierrePreoperacionalPage(
          idLocal: id,
          usuarioId: usuarioId,
          operadorNombre: _nombreOperador,
        ),
      ),
    );

    if (cerrada == true) {
      await _cargarInspeccionesLocales();
    }
  }

  Future<void> _sincronizarPendientes() async {
    if (_sincronizando) return;

    final usuarioId = _usuarioId;

    if (usuarioId == null) {
      setState(() {
        _error = 'No se pudo identificar al usuario autenticado.';
      });
      return;
    }

    if (!_enLinea) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sin conexión: las inspecciones se sincronizarán '
            'cuando tengas internet.',
          ),
        ),
      );
      return;
    }

    if (widget.modoOffline) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sesión sin conexión'),
          content: const Text(
            'Entraste con las credenciales guardadas. Para sincronizar, '
            'cierra sesión e ingresa de nuevo con internet.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _sincronizando = true;
      _error = null;
      _mensaje = null;
    });

    try {
      final resultado = await _sincronizacionService.sincronizarPendientes(
        usuarioId: usuarioId,
      );

      // Recargar primero para que la interfaz use los estados actuales.
      await _cargarInspeccionesLocales();

      if (!mounted) return;

      final total = resultado['total'] as int? ?? 0;
      final sincronizados = resultado['sincronizados'] as int? ?? 0;
      final fallidos = resultado['fallidos'] as int? ?? 0;
      final errores = resultado['errores'];

      setState(() {
        _mensaje = fallidos == 0
            ? 'Sincronización completada. '
                  'Avances enviados: $sincronizados.'
            : 'La sincronización terminó con $fallidos elemento(s) fallido(s).';
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Resultado de sincronización'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Elementos procesados: $total'),
                Text('Sincronizados: $sincronizados'),
                Text('Fallidos: $fallidos'),
                const SizedBox(height: 10),
                const Text(
                  'Los avances pueden quedar en proceso en el servidor '
                  'hasta que registres el cierre definitivo.',
                ),
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
                      child: Text('${error['mensaje']}'),
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

  Future<void> _cerrarSesion() async {
    await _auth.cerrarSesion();

    if (!mounted) return;

    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (ruta) => false,
    );
  }

  // ==========================================================
  // INTERFAZ - DISEÑO CORPORATIVO INTELLIFEET
  // ==========================================================

  static const Color _navy = Color(0xFF101B33);
  static const Color _blue = Color(0xFF2457A7);
  static const Color _gold = Color(0xFFD5AD48);
  static const Color _background = Color(0xFFF3F6FB);
  static const Color _muted = Color(0xFF718096);
  static const Color _border = Color(0xFFE5EAF2);

  @override
  Widget build(BuildContext context) {
    final activoActual = _activoSeleccionado;
    final plantillaActual = _plantillaSeleccionada;

    final inspeccionHoy = activoActual != null && plantillaActual != null
        ? _obtenerInspeccionDelDia(
            activo: activoActual,
            plantilla: plantillaActual,
          )
        : null;

    final estadoInspeccionHoy = inspeccionHoy?['estado']?.toString();

    final puedeContinuarHoy =
        estadoInspeccionHoy == PreoperacionalLocalDb.estadoPendiente ||
        estadoInspeccionHoy == PreoperacionalLocalDb.estadoSincronizadoParcial;

    final inspeccionDeHoyBloqueada =
        inspeccionHoy != null && !puedeContinuarHoy;

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                Icons.local_shipping_rounded,
                color: _navy,
                size: 23,
              ),
            ),
            const SizedBox(width: 11),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IntelliFeet',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 19,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  'GESTIÓN DE FLOTA',
                  style: TextStyle(
                    color: Color(0xFFCAD3E3),
                    fontSize: 9,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sincronizar inspecciones',
            onPressed: _sincronizando ? null : _sincronizarPendientes,
            icon: _sincronizando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.sync_rounded, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: _cerrarSesion,
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 30),
              children: [
                _construirEncabezadoPrincipal(),
                const SizedBox(height: 18),
                _construirBannerConexion(),
                const SizedBox(height: 16),
                _construirResumenInspecciones(),
                const SizedBox(height: 22),
                _construirTarjetaConfiguracion(),

                if (_configuracion != null) ...[
                  const SizedBox(height: 28),
                  _seccionTitulo(
                    'Mis activos',
                    'Selecciona el vehículo o maquinaria que vas a inspeccionar.',
                    icono: Icons.directions_car_filled_outlined,
                  ),
                  const SizedBox(height: 12),
                  if (_activos.isEmpty)
                    _mensajeVacio(
                      'No tienes activos asignados.',
                      icono: Icons.directions_car_outlined,
                    )
                  else
                    ..._activos.map(_construirTarjetaActivo),

                  const SizedBox(height: 24),
                  _seccionTitulo(
                    'Plantillas disponibles',
                    'Elige el formato de inspección correspondiente al activo.',
                    icono: Icons.fact_check_outlined,
                  ),
                  const SizedBox(height: 12),
                  if (_plantillasCompatibles().isEmpty)
                    _mensajeVacio(
                      'No hay plantillas disponibles para este activo.',
                      icono: Icons.assignment_outlined,
                    )
                  else
                    ..._plantillasCompatibles().map(_construirTarjetaPlantilla),

                  const SizedBox(height: 8),
                  _construirBotonComenzar(
                    puedeContinuarHoy: puedeContinuarHoy,
                    inspeccionDeHoyBloqueada: inspeccionDeHoyBloqueada,
                  ),
                ],

                const SizedBox(height: 30),
                _construirSeccionInspecciones(),
                const SizedBox(height: 16),
                _construirBotonSincronizar(),

                if (_mensaje != null) ...[
                  const SizedBox(height: 16),
                  _construirAviso(_mensaje!, esError: false),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _construirAviso(_error!, esError: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  // ENCABEZADO Y RESUMEN
  // ----------------------------------------------------------

  Widget _construirEncabezadoPrincipal() {
    final iniciales = _nombreOperador
        .trim()
        .split(RegExp(r'\s+'))
        .where((parte) => parte.isNotEmpty)
        .take(2)
        .map((parte) => parte[0].toUpperCase())
        .join();

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF101B33), Color(0xFF1B3156)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _navy.withValues(alpha: 0.13),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PANEL DEL OPERADOR',
                      style: TextStyle(
                        color: Color(0xFFD5AD48),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      'Hola, $_nombreOperador',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'Gestiona tus inspecciones preoperacionales.',
                      style: TextStyle(
                        color: Color(0xFFD0D9E8),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: Text(
                  iniciales.isEmpty ? 'OP' : iniciales,
                  style: const TextStyle(
                    color: Color(0xFFD5AD48),
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.14)),
          const SizedBox(height: 13),
          Row(
            children: [
              Icon(
                Icons.person_outline_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${widget.usuario['username'] ?? _nombreOperador}'
                  '  •  ${widget.usuario['rol'] ?? 'Operador'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFD0D9E8),
                    fontSize: 11,
                  ),
                ),
              ),
              if (widget.modoOffline)
                _construirEtiqueta(
                  'SESIÓN OFFLINE',
                  const Color(0xFFFFE8B0),
                  const Color(0xFF6B4D0D),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _construirResumenInspecciones() {
    final total = _inspeccionesLocales.length;
    final pendientes = _pendientesSincronizar;
    final completadas = _inspeccionesLocales.where((inspeccion) {
      return inspeccion['estado'] == PreoperacionalLocalDb.estadoSincronizado;
    }).length;

    return Row(
      children: [
        Expanded(
          child: _construirIndicador(
            icono: Icons.assignment_outlined,
            etiqueta: 'Registradas',
            valor: '$total',
            color: _blue,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _construirIndicador(
            icono: Icons.cloud_upload_outlined,
            etiqueta: 'Pendientes',
            valor: '$pendientes',
            color: const Color(0xFFB17A13),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _construirIndicador(
            icono: Icons.check_circle_outline_rounded,
            etiqueta: 'Sincronizadas',
            valor: '$completadas',
            color: const Color(0xFF258052),
          ),
        ),
      ],
    );
  }

  Widget _construirIndicador({
    required IconData icono,
    required String etiqueta,
    required String valor,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: color, size: 21),
          const SizedBox(height: 12),
          Text(
            valor,
            style: const TextStyle(
              color: _navy,
              fontSize: 23,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            etiqueta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _muted,
              fontSize: 10,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // CONEXIÓN Y CONFIGURACIÓN OFFLINE
  // ----------------------------------------------------------

  Widget _construirBannerConexion() {
    final fondo = _enLinea ? const Color(0xFFEAF7EF) : const Color(0xFFFFF5DF);

    final color = _enLinea ? const Color(0xFF237749) : const Color(0xFF98680B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 39,
            height: 39,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _enLinea ? Icons.wifi_rounded : Icons.wifi_off_rounded,
              color: color,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _enLinea ? 'Conexión disponible' : 'Trabajando sin conexión',
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _enLinea
                      ? 'Puedes actualizar tus datos y sincronizar.'
                      : 'Tus avances se guardan en este dispositivo.',
                  style: TextStyle(color: color, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }

  Widget _construirTarjetaConfiguracion() {
    final descargadoEn = _configuracion?['descargado_en']?.toString();
    final descargada = descargadoEn != null && descargadoEn.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF0FC),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.cloud_download_outlined,
                  color: _blue,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Datos para trabajar offline',
                      style: TextStyle(
                        color: _navy,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Activos y plantillas de tu cuenta',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(
                descargada
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: descargada
                    ? const Color(0xFF258052)
                    : const Color(0xFFB17A13),
                size: 22,
              ),
            ],
          ),
          const SizedBox(height: 15),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              descargada
                  ? 'Configuración guardada en el dispositivo.\n'
                        'Última actualización: $descargadoEn'
                  : 'Descarga tus activos y plantillas para poder trabajar '
                        'sin conexión.',
              style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 48,
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _blue,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFDDE3EC),
                disabledForegroundColor: const Color(0xFF7A8494),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _cargando || !_enLinea
                  ? null
                  : () => _descargarConfiguracion(),
              icon: _cargando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync_rounded, size: 19),
              label: Text(
                _cargando
                    ? 'Actualizando datos...'
                    : _enLinea
                    ? 'Actualizar desde el servidor'
                    : 'Sin conexión a internet',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // ACTIVOS Y PLANTILLAS
  // ----------------------------------------------------------

  Widget _construirTarjetaActivo(Map<String, dynamic> activo) {
    final seleccionado =
        activo['id']?.toString() == _activoSeleccionado?['id']?.toString() &&
        activo['tipo']?.toString() == _activoSeleccionado?['tipo']?.toString();

    final maquinaria = activo['tipo'] == 'MAQUINARIA';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: seleccionado ? _gold : _border,
          width: seleccionado ? 1.8 : 1,
        ),
        boxShadow: seleccionado
            ? [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.10),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: _cargando ? null : () => _seleccionarActivo(activo),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              children: [
                Container(
                  width: 53,
                  height: 53,
                  decoration: BoxDecoration(
                    color: seleccionado
                        ? const Color(0xFFFFF3D0)
                        : const Color(0xFFEAF0FC),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    maquinaria
                        ? Icons.construction_rounded
                        : Icons.local_shipping_rounded,
                    color: seleccionado ? _navy : _blue,
                    size: 27,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activo['nombre']?.toString() ?? 'Activo',
                        style: const TextStyle(
                          color: _navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        maquinaria ? 'MAQUINARIA' : 'VEHÍCULO',
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(
                            Icons.speed_rounded,
                            size: 15,
                            color: _blue,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Lectura actual: '
                              '${activo['lectura_actual'] ?? 'No disponible'}'
                              '${maquinaria ? ' h' : ' km'}',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  seleccionado
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: seleccionado ? _gold : const Color(0xFFBBC4D1),
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _plantillasCompatibles() {
    final activo = _activoSeleccionado;

    return _plantillas.where((plantilla) {
      if (plantilla['activa'] != true) return false;
      if (activo == null) return true;

      if (plantilla['tipo_activo'] != activo['tipo']) return false;

      if (activo['tipo'] == 'MAQUINARIA') {
        return plantilla['tipo_maquinaria_id']?.toString() ==
            activo['tipo_id']?.toString();
      }

      if (activo['tipo'] == 'VEHICULO') {
        return plantilla['tipo_vehiculo_id']?.toString() ==
            activo['tipo_id']?.toString();
      }

      return true;
    }).toList();
  }

  Widget _construirTarjetaPlantilla(Map<String, dynamic> plantilla) {
    final seleccionada =
        plantilla['id']?.toString() ==
        _plantillaSeleccionada?['id']?.toString();

    final categorias = plantilla['categorias'] as List? ?? [];

    final preguntas = categorias.fold<int>(
      0,
      (total, categoria) =>
          total +
          ((categoria is Map && categoria['items'] is List)
              ? (categoria['items'] as List).length
              : 0),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: seleccionada ? _gold : _border,
          width: seleccionada ? 1.8 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: _cargando ? null : () => _seleccionarPlantilla(plantilla),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 47,
                  height: 47,
                  decoration: BoxDecoration(
                    color: seleccionada
                        ? const Color(0xFFFFF3D0)
                        : const Color(0xFFEAF0FC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.fact_check_outlined,
                    color: seleccionada ? _navy : _blue,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plantilla['nombre']?.toString() ?? 'Plantilla',
                        style: const TextStyle(
                          color: _navy,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if ((plantilla['descripcion']?.toString() ?? '')
                          .isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          plantilla['descripcion'].toString(),
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          _construirEtiqueta(
                            '$preguntas preguntas',
                            const Color(0xFFEAF0FC),
                            _blue,
                          ),
                          _construirEtiqueta(
                            '${categorias.length} categorías',
                            const Color(0xFFF0F2F6),
                            _muted,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Lectura: '
                        '${plantilla['tipo_medicion'] ?? 'No especificada'}',
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                Icon(
                  seleccionada
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: seleccionada ? _gold : const Color(0xFFBBC4D1),
                  size: 23,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _construirBotonComenzar({
    required bool puedeContinuarHoy,
    required bool inspeccionDeHoyBloqueada,
  }) {
    final deshabilitado =
        _cargando ||
        _activoSeleccionado == null ||
        _plantillaSeleccionada == null ||
        inspeccionDeHoyBloqueada;

    final texto = _cargando
        ? 'Preparando inspección...'
        : puedeContinuarHoy
        ? 'Continuar inspección de hoy'
        : inspeccionDeHoyBloqueada
        ? 'Inspección de hoy ya registrada'
        : 'Comenzar preoperacional';

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _navy,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFDDE3EC),
          disabledForegroundColor: const Color(0xFF7A8494),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        onPressed: deshabilitado ? null : _comenzarPreoperacional,
        icon: _cargando
            ? const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                puedeContinuarHoy
                    ? Icons.play_circle_outline_rounded
                    : inspeccionDeHoyBloqueada
                    ? Icons.check_circle_outline_rounded
                    : Icons.play_arrow_rounded,
              ),
        label: Text(
          texto,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  // INSPECCIONES LOCALES
  // ----------------------------------------------------------

  Widget _construirSeccionInspecciones() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _seccionTitulo(
          'Mis inspecciones',
          'Consulta el avance de tus revisiones en este dispositivo.',
          icono: Icons.history_rounded,
        ),
        const SizedBox(height: 12),
        if (_inspeccionesLocales.isEmpty)
          _mensajeVacio(
            'Todavía no tienes inspecciones en este dispositivo.',
            icono: Icons.assignment_outlined,
          )
        else
          ..._inspeccionesLocales.map(_construirTarjetaInspeccion),
      ],
    );
  }

  Widget _construirTarjetaInspeccion(Map<String, dynamic> inspeccion) {
    final estado = inspeccion['estado']?.toString() ?? '';

    final activo =
        (inspeccion['activo'] as Map?)?.cast<String, dynamic>() ?? {};

    final plantilla =
        (inspeccion['plantilla'] as Map?)?.cast<String, dynamic>() ?? {};

    final (
      String etiqueta,
      Color color,
      Color fondo,
      IconData icono,
    ) = switch (estado) {
      PreoperacionalLocalDb.estadoPendiente => (
        'En progreso',
        const Color(0xFF2457A7),
        const Color(0xFFEAF0FC),
        Icons.edit_note_rounded,
      ),
      PreoperacionalLocalDb.estadoSincronizadoParcial => (
        'Avance sincronizado',
        const Color(0xFF2457A7),
        const Color(0xFFEAF0FC),
        Icons.cloud_done_outlined,
      ),
      PreoperacionalLocalDb.estadoPreguntasCompletadas => (
        'Pendiente de cierre',
        const Color(0xFF98680B),
        const Color(0xFFFFF5DF),
        Icons.pending_actions_rounded,
      ),
      PreoperacionalLocalDb.estadoCerradaPendienteSync => (
        'Pendiente de envío',
        const Color(0xFF7044A0),
        const Color(0xFFF1EAF9),
        Icons.cloud_upload_outlined,
      ),
      PreoperacionalLocalDb.estadoSincronizado => (
        'Sincronizada',
        const Color(0xFF237749),
        const Color(0xFFEAF7EF),
        Icons.check_circle_outline_rounded,
      ),
      _ => (
        'Estado desconocido',
        const Color(0xFF718096),
        const Color(0xFFF0F2F6),
        Icons.help_outline_rounded,
      ),
    };

    final puedeContinuar =
        estado == PreoperacionalLocalDb.estadoPendiente ||
        estado == PreoperacionalLocalDb.estadoSincronizadoParcial;

    final necesitaCierre =
        estado == PreoperacionalLocalDb.estadoPreguntasCompletadas;

    final necesitaSync =
        estado == PreoperacionalLocalDb.estadoCerradaPendienteSync;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: fondo,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icono, color: color, size: 23),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activo['nombre']?.toString() ?? 'Activo',
                      style: const TextStyle(
                        color: _navy,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      plantilla['nombre']?.toString() ?? 'Inspección',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(child: _construirEtiqueta(etiqueta, fondo, color)),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.update_rounded, color: _muted, size: 15),
                const SizedBox(width: 7),
                const Text(
                  'Última actualización',
                  style: TextStyle(color: _muted, fontSize: 10),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    inspeccion['actualizado_en']?.toString() ?? 'Sin fecha',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: _navy,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (puedeContinuar || necesitaCierre || necesitaSync) ...[
            const SizedBox(height: 12),
            if (puedeContinuar)
              SizedBox(
                width: double.infinity,
                height: 45,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _blue,
                    side: const BorderSide(color: Color(0xFFCAD7EF)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _cargando
                      ? null
                      : () => _continuarBorrador(inspeccion),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text(
                    'Continuar diligenciando',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              )
            else if (necesitaCierre)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: _navy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _cargando
                            ? null
                            : () => _registrarCierre(inspeccion),
                        icon: const Icon(Icons.draw_outlined, size: 18),
                        label: const Text(
                          'Cerrar preoperacional',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB45309),
                          side: const BorderSide(color: Color(0xFFF2C078)),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _cargando
                            ? null
                            : () => _reportarAnomalia(inspeccion),
                        icon: const Icon(
                          Icons.report_problem_outlined,
                          size: 18,
                        ),
                        label: const Text(
                          'Reportar anomalía',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Icon(
                    _enLinea
                        ? Icons.cloud_upload_outlined
                        : Icons.wifi_off_rounded,
                    color: color,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _enLinea
                          ? 'Lista para enviar. Usa el botón de sincronización.'
                          : 'Se enviará cuando recuperes la conexión.',
                      style: TextStyle(color: color, fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // SINCRONIZACIÓN
  // ----------------------------------------------------------

  Widget _construirBotonSincronizar() {
    final pendientes = _pendientesSincronizar;
    final deshabilitado = _sincronizando || pendientes == 0 || !_enLinea;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _navy.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.sync_rounded,
                  color: Color(0xFFD5AD48),
                  size: 25,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sincronización',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Mantén tus registros actualizados.',
                      style: TextStyle(color: Color(0xFFCAD3E3), fontSize: 11),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$pendientes',
                  style: const TextStyle(
                    color: _navy,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          SizedBox(
            width: double.infinity,
            height: 49,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: _navy,
                disabledBackgroundColor: const Color(0xFF35435C),
                disabledForegroundColor: const Color(0xFFB8C1D0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              onPressed: deshabilitado ? null : _sincronizarPendientes,
              icon: _sincronizando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _navy,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined, size: 20),
              label: Text(
                _sincronizando
                    ? 'Sincronizando inspecciones...'
                    : pendientes == 0
                    ? 'No hay inspecciones pendientes'
                    : !_enLinea
                    ? 'Esperando conexión'
                    : 'Sincronizar inspecciones',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: Color(0xFFD5AD48),
                size: 16,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Los avances se envían sin cerrar la inspección. '
                  'La lectura final y la firma se registran al completar '
                  'el proceso de cierre.',
                  style: TextStyle(
                    color: Color(0xFFCAD3E3),
                    fontSize: 10,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // COMPONENTES COMPARTIDOS
  // ----------------------------------------------------------

  Widget _seccionTitulo(
    String titulo,
    String subtitulo, {
    IconData icono = Icons.circle_outlined,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 39,
          height: 39,
          decoration: BoxDecoration(
            color: const Color(0xFFE7EDF9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icono, color: _blue, size: 21),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: const TextStyle(
                  color: _navy,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitulo,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _construirEtiqueta(String texto, Color fondo, Color colorTexto) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: colorTexto,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _mensajeVacio(
    String texto, {
    IconData icono = Icons.info_outline_rounded,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Icon(icono, size: 32, color: const Color(0xFFA5B0C0)),
          const SizedBox(height: 10),
          Text(
            texto,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _construirAviso(String texto, {required bool esError}) {
    final color = esError ? const Color(0xFFB42318) : const Color(0xFF237749);

    final fondo = esError ? const Color(0xFFFFEFED) : const Color(0xFFEAF7EF);

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            esError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            color: color,
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(color: color, fontSize: 12, height: 1.5),
            ),
          ),
          if (esError)
            IconButton(
              tooltip: 'Cerrar mensaje',
              onPressed: () {
                setState(() => _error = null);
              },
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              icon: Icon(Icons.close_rounded, color: color, size: 17),
            ),
        ],
      ),
    );
  }
}
