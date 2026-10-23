import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class InspeccionesApi {
  static const Duration _timeoutNormal = Duration(seconds: 20);
  static const Duration _timeoutMultipart = Duration(seconds: 60);

  // ==========================================================
  // OBTENER CONFIGURACIÓN MÓVIL
  // ==========================================================

  Future<Map<String, dynamic>> obtenerConfiguracion({
    required String token,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.configuracionEndpoint}',
    );

    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(_timeoutNormal);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(decoded, 'Error HTTP ${response.statusCode}.'),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'No se pudo obtener la configuración.',
    );

    return data;
  }

  // ==========================================================
  // DESCARGAR HISTORIAL DE INSPECCIONES
  // ==========================================================

  Future<Map<String, dynamic>> obtenerHistorialInspecciones({
    required String token,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.historialEndpoint}');

    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(_timeoutNormal);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al descargar el historial '
          '(HTTP ${response.statusCode}).',
        ),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'No se pudo descargar el historial.',
    );

    final inspecciones = data['inspecciones'];

    if (inspecciones is! List) {
      throw Exception(
        'El servidor no devolvió una lista válida de inspecciones.',
      );
    }

    return data;
  }

  // ==========================================================
  // SINCRONIZAR INSPECCIÓN OFFLINE
  //
  // IMPORTANTE:
  // Este método solamente envía el avance.
  // No finaliza la inspección ni registra la lectura final.
  // ==========================================================

  Future<Map<String, dynamic>> sincronizarInspeccion({
    required String token,
    required Map<String, dynamic> payload,
    Map<String, List<int>> fotografias = const {},
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.sincronizarEndpoint}',
    );

    final request = http.MultipartRequest('POST', uri);

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });

    // Se conserva el contrato multipart existente.
    // Flask debe leer el JSON desde request.form['payload'].
    request.fields['payload'] = jsonEncode(payload);

    // Las claves deben coincidir con los nombres que espera Flask.
    for (final entry in fotografias.entries) {
      if (entry.key.trim().isEmpty) {
        throw Exception('Se encontró una fotografía sin nombre de campo.');
      }

      if (entry.value.isEmpty) {
        throw Exception('La fotografía "${entry.key}" está vacía.');
      }

      request.files.add(
        http.MultipartFile.fromBytes(
          entry.key,
          entry.value,
          filename: '${entry.key}.jpg',
        ),
      );
    }

    final streamedResponse = await request.send().timeout(_timeoutMultipart);

    // También se limita el tiempo de lectura del cuerpo.
    final response = await http.Response.fromStream(streamedResponse)
        .timeout(_timeoutMultipart);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al sincronizar (HTTP ${response.statusCode}).',
        ),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'El servidor no confirmó la sincronización.',
    );

    // La respuesta debe contener los datos de la inspección.
    // No se asume que HTTP 200 por sí solo confirme el resultado.
    if (data.isEmpty) {
      throw Exception(
        'El servidor confirmó la solicitud, '
        'pero no devolvió los datos de la inspección.',
      );
    }

    return data;
  }

  // ==========================================================
  // SINCRONIZAR UNA ANOMALÍA INDIVIDUAL
  //
  // Envía una anomalía pendiente y sus fotografías sin
  // reenviar las respuestas de la inspección.
  // ==========================================================

  Future<Map<String, dynamic>> sincronizarAnomalia({
    required String token,
    required String uuidInspeccion,
    required Map<String, dynamic> payload,
    Map<String, List<int>> fotografias = const {},
  }) async {
    final uuidInspeccionNormalizado = uuidInspeccion.trim();
    final uuidAnomalia = payload['uuid_sync']?.toString().trim() ?? '';

    if (uuidInspeccionNormalizado.isEmpty) {
      throw Exception('El UUID de la inspección es obligatorio.');
    }

    if (uuidAnomalia.isEmpty) {
      throw Exception('El UUID de la anomalía es obligatorio.');
    }

    final titulo = payload['titulo']?.toString().trim() ?? '';

    if (titulo.isEmpty) {
      throw Exception('El título de la anomalía es obligatorio.');
    }

    // La inspección se identifica por su UUID local estable.
    // El backend lo resolverá al ID real de la inspección.
    final payloadCompleto = <String, dynamic>{
      ...payload,
      'uuid_inspeccion': uuidInspeccionNormalizado,
      'uuid_sync': uuidAnomalia,
    };

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.sincronizarAnomaliaEndpoint}',
    );

    final request = http.MultipartRequest('POST', uri);

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });

    // Flask recibirá el JSON desde request.form['payload'].
    request.fields['payload'] = jsonEncode(payloadCompleto);

    for (final entry in fotografias.entries) {
      final clave = entry.key.trim();
      final bytes = entry.value;

      if (clave.isEmpty) {
        throw Exception('Se encontró una fotografía sin nombre de campo.');
      }

      if (bytes.isEmpty) {
        throw Exception('La fotografía "$clave" está vacía.');
      }

      request.files.add(
        http.MultipartFile.fromBytes(clave, bytes, filename: '$clave.jpg'),
      );
    }

    final streamedResponse = await request.send().timeout(_timeoutMultipart);

    final response = await http.Response.fromStream(streamedResponse)
        .timeout(_timeoutMultipart);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al sincronizar la anomalía '
          '(HTTP ${response.statusCode}).',
        ),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto:
          'El servidor no confirmó la sincronización de la anomalía.',
    );

    // No basta con recibir HTTP 200: el servidor debe confirmar
    // que procesó la anomalía solicitada.
    final uuidAnomaliaRespuesta = data['uuid_anomalia']?.toString();

    if (uuidAnomaliaRespuesta != uuidAnomalia) {
      throw Exception(
        'El servidor no confirmó el UUID de la anomalía enviada.',
      );
    }

    final uuidInspeccionRespuesta = data['uuid_inspeccion']?.toString();

    if (uuidInspeccionRespuesta != uuidInspeccionNormalizado) {
      throw Exception(
        'El servidor no confirmó la inspección asociada '
        'a la anomalía.',
      );
    }

    return data;
  }

  // ==========================================================
  // CONSULTAR ESTADO DE SINCRONIZACIÓN
  // ==========================================================

  Future<Map<String, dynamic>> consultarSincronizacion({
    required String token,
    required String uuidSync,
  }) async {
    if (uuidSync.trim().isEmpty) {
      throw Exception('No se puede consultar la sincronización sin un UUID.');
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.sincronizacionEndpoint}/'
      '${Uri.encodeComponent(uuidSync)}',
    );

    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(_timeoutNormal);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error consultando sincronización '
          '(HTTP ${response.statusCode}).',
        ),
      );
    }

    return _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'No fue posible consultar la sincronización.',
    );
  }

  // ==========================================================
  // FINALIZAR INSPECCIÓN
  //
  // Este endpoint se conserva separado de la sincronización
  // parcial. No se invoca desde sincronizarInspeccion().
  // ==========================================================

  Future<Map<String, dynamic>> finalizarInspeccion({
    required String token,
    required int inspeccionId,
  }) async {
    if (inspeccionId <= 0) {
      throw Exception('El identificador de la inspección no es válido.');
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.finalizarEndpoint(inspeccionId)}',
    );

    final response = await http
        .post(
          uri,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: '{}',
        )
        .timeout(_timeoutNormal);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al finalizar (HTTP ${response.statusCode}).',
        ),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'El servidor no confirmó la finalización.',
    );

    // El backend puede responder HTTP 200 y señalar que la
    // validación de negocio no fue satisfactoria.
    if (data['ok'] != true) {
      final errores = data['errores'];

      if (errores is List && errores.isNotEmpty) {
        throw Exception(errores.take(8).map((error) => '• $error').join('\n'));
      }

      throw Exception(
        data['mensaje']?.toString() ?? 'El servidor rechazó la finalización.',
      );
    }

    return data;
  }

  // ==========================================================
  // REGISTRAR LECTURA FINAL + FIRMA
  // ==========================================================

  Future<Map<String, dynamic>> registrarLecturaFinal({
    required String token,
    required int inspeccionId,
    required num lecturaFinal,
    required List<int> fotoFinal,
    required List<int> firmaPng,
  }) async {
    if (inspeccionId <= 0) {
      throw Exception('El identificador de la inspección no es válido.');
    }

    if (!lecturaFinal.isFinite || lecturaFinal < 0) {
      throw Exception(
        'La lectura final debe ser un número válido '
        'mayor o igual a cero.',
      );
    }

    if (fotoFinal.isEmpty) {
      throw Exception('La fotografía de la lectura final está vacía.');
    }

    if (firmaPng.isEmpty) {
      throw Exception('La firma del operador está vacía.');
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.lecturaFinalEndpoint(inspeccionId)}',
    );

    final request = http.MultipartRequest('POST', uri);

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });

    // Se conservan los nombres de campo del contrato existente.
    request.fields['lectura'] = lecturaFinal.toString();
    request.fields['tratamiento_datos_aceptado'] = 'true';
    request.fields['confirma_firma'] = 'true';

    request.files.add(
      http.MultipartFile.fromBytes(
        'foto',
        fotoFinal,
        filename: 'lectura_final.jpg',
      ),
    );

    request.files.add(
      http.MultipartFile.fromBytes('firma', firmaPng, filename: 'firma.png'),
    );

    final streamedResponse = await request.send().timeout(_timeoutMultipart);

    final response = await http.Response.fromStream(streamedResponse)
        .timeout(_timeoutMultipart);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al registrar la lectura final '
          '(HTTP ${response.statusCode}).',
        ),
      );
    }

    final data = _validarRespuestaExitosa(
      decoded,
      mensajePorDefecto: 'El servidor no confirmó la lectura final.',
    );

    if (data['ok'] == false) {
      final errores = data['errores'];

      if (errores is List && errores.isNotEmpty) {
        throw Exception(errores.take(8).map((error) => '• $error').join('\n'));
      }

      throw Exception(
        data['mensaje']?.toString() ??
            'El servidor rechazó el registro de la lectura final.',
      );
    }

    return data;
  }

  // ==========================================================
  // VALIDAR RESPUESTA ESTÁNDAR DEL BACKEND
  // ==========================================================

  Map<String, dynamic> _validarRespuestaExitosa(
    dynamic decoded, {
    required String mensajePorDefecto,
  }) {
    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'La respuesta del servidor no tiene el formato esperado.',
      );
    }

    if (decoded['success'] != true) {
      throw Exception(_obtenerMensaje(decoded, mensajePorDefecto));
    }

    final resultado = decoded['data'];

    if (resultado is! Map<String, dynamic>) {
      throw Exception(
        'La respuesta del servidor no contiene '
        'un objeto data válido.',
      );
    }

    return resultado;
  }

  // ==========================================================
  // DECODIFICAR RESPUESTA HTTP
  // ==========================================================

  dynamic _decodificarRespuesta(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw Exception(
        'El servidor no devolvió JSON válido '
        '(HTTP ${response.statusCode}).',
      );
    }
  }

  // ==========================================================
  // OBTENER MENSAJE DE ERROR
  // ==========================================================

  String _obtenerMensaje(dynamic decoded, String mensajePorDefecto) {
    if (decoded is Map) {
      final mensaje =
          decoded['message'] ?? decoded['mensaje'] ?? decoded['error'];

      if (mensaje != null && mensaje.toString().trim().isNotEmpty) {
        return mensaje.toString();
      }

      final errores = decoded['errores'];

      if (errores is List && errores.isNotEmpty) {
        return errores.take(8).map((error) => error.toString()).join('\n');
      }
    }

    return mensajePorDefecto;
  }
}
