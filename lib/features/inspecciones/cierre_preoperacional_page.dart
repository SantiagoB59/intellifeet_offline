import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/storage/preoperacional_local_db.dart';
import 'widgets/firma_pad.dart';
import 'widgets/marca_agua.dart';

/// Cierre del preoperacional.
///
/// 1. Registra la lectura final y su fotografía con marca de agua.
/// 2. Captura la firma y los consentimientos del operador.
/// 3. Guarda el cierre local para sincronizarlo posteriormente.
///
/// Cada operación se valida contra el usuario autenticado.
class CierrePreoperacionalPage extends StatefulWidget {
  final String idLocal;
  final String operadorNombre;
  final int usuarioId;

  const CierrePreoperacionalPage({
    super.key,
    required this.idLocal,
    required this.operadorNombre,
    required this.usuarioId,
  });

  @override
  State<CierrePreoperacionalPage> createState() =>
      _CierrePreoperacionalPageState();
}

class _CierrePreoperacionalPageState extends State<CierrePreoperacionalPage> {
  final _lecturaController = TextEditingController();
  final _observacionesController = TextEditingController();
  final _firmaKey = GlobalKey<FirmaPadState>();
  final _picker = ImagePicker();

  Map<String, dynamic>? _detalle;

  bool _cargando = true;
  bool _guardando = false;
  bool _capturando = false;

  String? _error;

  Uint8List? _fotoFinal;
  DateTime? _fotoCapturadaEn;

  bool _tratamientoDatosAceptado = false;
  bool _confirmaFirma = false;

  @override
  void initState() {
    super.initState();
    _cargarDetalle();
  }

