import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/network/inspecciones_api.dart';
import '../../core/storage/preoperacional_local_db.dart';
import '../autenticacion/auth_service.dart';

class SincronizacionService {
  SincronizacionService({
    InspeccionesApi? api,
    PreoperacionalLocalDb? baseLocal,
    AuthService? authService,
  }) : _api = api ?? InspeccionesApi(),
       _baseLocal = baseLocal ?? PreoperacionalLocalDb.instance,
       _authService = authService ?? AuthService();

  final InspeccionesApi _api;
  final PreoperacionalLocalDb _baseLocal;
  final AuthService _authService;

  bool _sincronizando = false;

  /// Sincroniza primero los avances parciales y después los cierres.
  ///
  /// Cada operación local queda limitada al usuario autenticado.
  /// Los avances parciales permanecen abiertos en el servidor.
  /// Únicamente las inspecciones cerradas localmente ejecutan
  /// el flujo definitivo de cierre.
  Future<Map<String, dynamic>> sincronizarPendientes({
    required int usuarioId,
  }) async {
    if (usuarioId <= 0) {
      throw ArgumentError.value(
        usuarioId,
        'usuarioId',
        'Debe ser un identificador válido.',
      );
    }

    if (_sincronizando) {
      return {
        'total': 0,
        'sincronizados': 0,
        'fallidos': 0,
        'errores': <Map<String, String>>[],
        'ocupado': true,
      };
    }

    _sincronizando = true;

    try {
      final token = await _authService.obtenerToken();

      if (token == null || token.trim().isEmpty) {
        throw Exception(
          'No hay una sesión activa. Inicia sesión con internet '
          'para sincronizar.',
        );
      }

      // Solo obtiene inspecciones pertenecientes a esta cuenta.
      final parciales = await _baseLocal.obtenerPendientesSincronizacionParcial(
        usuarioId: usuarioId,
      );

      final cerradas = await _baseLocal.obtenerCerradasPendientesSync(
        usuarioId: usuarioId,
      );

      int sincronizados = 0;
      int fallidos = 0;

      final errores = <Map<String, String>>[];

      // Primero se envían los avances que todavía están abiertos.
      for (final fila in parciales) {
        final idLocal = fila['id']?.toString() ?? '';

        try {
          await _sincronizarAvanceParcial(
            token: token,
            fila: fila,
            usuarioId: usuarioId,
          );
          sincronizados++;
        } catch (e) {
          print('ERROR SINCRONIZANDO INSPECCIÓN PARCIAL [$idLocal]: $e');
          fallidos++;
          errores.add({
            'id': idLocal,
            'tipo': 'PARCIAL',
            'mensaje': _mensajeError(e),
          });
        }
      }

      // El cierre definitivo sigue siendo un proceso independiente.
      for (final fila in cerradas) {
        final idLocal = fila['id']?.toString() ?? '';

        try {
          await _sincronizarCierreDefinitivo(
            token: token,
            fila: fila,
            usuarioId: usuarioId,
          );
          sincronizados++;
        } catch (e) {
          print('ERROR SINCRONIZANDO CIERRE [$idLocal]: $e');
          fallidos++;
          errores.add({
            'id': idLocal,
            'tipo': 'CIERRE',
            'mensaje': _mensajeError(e),
          });
        }
      }

      // Sincronizar anomalías después de procesar los avances y cierres.
      try {
        final resultadoAnomalias = await _sincronizarAnomaliasPendientes(
          token: token,
          usuarioId: usuarioId,
        );

        sincronizados += resultadoAnomalias['sincronizadas'] as int;
        fallidos += resultadoAnomalias['fallidas'] as int;

        final erroresAnomalias =
            resultadoAnomalias['errores'] as List<Map<String, String>>;

        errores.addAll(erroresAnomalias);
      } catch (e) {
        print('ERROR GENERAL SINCRONIZANDO ANOMALÍAS: $e');

        fallidos++;

        errores.add({
          'id': 'anomalias',
          'tipo': 'ANOMALIA',
          'mensaje': _mensajeError(e),
        });
      }
      print(
        'RESUMEN SYNC: total=${parciales.length + cerradas.length}, '
        'sincronizados=$sincronizados, fallidos=$fallidos',
      );
      return {
        'total': parciales.length + cerradas.length,
        'sincronizados': sincronizados,
        'fallidos': fallidos,
        'errores': errores,
      };
    } finally {
      _sincronizando = false;
    }
  }
  // ==========================================================
  // SINCRONIZACIÓN INDEPENDIENTE DE ANOMALÍAS
  // ==========================================================

