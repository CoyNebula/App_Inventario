import 'dart:async';

import '../data/api_client.dart';
import '../data/models.dart';

String inventoryErrorMessage(Object error) {
  if (error is DataContractException) return error.message;
  if (error is TimeoutException)
    return 'El servidor tardó demasiado. Tus capturas locales siguen guardadas.';
  if (error is MobileApiException) {
    return switch (error.code) {
      'AUTH_INVALID_CREDENTIALS' => 'Usuario o contraseña incorrectos.',
      'DEVICE_PENDING_AUTHORIZATION' =>
        'Dispositivo registrado y pendiente de autorización en Laravel. Usa la misma cuenta y vuelve a intentar después de autorizarlo.',
      'DEVICE_REVOKED' =>
        'El acceso de este dispositivo fue revocado. Consulta al administrador.',
      'DEVICE_NOT_AUTHORIZED' =>
        'Este dispositivo no está autorizado para acceder.',
      'TWO_FACTOR_INVALID' => 'El código de verificación no es válido.',
      'TWO_FACTOR_CHALLENGE_EXPIRED' =>
        'La verificación venció. Vuelve a iniciar sesión.',
      'TWO_FACTOR_SETUP_INCOMPLETE' =>
        'Completa la configuración de verificación en dos pasos desde el sistema web.',
      'TOKEN_EXPIRED_OR_REVOKED' ||
      'AUTH_REQUIRED' =>
        'Renueva tu sesión con internet para sincronizar. Tus capturas permanecen en el dispositivo.',
      'SCOPE_FORBIDDEN' =>
        'Tu usuario no tiene una concesión vigente para este periodo o ubicación.',
      'PERMISSION_DENIED' => 'Tu usuario no tiene permiso para esta acción.',
      'PERIOD_CLOSED' =>
        'El periodo está cerrado. Se conservan las capturas pendientes para su revisión.',
      'SERVER_NOT_READY' =>
        'La API móvil no está habilitada o falta configurar sus vigencias, caché o esquema en Laravel.',
      'RATE_LIMITED' =>
        'Se alcanzó el límite de solicitudes. Espera antes de volver a intentar.',
      'PACKAGE_EXPIRED' =>
        'La descarga venció. Solicita un paquete nuevo con conexión.',
      'VALIDATION_FAILED' =>
        'El servidor rechazó los datos. Revisa los campos y la configuración de acceso.',
      _ => 'No se completó la solicitud al servidor (' +
          error.code +
          '). Tus datos locales se conservan.',
    };
  }
  return 'No se pudo completar la operación. Revisa la conexión y vuelve a intentar; tus datos locales se conservan.';
}
