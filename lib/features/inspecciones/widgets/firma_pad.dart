import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Lienzo para capturar la firma del operador.
///
/// Replica el mecanismo de la web: un canvas con trazo negro
/// sobre fondo blanco que se exporta como PNG de 900x300.
class FirmaPad extends StatefulWidget {
  const FirmaPad({super.key, this.alto = 190});

  final double alto;

  @override
  State<FirmaPad> createState() => FirmaPadState();
}

class FirmaPadState extends State<FirmaPad> {
  // Mismo tamaño de exportación que el canvas de la web.
  static const double _exportAncho = 900;
  static const double _exportAlto = 300;

  final List<List<Offset>> _trazos = [];
  List<Offset>? _trazoActual;
  Size _tamano = Size.zero;

  bool get estaVacia =>
      _trazos.isEmpty && (_trazoActual == null || _trazoActual!.length < 2);

  void limpiar() {
    setState(() {
      _trazos.clear();
      _trazoActual = null;
    });
  }

  Offset _limitar(Offset punto) {
    return Offset(
      punto.dx.clamp(0.0, _tamano.width),
      punto.dy.clamp(0.0, _tamano.height),
    );
  }

  void _iniciar(DragStartDetails detalles) {
    _trazoActual = [_limitar(detalles.localPosition)];
    setState(() {});
  }

  void _continuar(DragUpdateDetails detalles) {
    _trazoActual?.add(_limitar(detalles.localPosition));
    setState(() {});
  }

  void _terminar(DragEndDetails detalles) {
    final trazo = _trazoActual;

    if (trazo != null && trazo.isNotEmpty) {
      _trazos.add(trazo);
    }

    _trazoActual = null;
    setState(() {});
  }

  /// Exporta la firma como PNG (900x300), igual que la web.
  /// Devuelve null si no hay ningún trazo.
  Future<Uint8List?> exportarPng() async {
    if (estaVacia || _tamano == Size.zero) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _exportAncho, _exportAlto),
      Paint()..color = Colors.white,
    );

    final escalaX = _exportAncho / _tamano.width;
    final escalaY = _exportAlto / _tamano.height;

    final pintura = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5 * escalaX
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void dibujar(List<Offset> trazo) {
      for (var i = 0; i < trazo.length - 1; i++) {
        canvas.drawLine(
          Offset(trazo[i].dx * escalaX, trazo[i].dy * escalaY),
          Offset(trazo[i + 1].dx * escalaX, trazo[i + 1].dy * escalaY),
          pintura,
        );
      }
    }

    for (final trazo in _trazos) {
      dibujar(trazo);
    }

    final actual = _trazoActual;
    if (actual != null) dibujar(actual);

    final picture = recorder.endRecording();
    final imagen = await picture.toImage(
      _exportAncho.round(),
      _exportAlto.round(),
    );
    final datos = await imagen.toByteData(format: ui.ImageByteFormat.png);

    return datos?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _tamano = Size(constraints.maxWidth, widget.alto);

        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            height: widget.alto,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(12),
            ),
            child: GestureDetector(
              onPanStart: _iniciar,
              onPanUpdate: _continuar,
              onPanEnd: _terminar,
              child: CustomPaint(
                painter: _FirmaPainter(
                  trazos: _trazos,
                  trazoActual: _trazoActual,
                  mostrarPlaceholder: estaVacia,
                ),
                size: Size(constraints.maxWidth, widget.alto),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FirmaPainter extends CustomPainter {
  _FirmaPainter({
    required this.trazos,
    required this.trazoActual,
    required this.mostrarPlaceholder,
  });

  final List<List<Offset>> trazos;
  final List<Offset>? trazoActual;
  final bool mostrarPlaceholder;

  @override
  void paint(Canvas canvas, Size size) {
    if (mostrarPlaceholder) {
      final texto = TextPainter(
        text: const TextSpan(
          text: 'Firme aquí con el dedo',
          style: TextStyle(color: Colors.black26, fontSize: 16),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      texto.paint(
        canvas,
        Offset(
          (size.width - texto.width) / 2,
          (size.height - texto.height) / 2,
        ),
      );
    }

    final pintura = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void dibujar(List<Offset> trazo) {
      for (var i = 0; i < trazo.length - 1; i++) {
        canvas.drawLine(trazo[i], trazo[i + 1], pintura);
      }
    }

    for (final trazo in trazos) {
      dibujar(trazo);
    }

    final actual = trazoActual;
    if (actual != null) dibujar(actual);
  }

  @override
  bool shouldRepaint(covariant _FirmaPainter oldDelegate) => true;
}
