class ApiConfig {
  // Emulador Android: conecta con Flask ejecutándose
  // en el computador anfitrión.
  static const String baseUrl = 'http://10.0.2.2:5000';

  // Configuración para trabajar sin conexión.
  static const String configuracionEndpoint =
      '/api/inspecciones/movil/configuracion';

  // Envío de inspecciones pendientes.
  static const String sincronizarEndpoint =
      '/api/inspecciones/movil/sincronizar';

  // Consulta del estado de una inspección sincronizada.
  static const String sincronizacionEndpoint =
      '/api/inspecciones/movil/sincronizacion';
}