  Future<Map<String, dynamic>> _sincronizarAnomaliasPendientes({
    required String token,
    required int usuarioId,
  }) async {
    int sincronizadas = 0;
    int fallidas = 0;

    final errores = <Map<String, String>>[];

    // Este método debe devolver todas las anomalías pendientes
    // del usuario, incluidas las de inspecciones ya sincronizadas.
    final anomalias = await _baseLocal.obtenerAnomaliasPendientesSyncUsuario(
      usuarioId: usuarioId,
    );

    for (final anomalia in anomalias) {
      final anomaliaId = anomalia['id']?.toString() ?? '';

      try {
        final uuidInspeccion =
            anomalia['uuid_inspeccion']?.toString().trim() ?? '';

        final uuidAnomalia = anomalia['uuid_sync']?.toString().trim() ?? '';

        if (anomaliaId.isEmpty) {
          throw Exception('La anomalía no tiene un identificador local.');
        }

        if (!_esUuidValido(uuidInspeccion)) {
          throw Exception('La inspección asociada no tiene un UUID válido.');
        }

        if (!_esUuidValido(uuidAnomalia)) {
          throw Exception(
            'La anomalía no tiene un UUID de sincronización válido.',
          );
        }

        // Cada anomalía lleva únicamente sus propias fotografías.
        final fotografias = <String, List<int>>{};
        final fotosPayload = <Map<String, dynamic>>[];

        final fotosLocales = anomalia['fotos'];

        if (fotosLocales is List) {
          for (var i = 0; i < fotosLocales.length; i++) {
            final foto = fotosLocales[i];

            if (foto is! Map) {
              throw Exception(
                'Una fotografía de la anomalía tiene un formato inválido.',
              );
            }

            final bytes = _bytesDe(foto['foto']);

            if (bytes == null || bytes.isEmpty) {
              throw Exception('Una fotografía de la anomalía está vacía.');
            }

            final archivoKey =
                'anomalia_${uuidAnomalia.replaceAll('-', '')}_foto_$i';

            fotografias[archivoKey] = bytes;

            fotosPayload.add({'archivo_key': archivoKey});
          }
        }

        final payload = <String, dynamic>{
          'uuid_sync': uuidAnomalia,
          'uuid_inspeccion': uuidInspeccion,
          'titulo': anomalia['titulo']?.toString().trim() ?? '',
          'descripcion': anomalia['descripcion']?.toString() ?? '',
          'prioridad': (anomalia['prioridad']?.toString() ?? 'MEDIA')
              .toUpperCase(),
          'fotos': fotosPayload,
        };

        // Envía exclusivamente la anomalía y sus fotografías.
        final resultado = await _api.sincronizarAnomalia(
          token: token,
          uuidInspeccion: uuidInspeccion,
          payload: payload,
          fotografias: fotografias,
        );

        // No marcar como sincronizada si el servidor no confirma
        // ambos UUID mediante la respuesta del método API.
        if (resultado['uuid_anomalia']?.toString() != uuidAnomalia ||
            resultado['uuid_inspeccion']?.toString() != uuidInspeccion) {
          throw Exception(
            'El servidor no confirmó la anomalía y su inspección asociada.',
          );
        }

        await _baseLocal.marcarAnomaliaSincronizada(
          id: anomaliaId,
          usuarioId: usuarioId,
        );

        sincronizadas++;

        print(
          'ANOMALÍA SINCRONIZADA: $anomaliaId '
          '(UUID: $uuidAnomalia)',
        );
      } catch (e) {
        print('ERROR SINCRONIZANDO ANOMALÍA [$anomaliaId]: $e');

        fallidas++;

        errores.add({
          'id': anomaliaId,
          'tipo': 'ANOMALIA',
          'mensaje': _mensajeError(e),
        });

        // No cambiar el estado local: permanece pendiente para reintentar.
      }
    }

    return {
      'total': anomalias.length,
      'sincronizadas': sincronizadas,
      'fallidas': fallidas,
      'errores': errores,
    };
  }
  // ==========================================================
  // SINCRONIZACIÓN PARCIAL
  // ==========================================================

