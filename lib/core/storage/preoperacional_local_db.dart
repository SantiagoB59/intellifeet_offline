import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PreoperacionalLocalDb {
  PreoperacionalLocalDb._();

  static final PreoperacionalLocalDb instance = PreoperacionalLocalDb._();

  static Database? _database;

  static const String estadoPendiente = 'PENDIENTE';
  static const String estadoCerradaPendienteSync = 'CERRADA_PENDIENTE_SYNC';
  static const String estadoSincronizado = 'SINCRONIZADO';
  static const String estadoPreguntasCompletadas = 'PREGUNTAS_COMPLETADAS';

  Future<Database> get database async {
    if (_database != null) return _database!;

    final directorio = await getDatabasesPath();
    final ruta = p.join(directorio, 'intellifeet_offline.db');

    _database = await openDatabase(
      ruta,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE preoperacionales (
            id TEXT PRIMARY KEY,
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
            creado_en TEXT NOT NULL,
            actualizado_en TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS
          idx_preoperacionales_uuid_sync
          ON preoperacionales(uuid_sync)
          WHERE uuid_sync IS NOT NULL
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE preoperacionales ADD COLUMN uuid_sync TEXT',
          );

          await db.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS
            idx_preoperacionales_uuid_sync
            ON preoperacionales(uuid_sync)
            WHERE uuid_sync IS NOT NULL
          ''');
        }

        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE preoperacionales ADD COLUMN lectura_final REAL',
          );
          await db.execute(
            'ALTER TABLE preoperacionales ADD COLUMN foto_final BLOB',
          );
          await db.execute(
            'ALTER TABLE preoperacionales ADD COLUMN firma BLOB',
          );
          await db.execute('''
            ALTER TABLE preoperacionales
            ADD COLUMN consentimiento_aceptado INTEGER NOT NULL DEFAULT 0
          ''');
          await db.execute('''
            ALTER TABLE preoperacionales
            ADD COLUMN confirma_firma INTEGER NOT NULL DEFAULT 0
          ''');
          await db.execute('''
            ALTER TABLE preoperacionales
            ADD COLUMN observaciones_generales TEXT NOT NULL DEFAULT ''
          ''');
          await db.execute(
            'ALTER TABLE preoperacionales ADD COLUMN cerrado_en TEXT',
          );
        }
      },
    );

    return _database!;
  }

  /// Guarda el UUID estable que se enviará al backend.
  /// No modifica el ID local ni los datos del borrador.
  Future<void> guardarUuidSync({
    required String idLocal,
    required String uuidSync,
  }) async {
    final db = await database;

    final cantidad = await db.update(
      'preoperacionales',
      {'uuid_sync': uuidSync},
      where: 'id = ? AND estado = ?',
      whereArgs: [idLocal, estadoPendiente],
    );

    if (cantidad == 0) {
      final filas = await db.query(
        'preoperacionales',
        columns: ['uuid_sync', 'estado'],
        where: 'id = ?',
        whereArgs: [idLocal],
        limit: 1,
      );

      if (filas.isEmpty) {
        throw Exception(
          'No se encontró la inspección local para guardar su UUID.',
        );
      }

      final estado = filas.first['estado']?.toString();
      final uuidExistente = filas.first['uuid_sync']?.toString();

      if (uuidExistente == uuidSync &&
          (estado == estadoCerradaPendienteSync ||
              estado == estadoSincronizado)) {
        return;
      }

      throw Exception(
        'No se puede cambiar el UUID de una inspección que no está '
        'en estado editable.',
      );
    }
  }

  /// Busca un borrador editable por activo y plantilla.
  Future<Map<String, dynamic>?> obtenerBorradorPorActivoPlantilla({
    required Map<String, dynamic> activo,
    required Map<String, dynamic> plantilla,
  }) async {
    final db = await database;

    final filas = await db.query(
      'preoperacionales',
      where: 'estado = ?',
      whereArgs: [estadoPendiente],
      orderBy: 'actualizado_en DESC',
    );

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

    if (idActivo == null || idPlantilla == null) return null;

    for (final fila in filas) {
      final activoGuardado = Map<String, dynamic>.from(
        jsonDecode(fila['activo_json'] as String) as Map,
      );

      final plantillaGuardada = Map<String, dynamic>.from(
        jsonDecode(fila['plantilla_json'] as String) as Map,
      );

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

      final mismoTipo =
          activo['tipo'] == null ||
          activoGuardado['tipo'] == null ||
          activo['tipo'].toString() == activoGuardado['tipo'].toString();

      if (idActivo == idActivoGuardado &&
          idPlantilla == idPlantillaGuardada &&
          mismoTipo) {
        final respuestas =
            jsonDecode(fila['respuestas_json'] as String) as List;

        return {
          ...fila,
          'activo': activoGuardado,
          'plantilla': plantillaGuardada,
          'respuestas': respuestas
              .whereType<Map>()
              .map((r) => Map<String, dynamic>.from(r))
              .toList(),
        };
      }
    }

    return null;
  }

  /// Guarda o actualiza un borrador, siempre que siga editable.
  Future<void> guardarBorrador({
    required String id,
    required Map<String, dynamic> activo,
    required Map<String, dynamic> plantilla,
    required num lecturaInicial,
    required List<Map<String, dynamic>> respuestas,
    Uint8List? fotoInicial,
    String? fotoCapturadaEn,
  }) async {
    final db = await database;
    final ahora = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final existentes = await txn.query(
        'preoperacionales',
        columns: ['creado_en', 'uuid_sync', 'estado'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );

      if (existentes.isNotEmpty) {
        final estado = existentes.first['estado']?.toString();

        if (estado != estadoPendiente) {
          throw Exception(
            'La inspección ya está cerrada o sincronizada. '
            'No se permite modificarla.',
          );
        }
      }

      final creadoEn = existentes.isNotEmpty
          ? existentes.first['creado_en'] as String
          : ahora;

      final uuidExistente = existentes.isNotEmpty
          ? existentes.first['uuid_sync']
          : null;

      final datos = <String, Object?>{
        'id': id,
        'uuid_sync': uuidExistente,
        'activo_json': jsonEncode(activo),
        'plantilla_json': jsonEncode(plantilla),
        'lectura_inicial': lecturaInicial,
        'foto_inicial': fotoInicial,
        'foto_capturada_en': fotoCapturadaEn,
        'respuestas_json': jsonEncode(respuestas),
        'estado': estadoPendiente,
        'creado_en': creadoEn,
        'actualizado_en': ahora,
      };

      if (existentes.isEmpty) {
        await txn.insert('preoperacionales', datos);
      } else {
        await txn.update(
          'preoperacionales',
          datos,
          where: 'id = ? AND estado = ?',
          whereArgs: [id, estadoPendiente],
        );
      }
    });
  }

  /// Marca que el cuestionario terminó, sin cerrar la inspección.
  Future<void> marcarPreguntasCompletadas(String id) async {
    final db = await database;

    final cantidad = await db.update(
      'preoperacionales',
      {
        'estado': estadoPreguntasCompletadas,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND estado = ?',
      whereArgs: [id, estadoPendiente],
    );

    if (cantidad == 0) {
      final inspeccion = await obtenerPorId(id);

      if (inspeccion == null) {
        throw Exception('No se encontró la inspección local.');
      }

      if (inspeccion['estado'] == estadoPreguntasCompletadas) {
        return;
      }

      throw Exception(
        'No se pudo completar el cuestionario. '
        'Verifica el estado de la inspección.',
      );
    }
  }

  /// Consulta las inspecciones con preguntas completadas
  /// que todavía no tienen lectura final ni firma.
  Future<List<Map<String, Object?>>> obtenerPreguntasCompletadas() async {
    final db = await database;

    return db.query(
      'preoperacionales',
      where: 'estado = ?',
      whereArgs: [estadoPreguntasCompletadas],
      orderBy: 'actualizado_en DESC',
    );
  }

  /// Cierra localmente una inspección validada.
  ///
  /// Una vez cerrada, guardarBorrador() ya no puede modificarla.
  Future<void> cerrarInspeccionLocal({
    required String id,
    required num lecturaFinal,
    required Uint8List? fotoFinal,
    required Uint8List firma,
    required bool consentimientoAceptado,
    required bool confirmaFirma,
    String observacionesGenerales = '',
  }) async {
    final db = await database;

    if (firma.isEmpty) {
      throw Exception('Debes registrar la firma del operador.');
    }

    if (!consentimientoAceptado) {
      throw Exception('Debes aceptar el tratamiento de datos.');
    }

    if (!confirmaFirma) {
      throw Exception('Debes confirmar la firma.');
    }

    await db.transaction((txn) async {
      final filas = await txn.query(
        'preoperacionales',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );

      if (filas.isEmpty) {
        throw Exception('No se encontró la inspección local.');
      }

      final fila = filas.first;
      final estadoActual = fila['estado']?.toString();

      if (estadoActual != estadoPreguntasCompletadas &&
          estadoActual != estadoPendiente) {
        throw Exception('Esta inspección ya fue cerrada o sincronizada.');
      }

      final lecturaInicial = fila['lectura_inicial'];

      if (lecturaFinal < 0) {
        throw Exception('La lectura final no puede ser negativa.');
      }

      if (lecturaInicial != null && lecturaFinal < (lecturaInicial as num)) {
        throw Exception('La lectura final no puede ser inferior a la inicial.');
      }

      final plantilla = jsonDecode(fila['plantilla_json'] as String) as Map;

      final tipoMedicion =
          plantilla['tipo_medicion']?.toString().toUpperCase() ?? '';

      final requiereMedicion = tipoMedicion != 'NINGUNO';

      if (requiereMedicion && fotoFinal == null) {
        throw Exception('Debes adjuntar la fotografía de la lectura final.');
      }

      await txn.update(
        'preoperacionales',
        {
          'lectura_final': requiereMedicion ? lecturaFinal : null,
          'foto_final': requiereMedicion ? fotoFinal : null,
          'firma': firma,
          'consentimiento_aceptado': 1,
          'confirma_firma': 1,
          'observaciones_generales': observacionesGenerales.trim(),
          'cerrado_en': DateTime.now().toIso8601String(),
          'estado': estadoCerradaPendienteSync,
          'actualizado_en': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND estado IN (?, ?)',
        whereArgs: [id, estadoPreguntasCompletadas, estadoPendiente],
      );
    });
  }

  /// Devuelve todos los registros pendientes, para compatibilidad.
  ///
  /// El servicio de sincronización deberá migrar a
  /// obtenerCerradasPendientesSync() antes de enviar cierres definitivos.
  Future<List<Map<String, Object?>>> obtenerPendientes() async {
    final db = await database;

    return db.query(
      'preoperacionales',
      where: 'estado = ?',
      whereArgs: [estadoPendiente],
      orderBy: 'creado_en ASC',
    );
  }

  /// Devuelve únicamente inspecciones cerradas que esperan confirmación.
  Future<List<Map<String, Object?>>> obtenerCerradasPendientesSync() async {
    final db = await database;

    return db.query(
      'preoperacionales',
      where: 'estado = ?',
      whereArgs: [estadoCerradaPendienteSync],
      orderBy: 'cerrado_en ASC',
    );
  }

  /// Marca como sincronizada una inspección cerrada.
  Future<void> marcarSincronizado(String id) async {
    final db = await database;

    final cantidad = await db.update(
      'preoperacionales',
      {
        'estado': estadoSincronizado,
        'actualizado_en': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND estado = ?',
      whereArgs: [id, estadoCerradaPendienteSync],
    );

    if (cantidad == 0) {
      throw Exception(
        'No se pudo confirmar el cierre local. '
        'Verifica que la inspección esté cerrada y pendiente de sincronizar.',
      );
    }
  }

  /// Obtiene una inspección local, incluidos sus archivos binarios.
  Future<Map<String, Object?>?> obtenerPorId(String id) async {
    final db = await database;
    final filas = await db.query(
      'preoperacionales',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    return filas.isEmpty ? null : filas.first;
  }
}
