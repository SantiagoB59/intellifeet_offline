import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Aplica la franja de evidencia sobre las fotografías,
/// con el mismo estilo que ya usa la aplicación en el
/// inicio del preoperacional.
class MarcaDeAgua {
  MarcaDeAgua._();

  static Uint8List aplicar({
    required Uint8List bytes,
    required String titulo,
    required List<String> lineas,
  }) {
    final imagen = img.decodeImage(bytes);

    if (imagen == null) {
      throw Exception('No fue posible procesar la fotografía.');
    }

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

    escribir(titulo);
    for (final linea in lineas) {
      escribir(linea);
    }

    return Uint8List.fromList(img.encodeJpg(imagen, quality: 90));
  }

  static String formatearFechaHora(DateTime fecha) {
    return '${fecha.day.toString().padLeft(2, '0')}/'
        '${fecha.month.toString().padLeft(2, '0')}/'
        '${fecha.year} '
        '${fecha.hour.toString().padLeft(2, '0')}:'
        '${fecha.minute.toString().padLeft(2, '0')}:'
        '${fecha.second.toString().padLeft(2, '0')}';
  }
}
