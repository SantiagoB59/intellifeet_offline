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

  Future<Map<String, dynamic>> sincronizarPendientes() async {
    final token = await _authService.obtenerToken();

    if (token == null || token.trim().isEmpty) {
      throw Exception(
        'No hay una sesión activa. Inicia sesión para sincronizar.',
      );
    }

    final pendientes = await _baseLocal.obtenerPendientes();

    int sincronizados = 0;
    int fallidos = 0;

    final errores = <Map<String, String>>[];

    for (final fila in pendientes) {
      final idLocal = fila['id']?.toString() ?? '';

      try {
        if (idLocal.isEmpty) {
          throw Exception('El borrador no tiene un identificador local.');
        }

        // Reutilizar el UUID guardado o crear uno si es necesario.
        var uuidSync = fila['uuid_sync']?.toString() ?? '';

        if (!_esUuidValido(uuidSync)) {
          uuidSync = _generarUuid();
          await _baseLocal.guardarUuidSync(
            idLocal: idLocal,
            uuidSync: uuidSync,
          );
        }

        final activo = _decodificarObjeto(fila['activo_json'], 'activo_json');

        final plantilla = _decodificarObjeto(
          fila['plantilla_json'],
          'plantilla_json',
        );

        final respuestas = _decodificarRespuestas(fila['respuestas_json']);

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
          throw Exception('El borrador no contiene un ID de plantilla.');
        }

        final activoId = _obtenerId(
          activo,
          esVehiculo ? ['vehiculo_id', 'id'] : ['maquinaria_id', 'id'],
        );

        if (activoId == null) {
          throw Exception('El borrador no contiene el ID del activo.');
        }

        final payload = <String, dynamic>{
          'uuid_sync': uuidSync,
          'plantilla_id': plantillaId,
          'vehiculo_id': esVehiculo ? activoId : null,
          'maquinaria_id': esMaquinaria ? activoId : null,
          'hora_inicio': fila['creado_en']?.toString(),
          'contador_inicial': fila['lectura_inicial'],
          'observaciones_generales': '',
          'respuestas': respuestas,
          'anomalias': <Map<String, dynamic>>[],
        };

        final fotografias = <String, List<int>>{};

        final fotoGuardada = fila['foto_inicial'];

        if (fotoGuardada != null) {
          final bytes = fotoGuardada is Uint8List
              ? fotoGuardada
              : Uint8List.fromList(List<int>.from(fotoGuardada as List));

          if (bytes.isNotEmpty) {
            const claveFoto = 'foto_contador_inicial';

            payload['foto_contador_inicial_key'] = claveFoto;
            fotografias[claveFoto] = bytes;
          }
        }

        final resultado = await _api.sincronizarInspeccion(
          token: token,
          payload: payload,
          fotografias: fotografias,
        );

        final uuidConfirmado = resultado['uuid_sync']?.toString();
        final estado = resultado['estado']?.toString();

        if (uuidConfirmado != uuidSync || estado == null || estado.isEmpty) {
          throw Exception(
            'El servidor no confirmó correctamente la inspección. '
            'UUID esperado: $uuidSync; '
            'UUID recibido: ${uuidConfirmado ?? "vacío"}.',
          );
        }

        await _baseLocal.marcarSincronizado(idLocal);

        sincronizados++;
      } catch (e) {
        fallidos++;

        errores.add({'id': idLocal, 'mensaje': e.toString()});
      }
    }

    return {
      'total': pendientes.length,
      'sincronizados': sincronizados,
      'fallidos': fallidos,
      'errores': errores,
    };
  }

  String _generarUuid() {
    final random = Random.secure();

    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // UUID versión 4 y variante RFC 4122.
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

  List<Map<String, dynamic>> _decodificarRespuestas(Object? contenido) {
    if (contenido is! String || contenido.isEmpty) {
      throw Exception('No se encontraron respuestas guardadas.');
    }

    final decoded = jsonDecode(contenido);

    if (decoded is! List) {
      throw Exception('Las respuestas locales no tienen formato de lista.');
    }

    return decoded.map((elemento) {
      if (elemento is! Map) {
        throw Exception('Una respuesta local tiene formato inválido.');
      }

      final respuesta = Map<String, dynamic>.from(elemento);

      if (!respuesta.containsKey('valor') &&
          respuesta.containsKey('respuesta')) {
        respuesta['valor'] = respuesta['respuesta'];
      }

      respuesta.remove('respuesta');
      respuesta.remove('fotos');

      return respuesta;
    }).toList();
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
