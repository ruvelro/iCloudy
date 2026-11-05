# Correcciones P2 — 20 de septiembre de 2026

Aplicadas sobre las correcciones P1, conservando los cambios anteriores. Alcance: los 15 hallazgos numerados A08–A22 de la auditoría. No incluye la migración completa a Swift 6 ni las funciones nuevas propuestas al final de la auditoría.

| Hallazgo | Corrección |
| --- | --- |
| A08 | O2 conserva las cookies SSO al renovar la sesión. Solo marca la renovación como guardada tras escribir correctamente; informa del fallo y permite volver a intentar la persistencia. |
| A09 | `maxBytes` llega a O2, Mega, FTP y volúmenes. O2 limita y comprueba el temporal; Mega valida el tamaño antes de solicitar bytes y limita cada bloque; FTP comprueba antes de escribir; los volúmenes rechazan antes de crear el destino. Los archivos parciales se retiran. |
| A10 | La cancelación abandona las sesiones de subida usando la cuenta de destino. Al terminar una transferencia entre nubes se refrescan ambas cuentas. |
| A11 | Los reflejos arrancan después de cargar las cuentas. Atajos espera a que termine esa inicialización y propaga los errores de lectura del Llavero. |
| A12 | Un mapa de identidades propaga renombrados y movimientos de rutas, incluidos descendientes, a favoritos, navegación, cachés, Spotlight, copias locales, reflejos y transferencias pendientes. Se pide pausar las transferencias antes de mutar una cuenta en uso. |
| A13 | Eliminar un reflejo cancela su trabajo; «sincronizar ahora» reutiliza el trabajo pausado. La planificación incluye directorios vacíos y reabre los antecesores de cualquier elemento nuevo o modificado. Los elementos omitidos siguen sin promoverse como sincronizados, conforme a P1. |
| A14 | Los puertos FTP se convierten sin trampas y deben estar entre 1 y 65535, tanto al conectar como al restaurar cuentas. |
| A15 | OneDrive mantiene una cola persistente de copias remotas. Guarda el monitor de una respuesta 202, consulta hasta obtener un estado terminal y retoma esas consultas al abrir la app. El panel distingue aceptación, finalización, fallo e incertidumbre; nunca vuelve a enviar automáticamente una copia tras reiniciar. |
| A16 | La limpieza de listados pasa por su propietario y ordena el borrado después de las escrituras pendientes. Temporales de vistas previas, transferencias y portapapeles que siguen en uso se conservan. La demo no se vacía mientras tiene trabajos pendientes o activos. |
| A17 | La comprobación y apertura en Finder resuelven bookmarks y mantienen abierto el acceso mientras verifican. Se siguen archivos trasladados y nuevas copias con bookmark de carpeta conservan su ruta relativa. Un permiso inaccesible o volumen ausente conserva el registro y se muestra como copia sin acceso. |
| A18 | FTP y WebDAV indican borrado permanente; los volúmenes indican recuperación desde Finder. La confirmación utiliza también la acción correspondiente. |
| A19 | Mega guarda el nodo nuevo y la retirada pendiente antes de mover la versión anterior a la papelera. Un fallo se comunica y no modifica anticipadamente el árbol. Reintentar solo retira el nodo anterior, incluso si ya falta el temporal local. |
| A20 | La búsqueda captura filtros y fecha de referencia al enviarse; todas sus páginas usan esos valores. Mega y Box indican resultados incompletos al alcanzar sus límites. |
| A21 | La finalización de cada archivo entre nubes se persiste antes de borrar su temporal. Al recuperar un checkpoint completo y validado no se vuelve a descargar ni subir, aunque falte el temporal. Los checkpoints sin integridad confirmada no se dan por válidos. |
| A22 | Desactivar la caché bloquea lecturas y escrituras y vacía memoria y disco. Límites globales: 20.000 elementos, 256 listados, 10 MiB y siete días, además de 5.000 elementos por listado. |

## Verificación

La batería incluye 21 pruebas nuevas de regresión en `Tests/iCloudyTests/P2RegressionTests.swift`, además de las pruebas existentes de proveedores, reflejos, recuperación, cachés, Spotlight, localización y seguridad P1. Se han actualizado las expectativas de los directorios vacíos y la simulación de copia asíncrona de OneDrive.

Verificación final:

- `swift test`: **348 pruebas, cero fallos**, en unos 33 segundos.
- `swift build -c release -Xswiftc -strict-concurrency=complete`: **correcta**, en unos 42 segundos.
- `git diff --check`: **correcto**.
- Los diagnósticos de concurrencia con ubicación en código bajan de **57 a 34**: se eliminan los de las propiedades compartidas de Atajos y el aislamiento de Spotlight. Los 34 restantes corresponden a categorías preexistentes.

Registros de esta sesión: `/tmp/icloudy-p2-final-tests2.log` y `/tmp/icloudy-p2-final-release.log`.

El seguimiento de OneDrive se basa en los contratos de [copia de driveItem](https://learn.microsoft.com/en-us/graph/api/driveitem-copy?view=graph-rest-1.0) y [acciones de larga duración](https://learn.microsoft.com/en-us/graph/long-running-actions-overview). Los monitores de almacenamiento reciben su URL temporal, sin reenviarles el token de Graph.

## Límites de la validación

- Se usan proveedores simulados y un servidor FTP local; no se han realizado operaciones sobre cuentas reales del usuario.
- Los bookmarks se comprueban con archivos locales movidos. Sigue siendo necesaria una prueba de distribución con una app firmada y sandbox, permisos reales y desconexión física de volúmenes.
- Un registro antiguo con bookmark de carpeta que no permite reconstruir la ruta del hijo se conserva como inaccesible; no se inventa una ubicación ni se elimina el registro.
- Si el servidor acepta una copia pero se pierde su respuesta antes de poder guardar el monitor, la operación queda sin confirmar y requiere revisar el destino. No se repite el POST automáticamente.
- La compilación estricta de concurrencia sigue mostrando advertencias anteriores a esta tarea. La migración integral a Swift 6 queda fuera de A08–A22.
