import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'core/network/inspecciones_api.dart';
import 'core/storage/preoperacional_local_db.dart';
import 'features/autenticacion/auth_service.dart';
import 'features/inspecciones/preoperacional_page.dart';
import 'features/inspecciones/inicio_preoperacional_dialog.dart';

void main() {
  runApp(const IntelliFeetApp());
}

class IntelliFeetApp extends StatelessWidget {
  const IntelliFeetApp({super.key});

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF101B33);
    const gold = Color(0xFFE0B323);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IntelliFeet Offline',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          primary: navy,
          secondary: gold,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: navy,
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _auth = AuthService();
  final _api = InspeccionesApi();

  final _username = TextEditingController();
  final _password = TextEditingController();

  Map<String, dynamic>? _usuario;
  Map<String, dynamic>? _configuracion;
  Map<String, dynamic>? _activoSeleccionado;
  Map<String, dynamic>? _plantillaSeleccionada;

  bool _cargando = false;
  bool _ocultarPassword = true;

  String? _error;
  String? _mensaje;

  List<Map<String, dynamic>> get _activos {
    final data = _configuracion?['data'];
    if (data is! Map) return [];

    final lista = data['activos'];
    if (lista is! List) return [];

    return lista
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<Map<String, dynamic>> get _plantillas {
    final data = _configuracion?['data'];
    if (data is! Map) return [];

    final lista = data['plantillas'];
    if (lista is! List) return [];

    return lista
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _iniciarSesion() async {
    FocusScope.of(context).unfocus();

    if (_username.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() {
        _error = 'Ingresa tu usuario y contraseña.';
        _mensaje = null;
      });
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
      _mensaje = null;
      _configuracion = null;
      _activoSeleccionado = null;
      _plantillaSeleccionada = null;
    });

    try {
      final resultado = await _auth.iniciarSesion(
        username: _username.text.trim(),
        password: _password.text,
      );

      if (!mounted) return;

      setState(() {
        _usuario = Map<String, dynamic>.from(resultado['usuario'] as Map);
        _mensaje = 'Inicio de sesión correcto.';
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

  Future<void> _consultarConfiguracion() async {
    final token = await _auth.obtenerToken();

    if (!mounted) return;

    if (token == null || token.isEmpty) {
      setState(() {
        _error = 'La sesión no tiene un token válido. Inicia sesión de nuevo.';
      });
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
      _mensaje = null;
    });

    try {
      final resultado = await _api.obtenerConfiguracion(token: token);

      if (!mounted) return;

      final data = resultado['data'];

      if (resultado['success'] != true || data is! Map) {
        throw Exception(
          'La configuración recibida no tiene el formato esperado.',
        );
      }

      final activos = (data['activos'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      final plantillas = (data['plantillas'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      setState(() {
        _configuracion = resultado;

        _activoSeleccionado = activos.isNotEmpty ? activos.first : null;

        _plantillaSeleccionada = plantillas
            .cast<Map<String, dynamic>?>()
            .firstWhere(
              (plantilla) =>
                  plantilla?['activa'] == true &&
                  plantilla?['tipo_activo'] == _activoSeleccionado?['tipo'],
              orElse: () => null,
            );

        _mensaje = 'Configuración descargada correctamente.';
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

  void _seleccionarActivo(Map<String, dynamic> activo) {
    setState(() {
      _activoSeleccionado = activo;

      _plantillaSeleccionada = _plantillas
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (plantilla) =>
                plantilla?['activa'] == true &&
                plantilla?['tipo_activo'] == activo['tipo'] &&
                (activo['tipo'] != 'MAQUINARIA' ||
                    plantilla?['tipo_maquinaria_id'] == activo['tipo_id']) &&
                (activo['tipo'] != 'VEHICULO' ||
                    plantilla?['tipo_vehiculo_id'] == activo['tipo_id']),
            orElse: () => null,
          );

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

  Future<void> _comenzarPreoperacional() async {
    if (_activoSeleccionado == null || _plantillaSeleccionada == null) {
      setState(() {
        _error = 'Selecciona un activo y una plantilla compatible.';
      });
      return;
    }

    setState(() {
      _error = null;
      _mensaje = null;
    });

    // Capturamos las selecciones actuales para mantenerlas estables
    // mientras se consulta la base de datos local.
    final activo = Map<String, dynamic>.from(_activoSeleccionado!);

    final plantilla = Map<String, dynamic>.from(_plantillaSeleccionada!);

    setState(() => _cargando = true);

    try {
      // 1. Buscar primero un borrador pendiente del mismo activo
      // y de la misma plantilla.
      final borrador = await PreoperacionalLocalDb.instance
          .obtenerBorradorPorActivoPlantilla(
            activo: activo,
            plantilla: plantilla,
          );

      if (!mounted) return;

      Map<String, dynamic>? datosInicio;
      String? idLocal;
      Map<String, dynamic>? borradorParaPagina;

      if (borrador != null) {
        // 2. Si existe, recuperar la lectura y la fotografía.
        final foto = _convertirFoto(borrador['foto_inicial']);

        datosInicio = {
          'lecturaInicial': borrador['lectura_inicial'],
          'fotoBytes': foto,
          'capturadaEn': borrador['foto_capturada_en'],
        };

        idLocal = borrador['id']?.toString();

        // Contiene las respuestas decodificadas por la consulta local.
        borradorParaPagina = borrador;

        setState(() {
          _mensaje =
              'Se encontró una inspección pendiente. '
              'Se recuperará el borrador guardado.';
        });
      } else {
        // 3. Si no existe borrador, solicitar los datos iniciales.
        datosInicio = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => InicioPreoperacionalDialog(
            activo: activo,
            plantilla: plantilla,
            operadorNombre:
                _usuario?['nombre']?.toString() ??
                _usuario?['username']?.toString() ??
                'Operador',
          ),
        );

        if (!mounted || datosInicio == null) return;
      }

      // 4. Abrir el formulario con los datos nuevos o recuperados.
      final datos = datosInicio;

      final lecturaInicial = datos['lecturaInicial'];
      final fotoInicial = _convertirFoto(datos['fotoBytes']);
      final fechaCaptura = datos['capturadaEn']?.toString();

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreoperacionalPage(
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

  Future<void> _cerrarSesion() async {
    await _auth.cerrarSesion();

    if (!mounted) return;

    setState(() {
      _usuario = null;
      _configuracion = null;
      _activoSeleccionado = null;
      _plantillaSeleccionada = null;
      _error = null;
      _mensaje = 'Sesión cerrada.';
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final usuario = _usuario;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'IntelliFeet Offline',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (usuario != null)
            IconButton(
              tooltip: 'Cerrar sesión',
              onPressed: _cargando ? null : _cerrarSesion,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 12),
              const Icon(
                Icons.local_shipping_outlined,
                size: 58,
                color: Color(0xFF101B33),
              ),
              const SizedBox(height: 12),
              const Text(
                'Control preoperacional',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF101B33),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Inspecciones para vehículos y maquinaria.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 24),

              if (usuario == null) ...[
                TextField(
                  controller: _username,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Usuario',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _password,
                  obscureText: _ocultarPassword,
                  decoration: InputDecoration(
                    labelText: 'Contraseña',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _ocultarPassword = !_ocultarPassword;
                        });
                      },
                      icon: Icon(
                        _ocultarPassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _iniciarSesion(),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: _cargando ? null : _iniciarSesion,
                    child: _cargando
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('Iniciar sesión'),
                  ),
                ),
              ] else ...[
                Card(
                  color: Colors.white,
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.verified_user, color: Color(0xFFB38A08)),
                            SizedBox(width: 8),
                            Text(
                              'Sesión activa',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          usuario['nombre']?.toString() ?? 'Operador',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('Usuario: ${usuario['username'] ?? ''}'),
                        Text('Rol: ${usuario['rol'] ?? ''}'),
                        Text('ID: ${usuario['id'] ?? ''}'),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _cargando
                                ? null
                                : _consultarConfiguracion,
                            icon: const Icon(Icons.download_outlined),
                            label: Text(
                              _cargando
                                  ? 'Descargando configuración...'
                                  : 'Cargar activos y plantillas',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_configuracion != null) ...[
                  const SizedBox(height: 24),
                  _seccionTitulo(
                    'Mis activos',
                    'Selecciona el vehículo o maquinaria que vas a inspeccionar.',
                  ),
                  const SizedBox(height: 10),

                  if (_activos.isEmpty)
                    _mensajeVacio('No tienes activos asignados.')
                  else
                    ..._activos.map((activo) {
                      final seleccionado =
                          activo['id'] == _activoSeleccionado?['id'] &&
                          activo['tipo'] == _activoSeleccionado?['tipo'];

                      return Card(
                        color: Colors.white,
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: seleccionado
                                ? const Color(0xFFE0B323)
                                : Colors.black12,
                            width: seleccionado ? 2 : 1,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(14),
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFF101B33),
                            foregroundColor: Colors.white,
                            child: Icon(
                              activo['tipo'] == 'MAQUINARIA'
                                  ? Icons.construction
                                  : Icons.local_shipping,
                            ),
                          ),
                          title: Text(
                            activo['nombre']?.toString() ?? 'Activo',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(activo['tipo']?.toString() ?? ''),
                                const SizedBox(height: 4),
                                Text(
                                  'Lectura actual: '
                                  '${activo['lectura_actual'] ?? 'No disponible'}'
                                  '${activo['tipo'] == 'MAQUINARIA' ? ' h' : ' km'}',
                                ),
                              ],
                            ),
                          ),
                          trailing: Icon(
                            seleccionado
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: seleccionado
                                ? const Color(0xFFB38A08)
                                : Colors.grey,
                          ),
                          onTap: _cargando
                              ? null
                              : () => _seleccionarActivo(activo),
                        ),
                      );
                    }),

                  const SizedBox(height: 20),
                  _seccionTitulo(
                    'Plantillas disponibles',
                    'Elige la inspección correspondiente al activo.',
                  ),
                  const SizedBox(height: 10),

                  if (_plantillas.isEmpty)
                    _mensajeVacio('No hay plantillas disponibles.')
                  else
                    ..._plantillas
                        .where((plantilla) {
                          if (plantilla['activa'] != true) return false;
                          if (_activoSeleccionado == null) return true;

                          if (plantilla['tipo_activo'] !=
                              _activoSeleccionado!['tipo']) {
                            return false;
                          }

                          if (_activoSeleccionado!['tipo'] == 'MAQUINARIA') {
                            return plantilla['tipo_maquinaria_id'] ==
                                _activoSeleccionado!['tipo_id'];
                          }

                          if (_activoSeleccionado!['tipo'] == 'VEHICULO') {
                            return plantilla['tipo_vehiculo_id'] ==
                                _activoSeleccionado!['tipo_id'];
                          }

                          return true;
                        })
                        .map((plantilla) {
                          final seleccionada =
                              plantilla['id'] == _plantillaSeleccionada?['id'];

                          final categorias =
                              (plantilla['categorias'] as List? ?? []);

                          final preguntas = categorias.fold<int>(
                            0,
                            (total, categoria) =>
                                total +
                                ((categoria is Map &&
                                        categoria['items'] is List)
                                    ? (categoria['items'] as List).length
                                    : 0),
                          );

                          return Card(
                            color: Colors.white,
                            elevation: 0,
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: seleccionada
                                    ? const Color(0xFFE0B323)
                                    : Colors.black12,
                                width: seleccionada ? 2 : 1,
                              ),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(14),
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFFFF3C4),
                                child: Icon(
                                  Icons.assignment_outlined,
                                  color: Color(0xFF101B33),
                                ),
                              ),
                              title: Text(
                                plantilla['nombre']?.toString() ?? 'Plantilla',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      plantilla['descripcion']?.toString() ??
                                          '',
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${categorias.length} categorías · '
                                      '$preguntas preguntas',
                                    ),
                                    Text(
                                      'Lectura: '
                                      '${plantilla['tipo_medicion'] ?? 'No especificada'}',
                                    ),
                                  ],
                                ),
                              ),
                              trailing: Icon(
                                seleccionada
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: seleccionada
                                    ? const Color(0xFFB38A08)
                                    : Colors.grey,
                              ),
                              onTap: _cargando
                                  ? null
                                  : () => _seleccionarPlantilla(plantilla),
                            ),
                          );
                        }),

                  const SizedBox(height: 16),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed:
                          _cargando ||
                              _activoSeleccionado == null ||
                              _plantillaSeleccionada == null
                          ? null
                          : _comenzarPreoperacional,
                      icon: _cargando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(
                        _cargando
                            ? 'Preparando inspección...'
                            : 'Comenzar preoperacional',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Los borradores se guardan localmente. '
                    'La sincronización con el servidor está pendiente.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ],

              if (_mensaje != null) ...[
                const SizedBox(height: 14),
                Text(_mensaje!, style: const TextStyle(color: Colors.green)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _seccionTitulo(String titulo, String subtitulo) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titulo,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
            color: Color(0xFF101B33),
          ),
        ),
        const SizedBox(height: 4),
        Text(subtitulo, style: const TextStyle(color: Colors.black54)),
      ],
    );
  }

  Widget _mensajeVacio(String texto) {
    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.black54),
            const SizedBox(width: 10),
            Expanded(child: Text(texto)),
          ],
        ),
      ),
    );
  }
}
