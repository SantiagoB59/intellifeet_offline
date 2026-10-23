import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../core/config/api_config.dart';

class AuthService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'intellifeet_access_token';
  static const _usuarioKey = 'intellifeet_usuario_cache';
  static const _credUsernameKey = 'intellifeet_cred_username';
  static const _credPasswordHashKey = 'intellifeet_cred_password_hash';

  // ==========================================================
  // INICIO DE SESIÓN CON INTERNET
  // ==========================================================

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

    await _guardarSesionParaOffline(
      username: username,
      password: password,
      token: body['token'].toString(),
      usuario: usuario,
    );

    return {'token': body['token'].toString(), 'usuario': usuario};
  }

  // ==========================================================
  // INICIO DE SESIÓN SIN INTERNET
  //
  // Valida contra las credenciales guardadas en el último
  // inicio de sesión con internet. La contraseña se guarda
  // como hash SHA-256 dentro del almacenamiento seguro del
  // dispositivo (nunca en texto plano).
  // ==========================================================

  Future<Map<String, dynamic>> iniciarSesionOffline({
    required String username,
    required String password,
  }) async {
    final usernameGuardado = await _storage.read(key: _credUsernameKey);
    final hashGuardado = await _storage.read(key: _credPasswordHashKey);
    final usuarioJson = await _storage.read(key: _usuarioKey);

    if (usernameGuardado == null ||
        hashGuardado == null ||
        usuarioJson == null) {
      throw Exception(
        'Sin conexión: primero debes iniciar sesión con internet '
        'al menos una vez en este dispositivo.',
      );
    }

    final usernameNormalizado = username.trim().toLowerCase();

    if (usernameGuardado != usernameNormalizado ||
        hashGuardado != _hashPassword(password)) {
      throw Exception(
        'Las credenciales no coinciden con las guardadas '
        'en este dispositivo.',
      );
    }

    final decoded = jsonDecode(usuarioJson);

    if (decoded is! Map) {
      throw Exception(
        'La sesión guardada está dañada. Inicia sesión con internet.',
      );
    }

    return {
      'usuario': Map<String, dynamic>.from(decoded),
      'offline': true,
    };
  }

  /// Indica si hay credenciales guardadas para entrar offline.
  Future<bool> tieneSesionOffline() async {
    final usuarioJson = await _storage.read(key: _usuarioKey);
    final hashGuardado = await _storage.read(key: _credPasswordHashKey);

    return usuarioJson != null && hashGuardado != null;
  }

  // ==========================================================
  // SESIÓN
  // ==========================================================

  Future<String?> obtenerToken() {
    return _storage.read(key: _tokenKey);
  }

  /// Cierra la sesión activa. Las credenciales offline se
  /// conservan para poder volver a entrar sin internet.
  Future<void> cerrarSesion() async {
    await _storage.delete(key: _tokenKey);
  }

  // ==========================================================
  // UTILIDADES PRIVADAS
  // ==========================================================

  Future<void> _guardarSesionParaOffline({
    required String username,
    required String password,
    required String token,
    required Map<String, dynamic> usuario,
  }) async {
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _usuarioKey, value: jsonEncode(usuario));
    await _storage.write(
      key: _credUsernameKey,
      value: username.trim().toLowerCase(),
    );
    await _storage.write(
      key: _credPasswordHashKey,
      value: _hashPassword(password),
    );
  }

  String _hashPassword(String password) {
    return sha256
        .convert(utf8.encode('intellifeet::$password'))
        .toString();
  }
}