  /// Envía el progreso de una inspección sin finalizarla.
  ///
  /// No ejecuta finalizarInspeccion() ni registrarLecturaFinal().
  Future<void> _sincronizarAvanceParcial({
    required String token,
    required Map<String, Object?> fila,
    required int usuarioId,
  }) async {
    final idLocal = fila['id']?.toString() ?? '';

    if (idLocal.isEmpty) {
      throw Exception('La inspección no tiene un identificador local.');
    }

    final resultado = await _subirAvance(
      token: token,
      fila: fila,
      usuarioId: usuarioId,
    );

    print('RESPUESTA DEL SERVIDOR: $resultado');
    print('ID LOCAL DE INSPECCIÓN: $idLocal');

    final estado = resultado['estado']?.toString() ?? '';

    print('ESTADO DEVUELTO POR EL SERVIDOR: $estado');

    if (estado == 'ANULADA') {
      throw Exception(
        'La inspección fue anulada en el servidor. '
        'Comunícate con el supervisor.',
      );
    }

    if (estado == 'FINALIZADA' || estado == 'REVISADA') {
      throw Exception(
        'El servidor indica que la inspección ya está cerrada, '
        'pero el registro local todavía requiere sincronización parcial. '
        'Verifica el estado con el servidor antes de continuar.',
      );
    }

    if (estado == 'PENDIENTE_CIERRE') {
      throw Exception(
        'El servidor indica que la inspección está pendiente de cierre. '
        'No se modificó el cierre desde la sincronización parcial.',
      );
    }

    // Solo modifica el registro perteneciente al usuario actual.
    await _baseLocal.marcarSincronizadoParcial(
      id: idLocal,
      usuarioId: usuarioId,
    );
  }

  // ==========================================================
  // SINCRONIZACIÓN DEFINITIVA
  // ==========================================================

  /// Envía una inspección cerrada localmente y completa el cierre remoto.
  Future<void> _sincronizarCierreDefinitivo({
    required String token,
    required Map<String, Object?> fila,
    required int usuarioId,
  }) async {
    final idLocal = fila['id']?.toString() ?? '';

    if (idLocal.isEmpty) {
      throw Exception('La inspección no tiene un identificador local.');
    }

    final resultado = await _subirAvance(
      token: token,
      fila: fila,
      usuarioId: usuarioId,
    );

    final estado = resultado['estado']?.toString() ?? '';
    final yaProcesada = resultado['ya_procesada'] == true;

    final inspeccionId = int.tryParse(
      resultado['inspeccion_id']?.toString() ?? '',
    );

    // Un reintento puede encontrar una inspección ya finalizada.
    if (estado == 'FINALIZADA' || estado == 'REVISADA') {
      await _baseLocal.marcarSincronizado(id: idLocal, usuarioId: usuarioId);
      return;
    }

    if (estado == 'ANULADA') {
      throw Exception(
        'La inspección fue anulada en el servidor. '
        'Comunícate con el supervisor.',
      );
    }

    if (inspeccionId == null) {
      throw Exception('El servidor no devolvió el ID de la inspección.');
    }

    // Evita repetir una transición ya procesada.
    if (!(yaProcesada && estado == 'PENDIENTE_CIERRE')) {
      await _api.finalizarInspeccion(token: token, inspeccionId: inspeccionId);
    }

    final lecturaFinal = fila['lectura_final'];
    final fotoFinal = _bytesDe(fila['foto_final']);
    final firma = _bytesDe(fila['firma']);

    if (lecturaFinal == null ||
        fotoFinal == null ||
        fotoFinal.isEmpty ||
        firma == null ||
        firma.isEmpty) {
      throw Exception(
        'El cierre local está incompleto: falta la lectura final, '
        'la fotografía o la firma.',
      );
    }

    final consentimientoAceptado =
        fila['consentimiento_aceptado'] == 1 ||
        fila['consentimiento_aceptado'] == true;

    final confirmaFirma =
        fila['confirma_firma'] == 1 || fila['confirma_firma'] == true;

    if (!consentimientoAceptado || !confirmaFirma) {
      throw Exception(
        'El cierre local no contiene las confirmaciones requeridas.',
      );
    }

    await _api.registrarLecturaFinal(
      token: token,
      inspeccionId: inspeccionId,
      lecturaFinal: lecturaFinal as num,
      fotoFinal: fotoFinal,
      firmaPng: firma,
    );

    await _baseLocal.marcarSincronizado(id: idLocal, usuarioId: usuarioId);
  }

