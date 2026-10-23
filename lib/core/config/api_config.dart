class ApiConfig {
  // Emulador Android: conecta con Flask ejecutándose
  // en el computador anfitrión.
  //
  // Para un celular físico conectado a la misma red del
  // computador, cambia esta IP por la del computador,
  // por ejemplo: 'http://192.168.1.50:5000'.
  static const String baseUrl = 'https://asbuilt.sbtechgroup.com';

  // Configuración para trabajar sin conexión.
  static const String configuracionEndpoint =
      '/api/inspecciones/movil/configuracion';

  // Envío de inspecciones pendientes.
  static const String sincronizarEndpoint =
      '/api/inspecciones/movil/sincronizar';

  // Consulta del estado de una inspección sincronizada.
  static const String sincronizacionEndpoint =
      '/api/inspecciones/movil/sincronizacion';

  static const String sincronizarAnomaliaEndpoint =
      '/api/inspecciones/movil/anomalias/sincronizar';

  // Descargar historial de inspecciones del usuario autenticado.
  static const String historialEndpoint = '/api/inspecciones/movil/historial';
  // Cierre de la inspección. Son exactamente los mismos
  // endpoints que usa la aplicación web, por lo que el
  // backend no necesita ningún cambio.
  static String finalizarEndpoint(int inspeccionId) =>
      '/api/inspecciones/$inspeccionId/finalizar';

  static String lecturaFinalEndpoint(int inspeccionId) =>
      '/api/inspecciones/$inspeccionId/lectura-final';
}
