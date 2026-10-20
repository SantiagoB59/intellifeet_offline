import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

class InicioPreoperacionalDialog extends StatefulWidget {
  final Map<String, dynamic> activo;
  final Map<String, dynamic> plantilla;
  final String operadorNombre;

  const InicioPreoperacionalDialog({
    super.key,
    required this.activo,
    required this.plantilla,
    required this.operadorNombre,
  });

  @override
  State<InicioPreoperacionalDialog> createState() =>
      _InicioPreoperacionalDialogState();
}

class _InicioPreoperacionalDialogState
    extends State<InicioPreoperacionalDialog> {
  final _formKey = GlobalKey<FormState>();
  final _lecturaController = TextEditingController();
  final _picker = ImagePicker();

  Uint8List? _fotoConMarca;
  DateTime? _fechaCaptura;
  bool _capturando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lecturaController.text = widget.activo['lectura_actual']?.toString() ?? '';
  }

  Future<void> _tomarFotografia() async {
    if (_capturando) return;

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
      final imagen = img.decodeImage(bytes);

      if (imagen == null) {
        throw Exception('No fue posible procesar la fotografía.');
      }

      final fecha = DateTime.now();
      final lectura = _lecturaController.text.trim();
      final activo = widget.activo['nombre']?.toString() ?? 'Activo';

      // Franja de marca de agua incorporada a la imagen.
      final altoFranja = (imagen.height * 0.23).round().clamp(100, 190);

      img.fillRect(
        imagen,
        x1: 0,
        y1: imagen.height - altoFranja,
        x2: imagen.width - 1,
        y2: imagen.height - 1,
        color: img.ColorRgba8(16, 27, 51, 220),
      );

      final fechaTexto =
          '${fecha.day.toString().padLeft(2, '0')}/'
          '${fecha.month.toString().padLeft(2, '0')}/'
          '${fecha.year} '
          '${fecha.hour.toString().padLeft(2, '0')}:'
          '${fecha.minute.toString().padLeft(2, '0')}:'
          '${fecha.second.toString().padLeft(2, '0')}';

      final escala = (imagen.width / 900).clamp(1, 3).toInt();
      final fuente = escala == 1
          ? img.arial14
          : escala == 2
          ? img.arial24
          : img.arial48;

      final x = (imagen.width * 0.025).round();
      var y = imagen.height - altoFranja + 10;

      void escribir(String texto) {
        img.drawString(
          imagen,
          texto,
          font: fuente,
          x: x,
          y: y,
          color: img.ColorRgb8(255, 255, 255),
        );
        y += (fuente.lineHeight * 1.15).round();
      }

      escribir('INTELLIFEET | EVIDENCIA PREOPERACIONAL');
      escribir('Activo: $activo');
      escribir('Lectura inicial: $lectura');
      escribir('Operador: ${widget.operadorNombre}');
      escribir('Fecha y hora: $fechaTexto');

      final bytesFinales = Uint8List.fromList(
        img.encodeJpg(imagen, quality: 90),
      );

      if (!mounted) return;

      setState(() {
        _fotoConMarca = bytesFinales;
        _fechaCaptura = fecha;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo tomar la fotografía: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _capturando = false);
      }
    }
  }

  void _continuar() {
    if (!_formKey.currentState!.validate()) return;

    if (_fotoConMarca == null || _fechaCaptura == null) {
      setState(() {
        _error = 'Debes tomar la fotografía con la cámara.';
      });
      return;
    }

    Navigator.of(context).pop({
      'lecturaInicial': num.parse(
        _lecturaController.text.trim().replaceAll(',', '.'),
      ),
      'fotoBytes': _fotoConMarca!,
      'capturadaEn': _fechaCaptura!.toIso8601String(),
    });
  }

  @override
  void dispose() {
    _lecturaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final medicion = widget.plantilla['tipo_medicion']?.toString() ?? 'LECTURA';

    return AlertDialog(
      title: const Text('Inicio del preoperacional'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.activo['nombre']?.toString() ?? 'Activo',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _lecturaController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: medicion == 'HOROMETRO'
                        ? 'Horómetro inicial'
                        : 'Kilometraje inicial',
                    border: const OutlineInputBorder(),
                    suffixText: medicion == 'HOROMETRO' ? 'h' : 'km',
                  ),
                  validator: (value) {
                    final lectura = num.tryParse(
                      (value ?? '').trim().replaceAll(',', '.'),
                    );

                    if (lectura == null || lectura < 0) {
                      return 'Ingresa una lectura válida.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),
                const Text(
                  'Fotografía inicial obligatoria',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (_fotoConMarca != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      _fotoConMarca!,
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
                    onPressed: _capturando ? null : _tomarFotografia,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(
                      _capturando
                          ? 'Procesando fotografía...'
                          : _fotoConMarca == null
                          ? 'Abrir cámara'
                          : 'Tomar otra fotografía',
                    ),
                  ),
                ),
                if (_fechaCaptura != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Capturada: ${_fechaCaptura!.toLocal()}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _capturando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _capturando ? null : _continuar,
          child: const Text('Continuar'),
        ),
      ],
    );
  }
}