  // ==========================================================
  // ENVÍO COMÚN DEL AVANCE
  // ==========================================================

  /// Construye el payload y envía la inspección al servidor.
  ///
  /// No ejecuta el cierre definitivo.
  /// Ambos flujos utilizan el mismo UUID estable.

  Future<Map<String, dynamic>> _subirAvance({
    required String token,
    required Map<String, Object?> fila,
    required int usuarioId,
  }) async {
    final idLocal = fila['id']?.toString() ?? '';

    if (idLocal.isEmpty) {
      throw Exception('La inspección no tiene un identificador local.');
    }

    var uuidSync = fila['uuid_sync']?.toString() ?? '';

    if (!_esUuidValido(uuidSync)) {
      uuidSync = _esUuidValido(idLocal) ? idLocal : _generarUuid();

      await _baseLocal.guardarUuidSync(
        idLocal: idLocal,
        uuidSync: uuidSync,
        usuarioId: usuarioId,
      );
    }

    final activo = _decodificarObjeto(fila['activo_json'], 'activo_json');

    final plantilla = _decodificarObjeto(
      fila['plantilla_json'],
      'plantilla_json',
    );

    final plantillaId = _obtenerId(plantilla, ['id', 'plantilla_id']);

    final tipo = (activo['tipo'] ?? '').toString().toUpperCase();
    final esVehiculo = tipo == 'VEHICULO';
    final esMaquinaria = tipo == 'MAQUINARIA';

    if (!esVehiculo && !esMaquinaria) {
      throw Exception(
        'El tipo de activo no es válido para sincronizar: '
        '${activo['tipo']}.',
      );
    }

    if (plantillaId == null) {
      throw Exception('La inspección no contiene un ID de plantilla.');
    }

    final activoId = _obtenerId(
      activo,
      esVehiculo ? ['vehiculo_id', 'id'] : ['maquinaria_id', 'id'],
    );

    if (activoId == null) {
      throw Exception('La inspección no contiene el ID del activo.');
    }

    // Fotografías correspondientes a la inspección y sus respuestas.
    // Las fotografías de anomalías se envían por separado.
    final fotografias = <String, List<int>>{};

    final fotoInicial = _bytesDe(fila['foto_inicial']);

    if (fotoInicial != null && fotoInicial.isNotEmpty) {
      fotografias['foto_contador_inicial'] = fotoInicial;
    }

    // Se conservan las respuestas y las fotografías de cada respuesta.
    final respuestasPayload = _construirRespuestasPayload(
      fila['respuestas_json'],
      fotografias,
    );

    // Payload exclusivo de la inspección.
    // No consultar ni agregar anomalías en esta función.
    final payload = <String, dynamic>{
      'uuid_sync': uuidSync,
      'plantilla_id': plantillaId,
      'vehiculo_id': esVehiculo ? activoId : null,
      'maquinaria_id': esMaquinaria ? activoId : null,
      'hora_inicio': fila['creado_en']?.toString(),
      'contador_inicial': fila['lectura_inicial'],
      'observaciones_generales':
          fila['observaciones_generales']?.toString() ?? '',
      'respuestas': respuestasPayload,
    };

    if (fotografias.containsKey('foto_contador_inicial')) {
      payload['foto_contador_inicial_key'] = 'foto_contador_inicial';
    }

    // Enviar la inspección sin incluir anomalías.
    final resultado = await _api.sincronizarInspeccion(
      token: token,
      payload: payload,
      fotografias: fotografias,
    );

    // Verificar el UUID de la inspección confirmado por el servidor.
    final uuidConfirmado = resultado['uuid_sync']?.toString();

    if (uuidConfirmado != uuidSync) {
      throw Exception(
        'El servidor no confirmó correctamente la inspección. '
        'UUID esperado: $uuidSync; '
        'UUID recibido: ${uuidConfirmado ?? "vacío"}.',
      );
    }

    // Verificar que el servidor haya devuelto el ID remoto.
    final inspeccionId = int.tryParse(
      resultado['inspeccion_id']?.toString() ?? '',
    );

    if (inspeccionId == null) {
      throw Exception('El servidor no devolvió un ID válido de inspección.');
    }

    // No marcar anomalías como sincronizadas aquí.
    // Tampoco reenviar sus fotografías desde esta función.
    // La sincronización independiente se encargará de ellas
    // después de procesar los avances y cierres.

    return resultado;
  }

