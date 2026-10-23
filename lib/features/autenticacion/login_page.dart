import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/network/connectivity_service.dart';
import '../inspecciones/home_page.dart';
import 'auth_service.dart';

const Color _navy = Color(0xFF101B33);
const Color _blue = Color(0xFF2457A7);
const Color _gold = Color(0xFFD5AD48);
const Color _background = Color(0xFFF3F6FB);
const Color _muted = Color(0xFF718096);

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _auth = AuthService();
  final _connectivity = ConnectivityService();

  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _cargando = false;
  bool _ocultarPassword = true;
  bool _enLinea = true;

  String? _error;

  @override
  void initState() {
    super.initState();
    _verificarConexion();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _verificarConexion() async {
    final enLinea = await _connectivity.hayConexion();

    if (mounted) {
      setState(() => _enLinea = enLinea);
    }
  }

  bool _esErrorDeRed(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException ||
        error is HandshakeException;
  }

  Future<void> _iniciarSesion() async {
    FocusScope.of(context).unfocus();

    if (_username.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() {
        _error = 'Ingresa tu usuario y contraseña.';
      });
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
    });

    final username = _username.text.trim();
    final password = _password.text;

    try {
      Map<String, dynamic> resultado;
      var modoOffline = false;

      try {
        // Intenta primero el login real, incluso si el plugin
        // de conectividad indica que no hay red.
        resultado = await _auth.iniciarSesion(
          username: username,
          password: password,
        );
      } catch (e) {
        // Solo permite el acceso offline si falla la conexión.
        // Los errores de autenticación se mantienen como errores.
        if (_esErrorDeRed(e)) {
          resultado = await _auth.iniciarSesionOffline(
            username: username,
            password: password,
          );
          modoOffline = true;
        } else {
          rethrow;
        }
      }

      if (!mounted) return;

      final usuario = Map<String, dynamic>.from(resultado['usuario'] as Map);

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomePage(usuario: usuario, modoOffline: modoOffline),
        ),
      );
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

  InputDecoration _decoracionCampo({
    required String etiqueta,
    required IconData icono,
    Widget? sufijo,
  }) {
    return InputDecoration(
      labelText: etiqueta,
      prefixIcon: Icon(icono, color: _muted, size: 21),
      suffixIcon: sufijo,
      filled: true,
      fillColor: const Color(0xFFF7F9FC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 19),
      labelStyle: const TextStyle(color: _muted, fontSize: 14),
      floatingLabelStyle: const TextStyle(
        color: _blue,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE0E6EF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFFE0E6EF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: _blue, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
      ),
    );
  }

  Widget _construirIndicadorConexion() {
    final color = _enLinea ? const Color(0xFF18794E) : const Color(0xFF9A6700);

    final fondo = _enLinea ? const Color(0xFFEAF7EF) : const Color(0xFFFFF5D9);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withOpacity(0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _enLinea ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 7),
          Text(
            _enLinea ? 'Conexión disponible' : 'Modo sin conexión',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _construirEncabezado() {
    return Column(
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.09),
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: Colors.white.withOpacity(0.16)),
          ),
          child: const Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.local_shipping_rounded, color: Colors.white, size: 43),
              Positioned(
                right: 13,
                bottom: 13,
                child: Icon(Icons.verified_rounded, color: _gold, size: 19),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'IntelliFeet',
          style: TextStyle(
            color: Colors.white,
            fontSize: 31,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'GESTIÓN INTELIGENTE DE FLOTA',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFFD7DFEE),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: 43,
          height: 3,
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        const SizedBox(height: 17),
        const Text(
          'Tu operación, bajo control.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _construirError() {
    if (_error == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 17),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF3CCCC)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFC43D3D),
            size: 21,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFF9D2929),
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _construirFormulario() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 27, 24, 23),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: const Color(0xFFE8EDF4)),
        boxShadow: [
          BoxShadow(
            color: _navy.withOpacity(0.07),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Bienvenido',
            style: TextStyle(
              color: _navy,
              fontSize: 25,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'Ingresa con tus credenciales para continuar.',
            style: TextStyle(color: _muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 23),
          _construirIndicadorConexion(),
          const SizedBox(height: 23),
          const Text(
            'USUARIO',
            style: TextStyle(
              color: _navy,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 9),
          TextField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.none,
            style: const TextStyle(
              color: _navy,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            decoration: _decoracionCampo(
              etiqueta: 'Tu usuario',
              icono: Icons.person_outline_rounded,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'CONTRASEÑA',
            style: TextStyle(
              color: _navy,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 9),
          TextField(
            controller: _password,
            obscureText: _ocultarPassword,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            style: const TextStyle(
              color: _navy,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            decoration: _decoracionCampo(
              etiqueta: 'Tu contraseña',
              icono: Icons.lock_outline_rounded,
              sufijo: IconButton(
                tooltip: _ocultarPassword
                    ? 'Mostrar contraseña'
                    : 'Ocultar contraseña',
                onPressed: () {
                  setState(() {
                    _ocultarPassword = !_ocultarPassword;
                  });
                },
                icon: Icon(
                  _ocultarPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: _muted,
                  size: 21,
                ),
              ),
            ),
            onSubmitted: (_) {
              if (!_cargando) _iniciarSesion();
            },
          ),
          _construirError(),
          const SizedBox(height: 23),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _cargando ? null : _iniciarSesion,
              style: FilledButton.styleFrom(
                backgroundColor: _blue,
                disabledBackgroundColor: _blue.withOpacity(0.6),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              child: _cargando
                  ? const SizedBox(
                      width: 23,
                      height: 23,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.login_rounded, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          _enLinea ? 'Iniciar sesión' : 'Ingresar sin conexión',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 17,
                color: Colors.blueGrey.shade400,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  'Acceso protegido para usuarios autorizados',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.blueGrey.shade500,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final ancho = constraints.maxWidth;
          final esPantallaAmplia = ancho >= 700;

          return Stack(
            children: [
              // Fondo corporativo.
              Container(
                height: esPantallaAmplia ? 360 : 320,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_navy, Color(0xFF1B3156), _blue],
                  ),
                ),
              ),

              // Detalles decorativos del encabezado.
              Positioned(
                top: -100,
                right: -75,
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.06),
                      width: 35,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 105,
                left: -100,
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.025),
                  ),
                ),
              ),

              SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: ancho < 360 ? 17 : 24,
                    vertical: 27,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        children: [
                          _construirEncabezado(),
                          const SizedBox(height: 29),
                          _construirFormulario(),
                          const SizedBox(height: 25),
                          const Text(
                            'INTELLIFEET  •  CONTROL PREOPERACIONAL',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF8995A8),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Seguridad y continuidad en cada recorrido.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF8995A8),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