  @override
  void dispose() {
    _lecturaController.dispose();
    _observacionesController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _activo =>
      (_detalle?['activo'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};

  Map<String, dynamic> get _plantilla =>
      (_detalle?['plantilla'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};

  String get _tipoMedicion =>
      _plantilla['tipo_medicion']?.toString().toUpperCase() ?? 'NINGUNO';

  String get _unidad => _tipoMedicion == 'HOROMETRO' ? 'h' : 'km';

  num get _lecturaInicial {
    final valor = _detalle?['lectura_inicial'];

    if (valor is num) return valor;

    return num.tryParse(valor?.toString() ?? '') ?? 0;
  }

  Future<void> _cargarDetalle() async {
    try {
      if (widget.usuarioId <= 0) {
        throw Exception('No se pudo identificar al usuario autenticado.');
      }

      final detalle = await PreoperacionalLocalDb.instance.obtenerDetallePorId(
        id: widget.idLocal,
        usuarioId: widget.usuarioId,
      );

      if (!mounted) return;

      if (detalle == null) {
        setState(() {
          _error =
              'No se encontró la inspección para el usuario actual. '
              'Puede pertenecer a otra cuenta o ser un registro antiguo '
              'pendiente de recuperar.';
          _cargando = false;
        });
        return;
      }

      setState(() {
        _detalle = detalle;
        _cargando = false;

        _lecturaController.text = _lecturaInicial > 0
            ? _lecturaInicial.toString()
            : '';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = _limpiarError(e);
        _cargando = false;
      });
    }
  }

  Future<void> _tomarFotoFinal() async {
    if (_capturando || _guardando) return;

    final lectura = num.tryParse(
      _lecturaController.text.trim().replaceAll(',', '.'),
    );

    if (lectura == null || lectura <= 0) {
      setState(() {
        _error = 'Ingresa primero una lectura final válida.';
      });
      return;
    }

    if (lectura < _lecturaInicial) {
      setState(() {
        _error =
            'La lectura final no puede ser inferior a la inicial '
            '($_lecturaInicial $_unidad).';
      });
      return;
    }

    setState(() {
      _capturando = true;
      _error = null;
    });

    try {
      final XFile? foto = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      if (foto == null) return;

      final bytes = await foto.readAsBytes();
      final fecha = DateTime.now();

      final bytesConMarca = MarcaDeAgua.aplicar(
        bytes: bytes,
        titulo: 'INTELLIFEET | CIERRE PREOPERACIONAL',
        lineas: [
          'Activo: ${_activo['nombre'] ?? 'Activo'}',
          'Lectura final: ${_lecturaController.text.trim()} $_unidad',
          'Operador: ${widget.operadorNombre}',
          'Fecha y hora: ${MarcaDeAgua.formatearFechaHora(fecha)}',
        ],
      );

      if (!mounted) return;

      setState(() {
        _fotoFinal = bytesConMarca;
        _fotoCapturadaEn = fecha;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'No se pudo tomar la fotografía: ${_limpiarError(e)}';
      });
    } finally {
      if (mounted) {
        setState(() => _capturando = false);
      }
    }
  }

  Future<void> _confirmarCierre() async {
    if (_guardando || _cargando || _detalle == null) return;

    if (widget.usuarioId <= 0) {
      setState(() {
        _error = 'No se pudo identificar al usuario autenticado.';
      });
      return;
    }

    final lectura = num.tryParse(
      _lecturaController.text.trim().replaceAll(',', '.'),
    );

    if (lectura == null || lectura <= 0) {
      setState(() {
        _error = 'Ingresa una lectura final válida.';
      });
      return;
    }

    if (lectura < _lecturaInicial) {
      setState(() {
        _error =
            'La lectura final no puede ser inferior a la inicial '
            '($_lecturaInicial $_unidad).';
      });
      return;
    }

    if (_fotoFinal == null || _fotoFinal!.isEmpty) {
      setState(() {
        _error = 'Debes tomar la fotografía de la lectura final.';
      });
      return;
    }

    if (!_tratamientoDatosAceptado) {
      setState(() {
        _error = 'Debes aceptar el tratamiento de datos personales.';
      });
      return;
    }

    if (!_confirmaFirma) {
      setState(() {
        _error = 'Debes confirmar que la firma es tuya.';
      });
      return;
    }

    final firma = await _firmaKey.currentState?.exportarPng();

    if (!mounted) return;

    if (firma == null || firma.isEmpty) {
      setState(() {
        _error = 'Debes registrar tu firma antes de finalizar.';
      });
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      await PreoperacionalLocalDb.instance.cerrarInspeccionLocal(
        id: widget.idLocal,
        usuarioId: widget.usuarioId,
        lecturaFinal: lectura,
        fotoFinal: _fotoFinal!,
        firma: firma,
        consentimientoAceptado: _tratamientoDatosAceptado,
        confirmaFirma: _confirmaFirma,
        observacionesGenerales: _observacionesController.text,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Inspección cerrada localmente. '
            'Quedó lista para sincronizar cuando tengas internet.',
          ),
        ),
      );

      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = _limpiarError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  String _limpiarError(Object error) {
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('ArgumentError: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cierre del preoperacional')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: _cargando
              ? const Center(child: CircularProgressIndicator())
              : _detalle == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error ?? 'Inspección no disponible.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _construirEncabezado(),
                    const SizedBox(height: 20),
                    _construirSeccionLectura(),
                    const SizedBox(height: 20),
                    _construirSeccionFirma(),
                    const SizedBox(height: 20),
                    _construirSeccionObservaciones(),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _guardando || _capturando
                            ? null
                            : _confirmarCierre,
                        icon: _guardando
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.verified_outlined),
                        label: Text(
                          _guardando
                              ? 'Guardando cierre...'
                              : 'Confirmar cierre de la inspección',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'El cierre se guarda en el dispositivo. '
                      'La inspección se enviará al servidor cuando '
                      'tengas conexión a internet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _construirEncabezado() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF101B33),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _activo['nombre']?.toString() ?? 'Activo',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _plantilla['nombre']?.toString() ?? '',
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 5),
          Text(
            'Lectura inicial: $_lecturaInicial $_unidad',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _construirSeccionLectura() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.speed, color: Color(0xFF101B33)),
                SizedBox(width: 8),
                Text(
                  'Lectura final',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _lecturaController,
              enabled: !_guardando && !_capturando,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _tipoMedicion == 'HOROMETRO'
                    ? 'Horómetro final'
                    : 'Kilometraje final',
                suffixText: _unidad,
                prefixIcon: const Icon(Icons.edit_outlined),
              ),
              onChanged: (_) {
                if (_fotoFinal != null) {
                  setState(() {
                    _fotoFinal = null;
                    _fotoCapturadaEn = null;
                    _error =
                        'La lectura cambió. Toma nuevamente la fotografía '
                        'para que coincida con el valor final.';
                  });
                }
              },
            ),
            const SizedBox(height: 14),
            const Text(
              'Fotografía de la lectura final obligatoria',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_fotoFinal != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  _fotoFinal!,
                  width: double.infinity,
                  fit: BoxFit.contain,
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.camera_alt, size: 42),
                    SizedBox(height: 8),
                    Text('Debes tomar una fotografía con la cámara'),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _capturando || _guardando ? null : _tomarFotoFinal,
                icon: const Icon(Icons.camera_alt),
                label: Text(
                  _capturando
                      ? 'Procesando fotografía...'
                      : _fotoFinal == null
                      ? 'Abrir cámara'
                      : 'Tomar otra fotografía',
                ),
              ),
            ),
            if (_fotoCapturadaEn != null) ...[
              const SizedBox(height: 6),
              Text(
                'Capturada: '
                '${MarcaDeAgua.formatearFechaHora(_fotoCapturadaEn!)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _construirSeccionFirma() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.draw_outlined, color: Color(0xFF101B33)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Firma del operador',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  onPressed: _guardando
                      ? null
                      : () => _firmaKey.currentState?.limpiar(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Limpiar'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FirmaPad(key: _firmaKey),
            const SizedBox(height: 10),
            CheckboxListTile(
              value: _tratamientoDatosAceptado,
              onChanged: _guardando
                  ? null
                  : (valor) {
                      setState(() {
                        _tratamientoDatosAceptado = valor ?? false;
                      });
                    },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Acepto el tratamiento de mis datos personales '
                'con fines de verificación de la inspección.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            CheckboxListTile(
              value: _confirmaFirma,
              onChanged: _guardando
                  ? null
                  : (valor) {
                      setState(() {
                        _confirmaFirma = valor ?? false;
                      });
                    },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Confirmo que esta es mi firma y que la información '
                'registrada en la inspección es verdadera.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirSeccionObservaciones() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.notes, color: Color(0xFF101B33)),
                SizedBox(width: 8),
                Text(
                  'Observaciones generales',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Opcional. Se enviarán junto con la inspección.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _observacionesController,
              enabled: !_guardando,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Escribe aquí cualquier novedad adicional...',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
