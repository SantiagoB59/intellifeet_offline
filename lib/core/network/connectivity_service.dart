import 'package:connectivity_plus/connectivity_plus.dart';

/// Servicio ligero para conocer el estado de la conexión.
///
/// La aplicación funciona igual con o sin internet: todo se
/// guarda localmente y la sincronización se habilita cuando
/// el dispositivo recupera la conexión.
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _tieneRed(List<ConnectivityResult> resultados) {
    return resultados.any(
      (resultado) => resultado != ConnectivityResult.none,
    );
  }

  Future<bool> hayConexion() async {
    final resultados = await _connectivity.checkConnectivity();
    return _tieneRed(resultados);
  }

  /// Emite true/false cada vez que cambia el estado de la red.
  Stream<bool> get cambiosConexion {
    return _connectivity.onConnectivityChanged.map(_tieneRed).distinct();
  }
}
