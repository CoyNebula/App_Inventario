# Aplicación de levantamiento

La app está conectada a `InventoryRepository`. Las pantallas están en
`lib/pantallas`; `lib/application` conserva la sesión en el almacenamiento seguro
del sistema y traduce los errores de acceso. `lib/data` mantiene SQLite, el
cliente HTTP, los paquetes y la cola idempotente.

## Ejecutar en Android desde Windows

Desde `App_Inventario`, usando el SDK instalado:

```powershell
& 'C:\src\flutter\bin\flutter.bat' pub get
& 'C:\src\flutter\bin\flutter.bat' devices
& 'C:\src\flutter\bin\flutter.bat' run --no-pub
```

Selecciona Android si Flutter ofrece varios destinos. Si `pub get` pide soporte
de enlaces simbólicos, activa **Modo de desarrollador** en Configuración de
Windows y vuelve a ejecutar ese comando. El SDK requiere esa opción para
preparar los complementos de escritorio del repositorio.

La dirección inicial de desarrollo es
`http://10.0.2.2:8084/api/v1/mobile`, que corresponde al acceso al PC desde un
emulador Android. En un teléfono físico, despliega **Servidor de inventario** en
la pantalla de acceso e introduce `http://IP_DE_TU_PC:8084/api/v1/mobile`.
Reemplaza `IP_DE_TU_PC` por la dirección de tu computadora accesible desde el
teléfono. Laravel debe estar funcionando y ambos equipos deben poder comunicarse.

También puedes establecer la dirección al ejecutar:

```powershell
& 'C:\src\flutter\bin\flutter.bat' run --no-pub --dart-define=INVENTARIO_API_URL=http://IP_DE_TU_PC:8084/api/v1/mobile
```

Las compilaciones de producción requieren una dirección HTTPS. HTTP está
permitido por el cliente solamente en debug y por Laravel solamente con
`APP_ENV=local`. La cámara Android usa el lector incluido en el paquete, sin
necesitar descargar un modelo al comenzar el levantamiento.

## Acceso y preparación

La [guía de acceso local](acceso-local.md) detalla la configuración de Laravel,
la autorización de teléfonos y cómo corregir los errores `SERVER_NOT_READY` e
`INTERNAL_ERROR` al escribir el log.

1. Ingresa con el usuario o correo y la contraseña existentes en Laravel. El
   identificador se consulta en `users.email`, que también admite usuarios como
   `jclemente`; no necesita contener `@`. Se admite la verificación de dos
   factores y sus códigos de recuperación. La contraseña escrita se comprueba
   contra el hash de `users.password`.
2. El teléfono se registra automáticamente después de validar la cuenta activa,
   contraseña, permiso `hacer_levantamiento` y segundo factor cuando corresponda.
   Su UUID se conserva para el mismo servidor y cuenta; dispositivos ajenos o
   revocados siguen bloqueados. No se necesitan concesiones territoriales.
3. Selecciona Año y Mes e introduce Nombre. Pulsa **Crear/Cargar periodo**.
   Un administrador con `hacer_levantamiento` puede confirmar la creación si
   falta el periodo o cerrar uno abierto. El capturista carga los existentes.
   Elige departamento y ubicación y descarga el paquete completo antes de salir.
4. Para reabrir una descarga, usa la lista de paquetes guardados. Está disponible
   aunque la consulta de periodos falle por falta de conexión.

La API necesita su configuración móvil y migraciones de fase 2: activación,
vigencias, caché compartida y esquema oficial preparado. Los seeders
históricos no son ejecutados desde la aplicación. La sesión y el token se
conservan mediante `flutter_secure_storage`; la contraseña no se almacena.

## Trabajo sin conexión

- Enfoca un QR mediante **Escanear QR** o escribe/pega el código en la entrada
  manual. El lector procesa identidades literales, incluidos ceros iniciales.
- Un QR ajeno al paquete muestra **No disponible en esta descarga**. No crea
  un nuevo activo automáticamente.
- **Ok** confirma un pendiente; **Actualizar** guarda observaciones sobre una
  revisión propia. Una revisión de otro usuario se presenta en solo lectura.
- **Reasignar** permite buscar un empleado desde tres caracteres y elegir
  departamento, ubicación y fecha usando los catálogos descargados. Requiere
  permiso de asignación y un resguardo vigente.
- Cada guardado actualiza el bien y su operación en una transacción SQLite.
  Una operación pendiente impide confirmar nuevamente el mismo detalle hasta
  resolver su resultado y renovar la instantánea. Se puede continuar con otros bienes.
- El avance incluye revisiones guardadas en el dispositivo. La cola muestra
  aparte las operaciones pendientes y las respuestas que necesitan atención.

## Sincronización

Pulsa **Sincronizar con el servidor** cuando recuperes conexión. La app comprueba
la sesión real con Laravel, envía hasta 100 operaciones / 1 MiB por lote y
procesa los acuses individualmente. Si se pierde una respuesta, recupera los
resultados por UUID antes de reenviar. Los cambios no desaparecen por un HTTP 200.

El resumen muestra aplicadas, pendientes, conflictos y rechazos. Cuando todas
las operaciones de un paquete están resueltas, se descarga una instantánea nueva
con versiones, fecha y leyendas oficiales. Un conflicto permanece visible hasta
su resolución explícita; la captura anterior se conserva en el historial.

Cerrar sesión conserva las descargas y operaciones SQLite. Al ingresar de nuevo
con la misma cuenta y servidor se pueden recuperar. Si vence la autorización
offline, la consulta local permanece disponible y las capturas nuevas se
bloquean hasta renovar el acceso online.

## Comprobaciones

```powershell
& 'C:\src\flutter\bin\flutter.bat' analyze --no-pub --no-fatal-infos
& 'C:\src\flutter\bin\flutter.bat' test --no-pub --concurrency=1
& 'C:\src\flutter\bin\flutter.bat' build apk --debug --no-pub
```

El APK se genera en `build/app/outputs/flutter-apk/app-debug.apk`. Las pruebas
usan SQLite y respuestas HTTP sintéticas: no requieren la red del Congreso.
La prueba final de cámara y conectividad LAN se realiza con un dispositivo y
una cuenta autorizada en el backend.
