import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class InspeccionesApi {
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
        .timeout(const Duration(seconds: 20));

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(decoded, 'Error HTTP ${response.statusCode}.'),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'La respuesta del servidor no tiene el formato esperado.',
      );
    }

    if (decoded['success'] == false) {
      throw Exception(
        _obtenerMensaje(decoded, 'No se pudo obtener la configuración.'),
      );
    }

    return decoded;
  }

  // ==========================================================
  // SINCRONIZAR INSPECCIÓN OFFLINE
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

    // Flask espera el JSON dentro del campo form-data "payload".
    request.fields['payload'] = jsonEncode(payload);

    // Cada clave debe coincidir con archivo_key o
    // foto_contador_inicial_key en el JSON.
    for (final entry in fotografias.entries) {
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

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 60),
    );

    final response = await http.Response.fromStream(streamedResponse);

    final decoded = _decodificarRespuesta(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _obtenerMensaje(
          decoded,
          'Error al sincronizar (HTTP ${response.statusCode}).',
        ),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'La respuesta de sincronización no tiene el formato esperado.',
      );
    }

    if (decoded['success'] != true) {
      throw Exception(
        _obtenerMensaje(decoded, 'El servidor no confirmó la sincronización.'),
      );
    }

    final resultado = decoded['data'];

    if (resultado is! Map<String, dynamic>) {
      throw Exception('El servidor no devolvió los datos de la inspección.');
    }

    return resultado;
  }

  // ==========================================================
  // CONSULTAR ESTADO DE SINCRONIZACIÓN
  // ==========================================================

  Future<Map<String, dynamic>> consultarSincronizacion({
    required String token,
    required String uuidSync,
  }) async {
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
        .timeout(const Duration(seconds: 20));

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

    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'La respuesta del servidor no tiene el formato esperado.',
      );
    }

    if (decoded['success'] != true) {
      throw Exception(
        _obtenerMensaje(decoded, 'No fue posible consultar la sincronización.'),
      );
    }

    final resultado = decoded['data'];

    if (resultado is! Map<String, dynamic>) {
      throw Exception(
        'El estado de sincronización no tiene el formato esperado.',
      );
    }

    return resultado;
  }

  // ==========================================================
  // UTILIDADES
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

  String _obtenerMensaje(dynamic decoded, String mensajePorDefecto) {
    if (decoded is Map) {
      final mensaje =
          decoded['message'] ?? decoded['mensaje'] ?? decoded['error'];

      if (mensaje != null && mensaje.toString().isNotEmpty) {
        return mensaje.toString();
      }
    }

    return mensajePorDefecto;
  }
}
