import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../core/config/api_config.dart';

class AuthService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'intellifeet_access_token';

  Future<Map<String, dynamic>> iniciarSesion({
    required String username,
    required String password,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/api/auth/login'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));

    final dynamic body;

    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw Exception('El servidor devolvió una respuesta no válida.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final mensaje = body is Map
          ? body['msg'] ?? body['message'] ?? body['error']
          : null;

      throw Exception(
        mensaje?.toString() ??
            'No se pudo iniciar sesión (HTTP ${response.statusCode}).',
      );
    }

    if (body is! Map<String, dynamic> ||
        body['token'] == null ||
        body['usuario'] is! Map) {
      throw Exception(
        'La respuesta de autenticación no tiene el formato esperado.',
      );
    }

    final usuario = Map<String, dynamic>.from(body['usuario'] as Map);

    if (usuario['activo'] == false) {
      throw Exception('La cuenta de usuario está inactiva.');
    }

    await _storage.write(key: _tokenKey, value: body['token'].toString());

    return {'token': body['token'].toString(), 'usuario': usuario};
  }

  Future<String?> obtenerToken() {
    return _storage.read(key: _tokenKey);
  }

  Future<void> cerrarSesion() async {
    await _storage.delete(key: _tokenKey);
  }
}
