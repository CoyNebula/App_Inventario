# Acceso móvil en desarrollo local

El login web y el móvil consultan el identificador en `users.email`. Aunque la
columna se llame `email`, admite nombres de usuario y correos. La vista web usa
`type="text"` y Fortify exige `required|string`. `FortifyServiceProvider` busca
la cuenta con el proveedor de Laravel, comprueba su contraseña y exige que esté
activa. `MobileAuthService` utiliza el mismo proveedor para validar credenciales,
y además aplica permisos móviles, segundo factor y autorización del dispositivo.

No hay cuentas ni contraseñas especiales en el flujo de autenticación. Los
usuarios de los seeders usan el mismo proceso que cualquier otra cuenta. El
usuario escribe su contraseña y Laravel la verifica contra el hash guardado.
Dart solicita usuario o correo sin exigir una arroba.

## Configuración de Laravel

En el `.env` del proyecto Laravel, con `APP_ENV=local` y `CACHE_STORE=database`:

```dotenv
MOBILE_API_ENABLED=true
MOBILE_PAT_TTL_MINUTES=480
MOBILE_OFFLINE_TTL_MINUTES=1440
MOBILE_PACKAGE_DOWNLOAD_TTL_MINUTES=60
MOBILE_AUTH_CACHE_STORE=database
```

Son plazos elegidos para desarrollo: 8 horas para el token, hasta 24 horas para
captura offline y 1 hora para descargar un paquete. La captura offline también
depende de la vigencia territorial de la cuenta. `.env.example` documenta estas
variables y deja la API desactivada hasta configurar explícitamente el entorno.

Después de modificar `.env`:

```powershell
docker exec --user laravel inventario_app php artisan config:clear
```

No hace falta reconstruir la imagen por un cambio en `.env`. Las tablas móviles,
las revisiones patrimoniales y las tablas de caché deben estar migradas.

Una petición sin token a `GET /api/v1/mobile/session` responde `401 AUTH_REQUIRED`
cuando el servicio está preparado. `503 SERVER_NOT_READY` indica que faltan
activación, vigencias, caché compatible o esquema. Quitar esa comprobación del
middleware ocultaría el problema de configuración.

## Registro del dispositivo

El primer acceso registra y activa el teléfono automáticamente después de
validar credenciales, cuenta activa, permiso de levantamiento y segundo factor.
El registro conserva usuario, UUID y fecha de autorización. El CHECK oficial
exige un actor: se registra al usuario autenticado y un evento de autorización
automática, sin atribuirle una aprobación administrativa.

Se mantienen la vinculación con el token, la propiedad de paquetes y acuses,
y el rechazo de dispositivos revocados o pertenecientes a otra cuenta. Los
servicios administrativos históricos permanecen disponibles, pero no son un
prerrequisito del primer acceso.

## Error interno al escribir el log

Un `storage/logs/laravel.log` creado por un comando ejecutado como root puede
quedar sin escritura para Apache, que en esta imagen corre como `laravel`.
El login puede guardar la sesión y fallar después al registrar la auditoría,
devolviendo `500 INTERNAL_ERROR`.

Comprobar el propietario y corregir ese archivo para el usuario de Apache:

```powershell
docker exec inventario_app chown laravel:laravel /var/www/html/storage/logs/laravel.log
docker exec inventario_app chmod 0664 /var/www/html/storage/logs/laravel.log
```

Ejecutar Artisan con `--user laravel` evita volver a crear registros como root.
No hace falta cambiar permisos de todo el proyecto.

## Preparación después del acceso

Entrar en la app y tener datos disponibles son dos pasos distintos. Si la base
importada no tiene periodos de levantamiento, un Administrador o SuperUsuario
con `hacer_levantamiento` puede crearlos desde la app o la Web. Ambas rutas
invocan `LevantamientoService`; el acceso por sí solo no crea periodos.

El usuario con `hacer_levantamiento` consulta periodos y todos los departamentos
y ubicaciones válidos. Reasignar exige también `asignar`. No se consultan
concesiones territoriales para descargar ni sincronizar. Los periodos heredados
sin instantánea se admiten y no fabrican registros históricos.

La línea base de esquema es `feature/api-levantamiento-mobile`, incluyendo
`users.activo`, las tablas móviles, snapshots y revisiones. Las operaciones
mantienen su UUID y acuse persistente en `mobile_operations`.