  List<Map<String, dynamic>> _construirRespuestasPayload(
    Object? contenido,
    Map<String, List<int>> fotografias,
  ) {
    if (contenido is! String || contenido.isEmpty) {
      throw Exception('No se encontraron respuestas guardadas.');
    }

    final decoded = jsonDecode(contenido);

    if (decoded is! List) {
      throw Exception('Las respuestas locales no tienen formato de lista.');
    }

    final respuestas = <Map<String, dynamic>>[];

    for (final elemento in decoded) {
      if (elemento is! Map) continue;

      final respuesta = Map<String, dynamic>.from(elemento);
      final itemId = respuesta['item_id'] ?? respuesta['id'];

      if (itemId == null) continue;

      final valor =
          respuesta['valor']?.toString() ??
          respuesta['respuesta']?.toString() ??
          '';

      if (valor.trim().isEmpty) continue;

      final fotos = <Map<String, dynamic>>[];
      final fotosGuardadas = respuesta['fotos'];

      if (fotosGuardadas is List) {
        var indice = 0;

        for (final elementoFoto in fotosGuardadas) {
          if (elementoFoto is! Map) continue;

          final base64 = elementoFoto['foto_base64']?.toString() ?? '';

          if (base64.isEmpty) continue;

          late final Uint8List bytes;

          try {
            bytes = base64Decode(base64);
          } on FormatException {
            continue;
          }

          if (bytes.isEmpty) continue;

          indice++;

          final clave = 'foto_respuesta_${itemId}_$indice';

          fotografias[clave] = bytes;

          fotos.add({
            'archivo_key': clave,
            'fecha_dispositivo':
                elementoFoto['capturada_en']?.toString() ??
                DateTime.now().toIso8601String(),
            'watermark': true,
          });
        }
      }

      respuestas.add({
        'item_id': itemId,
        'valor': valor,
        'observacion':
            respuesta['observacion']?.toString() ??
            respuesta['observaciones']?.toString() ??
            '',
        if (fotos.isNotEmpty) 'fotos': fotos,
      });
    }

    return respuestas;
  }

  // ==========================================================
  // UTILIDADES
  // ==========================================================

  String _mensajeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  Uint8List? _bytesDe(Object? valor) {
    if (valor is Uint8List) return valor;

    if (valor is List) {
      try {
        return Uint8List.fromList(valor.cast<int>());
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  String _generarUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  bool _esUuidValido(String valor) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'[1-8][0-9a-fA-F]{3}-'
      r'[89aAbB][0-9a-fA-F]{3}-'
      r'[0-9a-fA-F]{12}$',
    ).hasMatch(valor);
  }

  Map<String, dynamic> _decodificarObjeto(
    Object? contenido,
    String nombreCampo,
  ) {
    if (contenido is! String || contenido.isEmpty) {
      throw Exception('El campo local $nombreCampo está vacío.');
    }

    final decoded = jsonDecode(contenido);

    if (decoded is! Map) {
      throw Exception('El campo local $nombreCampo no es un objeto JSON.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  int? _obtenerId(Map<String, dynamic> objeto, List<String> claves) {
    for (final clave in claves) {
      final valor = objeto[clave];

      if (valor == null) continue;

      final id = int.tryParse(valor.toString());

      if (id != null && id > 0) {
        return id;
      }
    }

    return null;
  }
}
