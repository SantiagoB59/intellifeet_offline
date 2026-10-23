import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PreoperacionalLocalDb {
  PreoperacionalLocalDb._();

  static final PreoperacionalLocalDb instance = PreoperacionalLocalDb._();

  static Database? _database;

  static const int versionBaseDatos = 8;

  static const String estadoPendiente = 'PENDIENTE';
  static const String estadoCerradaPendienteSync = 'CERRADA_PENDIENTE_SYNC';
  static const String estadoSincronizado = 'SINCRONIZADO';
  static const String estadoPreguntasCompletadas = 'PREGUNTAS_COMPLETADAS';
  static const String estadoSincronizadoParcial = 'SINCRONIZADO_PARCIAL';

  static const String _tablaInspecciones = 'preoperacionales';
  static const String _tablaConfiguracion = 'configuracion_cache';
  static const String _tablaAnomalias = 'anomalias_locales';
  static const String _tablaAnomaliaFotos = 'anomalia_fotos_locales';

  Future<Database> get database async {
    if (_database != null) return _database!;

    final directorio = await getDatabasesPath();
    final ruta = p.join(directorio, 'intellifeet_offline.db');

    _database = await openDatabase(
      ruta,
      version: versionBaseDatos,
      onCreate: _crearBaseDatos,
      onUpgrade: _actualizarBaseDatos,
    );

    return _database!;
  }

  // ==========================================================
  // CREACIÓN Y MIGRACIONES
  // ==========================================================

  Future<void> _crearBaseDatos(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tablaInspecciones (
        id TEXT PRIMARY KEY,
        usuario_id INTEGER,
        uuid_sync TEXT UNIQUE,
        activo_json TEXT NOT NULL,
        plantilla_json TEXT NOT NULL,
        lectura_inicial REAL,
        foto_inicial BLOB,
        foto_capturada_en TEXT,
        lectura_final REAL,
        foto_final BLOB,
        firma BLOB,
        consentimiento_aceptado INTEGER NOT NULL DEFAULT 0,
        confirma_firma INTEGER NOT NULL DEFAULT 0,
        observaciones_generales TEXT NOT NULL DEFAULT '',
        cerrado_en TEXT,
        respuestas_json TEXT NOT NULL,
        estado TEXT NOT NULL,
        avance_sincronizado INTEGER NOT NULL DEFAULT 0,
        creado_en TEXT NOT NULL,
        actualizado_en TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS
      idx_preoperacionales_uuid_sync
      ON $_tablaInspecciones(uuid_sync)
      WHERE uuid_sync IS NOT NULL
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS
      idx_preoperacionales_usuario_estado
      ON $_tablaInspecciones(usuario_id, estado)
    ''');

    // Una caché independiente por usuario.
    await db.execute('''
      CREATE TABLE $_tablaConfiguracion (
        usuario_id INTEGER PRIMARY KEY NOT NULL,
        activos_json TEXT NOT NULL,
        plantillas_json TEXT NOT NULL,
        descargado_en TEXT NOT NULL
      )
    ''');
    await _crearTablasAnomalias(db);
  }

  Future<void> _crearTablasAnomalias(DatabaseExecutor db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS $_tablaAnomalias (
      id TEXT PRIMARY KEY,
      inspeccion_id TEXT NOT NULL,
      usuario_id INTEGER NOT NULL,
      uuid_sync TEXT NOT NULL UNIQUE,
      titulo TEXT NOT NULL,
      descripcion TEXT NOT NULL DEFAULT '',
      prioridad TEXT NOT NULL DEFAULT 'MEDIA',
      estado TEXT NOT NULL DEFAULT 'PENDIENTE_SYNC',
      creado_en TEXT NOT NULL,
      actualizado_en TEXT NOT NULL
    )
  ''');

    await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_anomalias_inspeccion_usuario
    ON $_tablaAnomalias(inspeccion_id, usuario_id)
  ''');

    await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_anomalias_estado
    ON $_tablaAnomalias(usuario_id, estado)
  ''');

    await db.execute('''
    CREATE TABLE IF NOT EXISTS $_tablaAnomaliaFotos (
      id TEXT PRIMARY KEY,
      anomalia_id TEXT NOT NULL,
      usuario_id INTEGER NOT NULL,
      foto BLOB NOT NULL,
      creado_en TEXT NOT NULL
    )
  ''');

    await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_anomalia_fotos_anomalia
    ON $_tablaAnomaliaFotos(anomalia_id, usuario_id)
  ''');
  }

  Future<void> _actualizarBaseDatos(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $_tablaInspecciones ADD COLUMN uuid_sync TEXT',
      );

      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS
        idx_preoperacionales_uuid_sync
        ON $_tablaInspecciones(uuid_sync)
        WHERE uuid_sync IS NOT NULL
      ''');
    }

    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE $_tablaInspecciones ADD COLUMN lectura_final REAL',
      );
      await db.execute(
        'ALTER TABLE $_tablaInspecciones ADD COLUMN foto_final BLOB',
      );
      await db.execute('ALTER TABLE $_tablaInspecciones ADD COLUMN firma BLOB');
      await db.execute('''
        ALTER TABLE $_tablaInspecciones
        ADD COLUMN consentimiento_aceptado INTEGER NOT NULL DEFAULT 0
      ''');
      await db.execute('''
        ALTER TABLE $_tablaInspecciones
        ADD COLUMN confirma_firma INTEGER NOT NULL DEFAULT 0
      ''');
      await db.execute('''
        ALTER TABLE $_tablaInspecciones
        ADD COLUMN observaciones_generales TEXT NOT NULL DEFAULT ''
      ''');
      await db.execute(
        'ALTER TABLE $_tablaInspecciones ADD COLUMN cerrado_en TEXT',
      );
    }

    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tablaConfiguracion (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          usuario_id INTEGER,
          activos_json TEXT NOT NULL,
          plantillas_json TEXT NOT NULL,
          descargado_en TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 6) {
      // Los registros antiguos quedan con usuario_id NULL.
      // No se asignan automáticamente al usuario que inicia sesión.
      await db.execute('''
        ALTER TABLE $_tablaInspecciones
        ADD COLUMN usuario_id INTEGER
      ''');

      // La tabla anterior solo permitía una configuración compartida.
      // Se migra a una configuración independiente por usuario.
      await db.execute('''
        CREATE TABLE configuracion_cache_v6 (
          usuario_id INTEGER PRIMARY KEY NOT NULL,
          activos_json TEXT NOT NULL,
          plantillas_json TEXT NOT NULL,
          descargado_en TEXT NOT NULL
        )
      ''');

      await db.execute('''
        INSERT OR IGNORE INTO configuracion_cache_v6 (
          usuario_id,
          activos_json,
          plantillas_json,
          descargado_en
        )
        SELECT
          usuario_id,
          activos_json,
          plantillas_json,
          descargado_en
        FROM $_tablaConfiguracion
        WHERE usuario_id IS NOT NULL
      ''');

      await db.execute('DROP TABLE $_tablaConfiguracion');

      await db.execute('''
        ALTER TABLE configuracion_cache_v6
        RENAME TO $_tablaConfiguracion
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS
        idx_preoperacionales_usuario_estado
        ON $_tablaInspecciones(usuario_id, estado)
      ''');
    }
    if (oldVersion < 7) {
      await _crearTablasAnomalias(db);
    }
    if (oldVersion < 8) {
      await db.execute('''
    ALTER TABLE $_tablaInspecciones
    ADD COLUMN avance_sincronizado INTEGER NOT NULL DEFAULT 0
  ''');
    }
  }

  // ==========================================================
  // VALIDACIÓN DE IDENTIDAD
  // ==========================================================

  void _validarUsuarioId(int usuarioId) {
    if (usuarioId <= 0) {
      throw ArgumentError.value(
        usuarioId,
        'usuarioId',
        'El ID del usuario debe ser un entero positivo.',
      );
    }
  }

  /// Comprueba que la inspección exista y pertenezca al usuario.
  ///
  /// Los registros antiguos sin propietario no se pueden utilizar
  /// hasta que su propietario se recupere de forma explícita.
  Future<Map<String, Object?>> _exigirPropiedad(
    DatabaseExecutor executor, {
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final filas = await executor.query(
      _tablaInspecciones,
      where: 'id = ? AND usuario_id = ?',
      whereArgs: [id, usuarioId],
      limit: 1,
    );

    if (filas.isEmpty) {
      throw Exception(
        'No se encontró la inspección para el usuario autenticado.',
      );
    }

    return filas.first;
  }

  // ==========================================================
  // UUID ESTABLE DE SINCRONIZACIÓN
  // ==========================================================

  Future<void> guardarUuidSync({
    required String idLocal,
    required String uuidSync,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;
    final uuidNormalizado = uuidSync.trim();

    if (uuidNormalizado.isEmpty) {
      throw Exception('El UUID de sincronización no puede estar vacío.');
    }

    await db.transaction((txn) async {
      final fila = await _exigirPropiedad(
        txn,
        id: idLocal,
        usuarioId: usuarioId,
      );

      final uuidExistente = fila['uuid_sync']?.toString();
      final estadoActual = fila['estado']?.toString();

      if (uuidExistente != null && uuidExistente.isNotEmpty) {
        if (uuidExistente != uuidNormalizado) {
          throw Exception(
            'La inspección ya tiene un UUID diferente. '
            'No se permite reemplazarlo.',
          );
        }

        return;
      }

      const estadosPermitidos = [
        estadoPendiente,
        estadoSincronizadoParcial,
        estadoPreguntasCompletadas,
        estadoCerradaPendienteSync,
      ];

      if (!estadosPermitidos.contains(estadoActual)) {
        throw Exception(
          'No se puede asignar un UUID a una inspección '
          'en estado $estadoActual.',
        );
      }

      final cantidad = await txn.update(
        _tablaInspecciones,
        {'uuid_sync': uuidNormalizado},
        where: 'id = ? AND usuario_id = ? AND uuid_sync IS NULL',
        whereArgs: [idLocal, usuarioId],
      );

      if (cantidad == 0) {
        throw Exception('No se pudo guardar el UUID de sincronización.');
      }
    });
  }

  // ==========================================================
  // RECUPERACIÓN DEL BORRADOR DIARIO
  // ==========================================================

  Future<Map<String, dynamic>?> obtenerBorradorPorActivoPlantilla({
    required int usuarioId,
    required Map<String, dynamic> activo,
    required Map<String, dynamic> plantilla,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    String? obtenerIdentificador(
      Map<String, dynamic> objeto,
      List<String> claves,
    ) {
      for (final clave in claves) {
        final valor = objeto[clave];

        if (valor != null && valor.toString().trim().isNotEmpty) {
          return valor.toString().trim();
        }
      }

      return null;
    }

    final idActivo = obtenerIdentificador(activo, [
      'id',
      'vehiculo_id',
      'maquinaria_id',
      'codigo',
      'placa',
    ]);

    final idPlantilla = obtenerIdentificador(plantilla, ['id', 'plantilla_id']);

    if (idActivo == null || idPlantilla == null) {
      return null;
    }

    final filas = await db.query(
      _tablaInspecciones,
      where: 'usuario_id = ? AND estado IN (?, ?)',
      whereArgs: [usuarioId, estadoPendiente, estadoSincronizadoParcial],
      orderBy: 'actualizado_en DESC',
    );

    final hoy = DateTime.now();
    final fechaHoy =
        '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';

    for (final fila in filas) {
      final creadoEn = fila['creado_en']?.toString();

      if (creadoEn == null ||
          creadoEn.length < 10 ||
          creadoEn.substring(0, 10) != fechaHoy) {
        continue;
      }

      final activoGuardado = _decodificarMapa(fila['activo_json']);
      final plantillaGuardada = _decodificarMapa(fila['plantilla_json']);

      if (activoGuardado.isEmpty || plantillaGuardada.isEmpty) {
        continue;
      }

      final idActivoGuardado = obtenerIdentificador(activoGuardado, [
        'id',
        'vehiculo_id',
        'maquinaria_id',
        'codigo',
        'placa',
      ]);

      final idPlantillaGuardada = obtenerIdentificador(plantillaGuardada, [
        'id',
        'plantilla_id',
      ]);

      final tipoActivo = activo['tipo']?.toString().toUpperCase();
      final tipoGuardado = activoGuardado['tipo']?.toString().toUpperCase();

      final mismoTipo =
          tipoActivo == null ||
          tipoGuardado == null ||
          tipoActivo == tipoGuardado;

      if (idActivo == idActivoGuardado &&
          idPlantilla == idPlantillaGuardada &&
          mismoTipo) {
        return {
          ...fila,
          'activo': activoGuardado,
          'plantilla': plantillaGuardada,
          'respuestas': _decodificarLista(fila['respuestas_json']),
        };
      }
    }

    return null;
  }

  // ==========================================================
  // GUARDADO DEL BORRADOR
  // ==========================================================

  Future<void> guardarBorrador({
    required String id,
    required int usuarioId,
    required Map<String, dynamic> activo,
    required Map<String, dynamic> plantilla,
    required num lecturaInicial,
    required List<Map<String, dynamic>> respuestas,
    Uint8List? fotoInicial,
    String? fotoCapturadaEn,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;
    final ahora = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      // Buscar por ID primero permite detectar si el ID ya pertenece
      // a otra cuenta o si se trata de un registro legado sin dueño.
      final existentes = await txn.query(
        _tablaInspecciones,
        columns: [
          'usuario_id',
          'creado_en',
          'uuid_sync',
          'estado',
          'foto_inicial',
          'foto_capturada_en',
        ],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );

      final existe = existentes.isNotEmpty;
      final registro = existe ? existentes.first : <String, Object?>{};

      if (existe) {
        final propietario = registro['usuario_id'];

        if (propietario is! int || propietario != usuarioId) {
          throw Exception(
            'No se puede modificar esta inspección: '
            'no pertenece al usuario autenticado.',
          );
        }
      }

      final estadoActual = registro['estado']?.toString();

      final esEditable =
          estadoActual == null ||
          estadoActual == estadoPendiente ||
          estadoActual == estadoSincronizadoParcial;

      if (existe && !esEditable) {
        throw Exception(
          'La inspección ya está cerrada o completada. '
          'No se permite modificarla desde el formulario.',
        );
      }

      final creadoEn = registro['creado_en']?.toString() ?? ahora;
      final uuidExistente = registro['uuid_sync'];

      final fotoGuardada = fotoInicial ?? registro['foto_inicial'];
      final fechaFotoGuardada =
          fotoCapturadaEn ?? registro['foto_capturada_en'];

      final estadoGuardar = estadoActual == estadoSincronizadoParcial
          ? estadoSincronizadoParcial
          : estadoPendiente;

      final datos = <String, Object?>{
        'id': id,
        'usuario_id': usuarioId,
        'uuid_sync': uuidExistente,
        'activo_json': jsonEncode(activo),
        'plantilla_json': jsonEncode(plantilla),
        'lectura_inicial': lecturaInicial,
        'foto_inicial': fotoGuardada,
        'foto_capturada_en': fechaFotoGuardada,
        'respuestas_json': jsonEncode(respuestas),
        'estado': estadoGuardar,
        'creado_en': creadoEn,
        'actualizado_en': ahora,
        'avance_sincronizado': 0,
      };

      if (!existe) {
        await txn.insert(_tablaInspecciones, datos);
      } else {
        final cantidad = await txn.update(
          _tablaInspecciones,
          datos,
          where: 'id = ? AND usuario_id = ? AND estado IN (?, ?)',
          whereArgs: [
            id,
            usuarioId,
            estadoPendiente,
            estadoSincronizadoParcial,
          ],
        );

        if (cantidad == 0) {
          throw Exception(
            'No se pudo actualizar el borrador. '
            'Verifica el estado actual de la inspección.',
          );
        }
      }
    });
  }

  // ==========================================================
  // SINCRONIZACIÓN PARCIAL
  // ==========================================================

  Future<List<Map<String, Object?>>> obtenerPendientesSincronizacionParcial({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    return db.query(
      _tablaInspecciones,
      where: '''
      usuario_id = ?
      AND avance_sincronizado = 0
      AND estado IN (?, ?, ?)
    ''',
      whereArgs: [
        usuarioId,
        estadoPendiente,
        estadoSincronizadoParcial,
        estadoPreguntasCompletadas,
      ],
      orderBy: 'actualizado_en ASC',
    );
  }

  Future<void> marcarSincronizadoParcial({
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    await db.transaction((txn) async {
      final fila = await _exigirPropiedad(txn, id: id, usuarioId: usuarioId);

      final estadoActual = fila['estado']?.toString();

      if (estadoActual != estadoPendiente &&
          estadoActual != estadoSincronizadoParcial &&
          estadoActual != estadoPreguntasCompletadas) {
        throw Exception(
          'No se puede registrar la sincronización parcial '
          'para una inspección en estado $estadoActual.',
        );
      }

      await txn.update(
        _tablaInspecciones,
        {
          'avance_sincronizado': 1,
          'actualizado_en': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND usuario_id = ?',
        whereArgs: [id, usuarioId],
      );
    });
  }

  Future<int> contarAvancesParcialesPendientes({required int usuarioId}) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final resultado = await db.rawQuery(
      '''
    SELECT COUNT(*) AS total
    FROM $_tablaInspecciones
    WHERE usuario_id = ?
      AND avance_sincronizado = 0
      AND estado IN (?, ?, ?)
    ''',
      [
        usuarioId,
        estadoPendiente,
        estadoSincronizadoParcial,
        estadoPreguntasCompletadas,
      ],
    );

    final total = resultado.first['total'];

    return total is int ? total : int.tryParse('$total') ?? 0;
  }

  Future<void> marcarPreguntasCompletadas({
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final actualizadas = await db.update(
      _tablaInspecciones,
      {
        'estado': estadoPreguntasCompletadas,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND usuario_id = ? AND estado IN (?, ?)',
      whereArgs: [id, usuarioId, estadoPendiente, estadoSincronizadoParcial],
    );

    if (actualizadas == 0) {
      final filas = await db.query(
        _tablaInspecciones,
        columns: ['estado'],
        where: 'id = ? AND usuario_id = ?',
        whereArgs: [id, usuarioId],
        limit: 1,
      );

      if (filas.isNotEmpty &&
          filas.first['estado'] == estadoPreguntasCompletadas) {
        return;
      }

      throw Exception(
        'No se pudo completar el cuestionario. '
        'Verifica que la inspección pertenezca a tu usuario '
        'y siga editable.',
      );
    }
  }

  Future<List<Map<String, Object?>>> obtenerPreguntasCompletadas({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    return db.query(
      _tablaInspecciones,
      where: 'usuario_id = ? AND estado = ?',
      whereArgs: [usuarioId, estadoPreguntasCompletadas],
      orderBy: 'actualizado_en DESC',
    );
  }

  // ==========================================================
  // CIERRE LOCAL
  // ==========================================================

  Future<void> cerrarInspeccionLocal({
    required String id,
    required int usuarioId,
    required num lecturaFinal,
    required Uint8List fotoFinal,
    required Uint8List firma,
    required bool consentimientoAceptado,
    required bool confirmaFirma,
    String observacionesGenerales = '',
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    if (firma.isEmpty) {
      throw Exception('Debes registrar la firma del operador.');
    }

    if (fotoFinal.isEmpty) {
      throw Exception('Debes adjuntar la fotografía de la lectura final.');
    }

    if (!consentimientoAceptado) {
      throw Exception('Debes aceptar el tratamiento de datos.');
    }

    if (!confirmaFirma) {
      throw Exception('Debes confirmar la firma.');
    }

    await db.transaction((txn) async {
      final fila = await _exigirPropiedad(txn, id: id, usuarioId: usuarioId);

      final estadoActual = fila['estado']?.toString();

      if (estadoActual != estadoPreguntasCompletadas &&
          estadoActual != estadoPendiente) {
        throw Exception(
          'La inspección debe tener el cuestionario completado '
          'antes de ejecutar el cierre.',
        );
      }

      final lecturaInicial = fila['lectura_inicial'];

      if (lecturaFinal < 0) {
        throw Exception('La lectura final no puede ser negativa.');
      }

      if (lecturaInicial != null && lecturaFinal < (lecturaInicial as num)) {
        throw Exception('La lectura final no puede ser inferior a la inicial.');
      }

      final ahora = DateTime.now().toIso8601String();

      final cantidad = await txn.update(
        _tablaInspecciones,
        {
          'lectura_final': lecturaFinal,
          'foto_final': fotoFinal,
          'firma': firma,
          'consentimiento_aceptado': 1,
          'confirma_firma': 1,
          'observaciones_generales': observacionesGenerales.trim(),
          'cerrado_en': ahora,
          'estado': estadoCerradaPendienteSync,
          'actualizado_en': ahora,
        },
        where: 'id = ? AND usuario_id = ? AND estado IN (?, ?)',
        whereArgs: [id, usuarioId, estadoPreguntasCompletadas, estadoPendiente],
      );

      if (cantidad == 0) {
        throw Exception(
          'No se pudo cerrar la inspección local. '
          'Verifica su estado actual.',
        );
      }
    });
  }

  // ==========================================================
  // CONSULTAS DE SINCRONIZACIÓN
  // ==========================================================

  Future<List<Map<String, Object?>>> obtenerPendientes({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    return db.query(
      _tablaInspecciones,
      where: 'usuario_id = ? AND estado = ?',
      whereArgs: [usuarioId, estadoPendiente],
      orderBy: 'creado_en ASC',
    );
  }

  Future<List<Map<String, Object?>>> obtenerCerradasPendientesSync({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    return db.query(
      _tablaInspecciones,
      where: 'usuario_id = ? AND estado = ?',
      whereArgs: [usuarioId, estadoCerradaPendienteSync],
      orderBy: 'cerrado_en ASC',
    );
  }

  Future<void> marcarSincronizado({
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final cantidad = await db.update(
      _tablaInspecciones,
      {
        'estado': estadoSincronizado,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND usuario_id = ? AND estado = ?',
      whereArgs: [id, usuarioId, estadoCerradaPendienteSync],
    );

    if (cantidad == 0) {
      final filas = await db.query(
        _tablaInspecciones,
        columns: ['estado'],
        where: 'id = ? AND usuario_id = ?',
        whereArgs: [id, usuarioId],
        limit: 1,
      );

      if (filas.isNotEmpty && filas.first['estado'] == estadoSincronizado) {
        return;
      }

      throw Exception(
        'No se pudo confirmar el cierre local. '
        'Verifica que la inspección pertenezca a tu usuario '
        'y esté cerrada y pendiente de sincronizar.',
      );
    }
  }

  // ==========================================================
  // CONSULTA DE REGISTROS
  // ==========================================================

  Future<Map<String, Object?>?> obtenerPorId({
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final filas = await db.query(
      _tablaInspecciones,
      where: 'id = ? AND usuario_id = ?',
      whereArgs: [id, usuarioId],
      limit: 1,
    );

    return filas.isEmpty ? null : filas.first;
  }

  Future<int> importarHistorialServidor({
    required int usuarioId,
    required List<Map<String, dynamic>> inspecciones,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;
    final ahora = DateTime.now().toIso8601String();
    var importadas = 0;

    String texto(dynamic valor, [String defecto = '']) {
      return valor?.toString() ?? defecto;
    }

    num? numero(dynamic valor) {
      if (valor is num) return valor;
      return num.tryParse(texto(valor));
    }

    await db.transaction((txn) async {
      for (final inspeccion in inspecciones) {
        final servidorId = inspeccion['id'];
        if (servidorId == null) continue;

        final idLocal = 'servidor_$servidorId';
        final uuid = texto(inspeccion['uuid_sync']).trim();

        // No sobrescribir registros locales ni duplicar UUID existentes.
        final existentePorId = await txn.query(
          _tablaInspecciones,
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [idLocal],
          limit: 1,
        );

        if (existentePorId.isNotEmpty) continue;

        if (uuid.isNotEmpty) {
          final existentePorUuid = await txn.query(
            _tablaInspecciones,
            columns: ['id'],
            where: 'uuid_sync = ?',
            whereArgs: [uuid],
            limit: 1,
          );

          if (existentePorUuid.isNotEmpty) continue;
        }

        final maquinariaId = inspeccion['maquinaria_id'];
        final vehiculoId = inspeccion['vehiculo_id'];
        final esMaquinaria = maquinariaId != null;

        final activo = <String, dynamic>{
          'id': esMaquinaria ? maquinariaId : vehiculoId,
          'tipo': esMaquinaria ? 'MAQUINARIA' : 'VEHICULO',
          'codigo': texto(
            esMaquinaria
                ? inspeccion['codigo_maquinaria']
                : inspeccion['placa'],
            'Sin código',
          ),
          'placa': inspeccion['placa'],
          'codigo_maquinaria': inspeccion['codigo_maquinaria'],
          'tipo_maquinaria': inspeccion['tipo_maquinaria'],
          'origen_historial': 'SERVIDOR',
          'foto_contador_inicial': inspeccion['foto_contador_inicial'],
          'foto_contador_final': inspeccion['foto_contador_final'],
          'firma_path': inspeccion['firma_path'],
        };

        final plantilla = <String, dynamic>{
          'id': inspeccion['plantilla_id'],
          'tipo_medicion': inspeccion['tipo_medicion'],
          'origen_historial': 'SERVIDOR',
          'estado_servidor': inspeccion['estado'],
          'hora_inicio': inspeccion['hora_inicio'],
          'hora_fin': inspeccion['hora_fin'],
          'confirmacion_fecha': inspeccion['confirmacion_fecha'],
          'tratamiento_datos_aceptado':
              inspeccion['tratamiento_datos_aceptado'] ?? false,
          'confirma_firma': inspeccion['confirma_firma'] ?? false,
          'usuario_servidor': inspeccion['usuario'],
        };

        final estadoServidor = texto(inspeccion['estado']).toUpperCase();

        // No se marcan inspecciones en proceso como pendientes de envío.
        final estadoLocal = estadoServidor == 'FINALIZADA'
            ? estadoSincronizado
            : estadoServidor == 'EN_PROCESO'
            ? 'EN_PROCESO'
            : estadoSincronizado;

        final fechaCreacion = texto(
          inspeccion['created_at'],
          texto(inspeccion['hora_inicio'], ahora),
        );

        await txn.insert(_tablaInspecciones, {
          'id': idLocal,
          'usuario_id': usuarioId,
          'uuid_sync': uuid.isEmpty ? null : uuid,
          'activo_json': jsonEncode(activo),
          'plantilla_json': jsonEncode(plantilla),
          'lectura_inicial': numero(
            inspeccion['lectura_inicial'] ?? inspeccion['contador_inicial'],
          ),
          'foto_inicial': null,
          'foto_capturada_en': null,
          'lectura_final': numero(
            inspeccion['lectura_final'] ?? inspeccion['contador_final'],
          ),
          'foto_final': null,
          'firma': null,
          'consentimiento_aceptado':
              inspeccion['tratamiento_datos_aceptado'] == true ? 1 : 0,
          'confirma_firma': inspeccion['confirma_firma'] == true ? 1 : 0,
          'observaciones_generales': texto(
            inspeccion['observaciones_generales'],
          ),
          'cerrado_en': inspeccion['hora_fin'],
          'respuestas_json': jsonEncode(<Map<String, dynamic>>[]),
          'estado': estadoLocal,
          'avance_sincronizado': 1,
          'creado_en': fechaCreacion,
          'actualizado_en': texto(inspeccion['hora_fin'], fechaCreacion),
        });

        importadas++;
      }
    });

    return importadas;
  }

  Future<int> contarCerradasPendientesSync({required int usuarioId}) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final resultado = await db.rawQuery(
      '''
      SELECT COUNT(*) AS total
      FROM $_tablaInspecciones
      WHERE usuario_id = ? AND estado = ?
      ''',
      [usuarioId, estadoCerradaPendienteSync],
    );

    final total = resultado.first['total'];

    return total is int ? total : int.tryParse('$total') ?? 0;
  }

  // ==========================================================
  // CACHÉ DE CONFIGURACIÓN POR USUARIO
  // ==========================================================

  Future<void> guardarConfiguracion({
    required int usuarioId,
    required List<Map<String, dynamic>> activos,
    required List<Map<String, dynamic>> plantillas,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    await db.insert(_tablaConfiguracion, {
      'usuario_id': usuarioId,
      'activos_json': jsonEncode(activos),
      'plantillas_json': jsonEncode(plantillas),
      'descargado_en': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> obtenerConfiguracion({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final filas = await db.query(
      _tablaConfiguracion,
      where: 'usuario_id = ?',
      whereArgs: [usuarioId],
      limit: 1,
    );

    if (filas.isEmpty) return null;

    final fila = filas.first;

    return {
      'usuario_id': fila['usuario_id'],
      'descargado_en': fila['descargado_en']?.toString(),
      'activos': _decodificarLista(fila['activos_json']),
      'plantillas': _decodificarLista(fila['plantillas_json']),
    };
  }

  // ==========================================================
  // LISTADO Y DETALLE PARA LA PANTALLA PRINCIPAL
  // ==========================================================

  Future<List<Map<String, dynamic>>> obtenerInspeccionesLocales({
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final filas = await db.query(
      _tablaInspecciones,
      columns: [
        'id',
        'usuario_id',
        'uuid_sync',
        'activo_json',
        'plantilla_json',
        'lectura_inicial',
        'lectura_final',
        'observaciones_generales',
        'estado',
        'avance_sincronizado',
        'creado_en',
        'actualizado_en',
        'cerrado_en',
      ],
      where: 'usuario_id = ?',
      whereArgs: [usuarioId],
      orderBy: 'actualizado_en DESC',
    );

    return filas.map((fila) {
      return {
        ...fila,
        'activo': _decodificarMapa(fila['activo_json']),
        'plantilla': _decodificarMapa(fila['plantilla_json']),
      };
    }).toList();
  }

  Future<Map<String, dynamic>?> obtenerDetallePorId({
    required String id,
    required int usuarioId,
  }) async {
    final fila = await obtenerPorId(id: id, usuarioId: usuarioId);

    if (fila == null) return null;

    return {
      ...fila,
      'activo': _decodificarMapa(fila['activo_json']),
      'plantilla': _decodificarMapa(fila['plantilla_json']),
      'respuestas': _decodificarLista(fila['respuestas_json']),
    };
  }

  Future<void> guardarAnomaliaLocal({
    required String id,
    required String inspeccionId,
    required int usuarioId,
    required String uuidSync,
    required String titulo,
    required String descripcion,
    required String prioridad,
    required List<Uint8List> fotos,
  }) async {
    _validarUsuarioId(usuarioId);

    final tituloNormalizado = titulo.trim();
    final uuidNormalizado = uuidSync.trim();
    final prioridadNormalizada = prioridad.trim().toUpperCase();

    if (tituloNormalizado.isEmpty) {
      throw Exception('El título de la anomalía es obligatorio.');
    }

    if (tituloNormalizado.length > 200) {
      throw Exception('El título no puede superar los 200 caracteres.');
    }

    if (id.trim().isEmpty ||
        inspeccionId.trim().isEmpty ||
        uuidNormalizado.isEmpty) {
      throw Exception('La anomalía debe tener identificadores válidos.');
    }

    const prioridadesValidas = {'BAJA', 'MEDIA', 'ALTA', 'CRITICA'};

    if (!prioridadesValidas.contains(prioridadNormalizada)) {
      throw Exception('La prioridad seleccionada no es válida.');
    }

    if (fotos.any((foto) => foto.isEmpty)) {
      throw Exception('Una de las fotografías está vacía.');
    }

    final db = await database;
    final ahora = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final inspeccion = await _exigirPropiedad(
        txn,
        id: inspeccionId,
        usuarioId: usuarioId,
      );

      final estadoInspeccion = inspeccion['estado']?.toString().trim();

      // Se permiten anomalías mientras el cuestionario esté
      // completado o la inspección esté sincronizada parcialmente.
      const estadosPermitidos = {
        estadoPreguntasCompletadas,
        'SINCRONIZADO_PARCIAL',
      };

      if (!estadosPermitidos.contains(estadoInspeccion)) {
        throw Exception(
          'No puedes reportar anomalías en el estado actual '
          'de la inspección.',
        );
      }

      await txn.insert(_tablaAnomalias, {
        'id': id,
        'inspeccion_id': inspeccionId,
        'usuario_id': usuarioId,
        'uuid_sync': uuidNormalizado,
        'titulo': tituloNormalizado,
        'descripcion': descripcion.trim(),
        'prioridad': prioridadNormalizada,
        'estado': 'PENDIENTE_SYNC',
        'creado_en': ahora,
        'actualizado_en': ahora,
      });

      for (var i = 0; i < fotos.length; i++) {
        await txn.insert(_tablaAnomaliaFotos, {
          'id': '${id}_foto_$i',
          'anomalia_id': id,
          'usuario_id': usuarioId,
          'foto': fotos[i],
          'creado_en': ahora,
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> obtenerAnomaliasPendientesSyncUsuario({
    required int usuarioId,
  }) async {
    final db = await database;

    final resultados = await db.rawQuery(
      '''
    SELECT
      a.id,
      a.uuid_sync,
      a.inspeccion_id,
      a.usuario_id,
      a.titulo,
      a.descripcion,
      a.prioridad,
      p.uuid_sync AS uuid_inspeccion
    FROM anomalias_locales AS a
    INNER JOIN preoperacionales AS p
      ON p.id = a.inspeccion_id
    WHERE a.usuario_id = ?
      AND a.estado = ?
      AND a.uuid_sync IS NOT NULL
      AND TRIM(a.uuid_sync) != ''
      AND p.uuid_sync IS NOT NULL
      AND TRIM(p.uuid_sync) != ''
    ORDER BY a.creado_en ASC
    ''',
      [usuarioId, 'PENDIENTE_SYNC'],
    );

    final anomalias = <Map<String, dynamic>>[];

    for (final fila in resultados) {
      final anomalia = Map<String, dynamic>.from(fila);

      final fotos = await db.query(
        'anomalia_fotos_locales',
        where: 'anomalia_id = ?',
        whereArgs: [anomalia['id']],
        orderBy: 'id ASC',
      );

      anomalia['fotos'] = fotos
          .map((foto) => Map<String, dynamic>.from(foto))
          .toList();

      anomalias.add(anomalia);
    }

    return anomalias;
  }

  Future<int> contarAnomaliasPendientesSync({required int usuarioId}) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final resultado = await db.rawQuery(
      '''
    SELECT COUNT(*) AS total
    FROM $_tablaAnomalias
    WHERE usuario_id = ?
      AND estado = ?
    ''',
      [usuarioId, 'PENDIENTE_SYNC'],
    );

    final total = resultado.first['total'];
    return total is int ? total : int.tryParse('$total') ?? 0;
  }

  Future<List<Map<String, dynamic>>> obtenerAnomaliasPorInspeccion({
    required String inspeccionId,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    // Verificar propiedad de la inspección.
    await _exigirPropiedad(db, id: inspeccionId, usuarioId: usuarioId);

    final filas = await db.query(
      _tablaAnomalias,
      where: 'inspeccion_id = ? AND usuario_id = ?',
      whereArgs: [inspeccionId, usuarioId],
      orderBy: 'creado_en ASC',
    );

    final resultado = <Map<String, dynamic>>[];

    for (final fila in filas) {
      final fotos = await db.query(
        _tablaAnomaliaFotos,
        where: 'anomalia_id = ? AND usuario_id = ?',
        whereArgs: [fila['id'], usuarioId],
        orderBy: 'creado_en ASC',
      );

      resultado.add({...fila, 'fotos': fotos});
    }

    return resultado;
  }

  Future<List<Map<String, dynamic>>> obtenerAnomaliasPendientesSync({
    required String inspeccionId,
    required int usuarioId,
  }) async {
    final anomalias = await obtenerAnomaliasPorInspeccion(
      inspeccionId: inspeccionId,
      usuarioId: usuarioId,
    );

    return anomalias
        .where((anomalia) => anomalia['estado'] == 'PENDIENTE_SYNC')
        .toList();
  }

  Future<void> marcarAnomaliaSincronizada({
    required String id,
    required int usuarioId,
  }) async {
    _validarUsuarioId(usuarioId);

    final db = await database;

    final cantidad = await db.update(
      _tablaAnomalias,
      {
        'estado': 'SINCRONIZADA',
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND usuario_id = ? AND estado = ?',
      whereArgs: [id, usuarioId, 'PENDIENTE_SYNC'],
    );

    if (cantidad == 0) {
      final filas = await db.query(
        _tablaAnomalias,
        columns: ['estado'],
        where: 'id = ? AND usuario_id = ?',
        whereArgs: [id, usuarioId],
        limit: 1,
      );

      if (filas.isNotEmpty && filas.first['estado'] == 'SINCRONIZADA') {
        return;
      }

      throw Exception('No se pudo actualizar el estado de la anomalía.');
    }
  }
  // ==========================================================
  // UTILIDADES DE DECODIFICACIÓN
  // ==========================================================

  static Map<String, dynamic> _decodificarMapa(Object? contenido) {
    if (contenido is! String || contenido.isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(contenido);

      if (decoded is! Map) return <String, dynamic>{};

      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      return <String, dynamic>{};
    } on TypeError {
      return <String, dynamic>{};
    }
  }

  static List<Map<String, dynamic>> _decodificarLista(Object? contenido) {
    if (contenido is! String || contenido.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    try {
      final decoded = jsonDecode(contenido);

      if (decoded is! List) return <Map<String, dynamic>>[];

      return decoded
          .whereType<Map>()
          .map((elemento) => Map<String, dynamic>.from(elemento))
          .toList();
    } on FormatException {
      return <Map<String, dynamic>>[];
    } on TypeError {
      return <Map<String, dynamic>>[];
    }
  }
}
