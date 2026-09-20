# Auditoría de iCloudy — 19 de septiembre de 2026

> Actualización: A01–A07 se han abordado en el árbol de trabajo. Consulta [las correcciones P1 y su validación](CORRECCIONES-P1-2026-09-19.md). El informe y las reproducciones siguientes documentan la revisión anterior a esas correcciones.
**Conclusión:** iCloudy tiene una base funcional amplia, pero hay defectos de integridad y recuperación que conviene corregir antes de ampliar la sincronización. La batería actual pasa y, aun así, permite sobrescrituras no deseadas y resultados de éxito incorrectos.

Revisión sobre el commit **14148fc**, versión declarada **0.5.0**. El árbol de trabajo estaba limpio al empezar. No se ha modificado el código de producción, conectado cuentas reales ni ejecutado operaciones contra archivos del usuario.

**Alcance y evidencia**

- Revisión de arquitectura, proveedores, autenticación, transferencias, reflejos, persistencia, búsqueda, vista previa, integración con macOS, interfaz en código, pruebas y empaquetado.
- **305 pruebas existentes: aprobadas**, sin fallos; aproximadamente 31 segundos de ejecución.
- **9 pruebas de reproducción: confirmadas**, con archivos temporales, credenciales ficticias, respuestas HTTP simuladas y un servidor FTP de loopback. Estas pruebas afirman el comportamiento defectuoso observado; que pasen demuestra su reproducción, no su corrección.
- Compilación release con comprobación estricta de concurrencia: terminada correctamente. **58 emisiones de advertencia, 57 diagnósticos distintos**, muchos señalados por el compilador como errores en modo de lenguaje Swift 6.
- Entorno: Apple Swift 6.4, arm64. No se ha validado ejecución en macOS 14, Intel, una aplicación firmada dentro del sandbox, VoiceOver ni cuentas reales. Tampoco se ha realizado una auditoría criptográfica independiente de Mega o una prueba de penetración de los servicios.

Se conservan las [pruebas de reproducción](/Users/ruvelro/Documents/src/iCloudy/docs/auditoria-2026-09-19/AuditProbeTests.swift), su [salida](/Users/ruvelro/Documents/src/iCloudy/docs/auditoria-2026-09-19/reproducciones.log) y el [registro de compilación](/Users/ruvelro/Documents/src/iCloudy/docs/auditoria-2026-09-19/compilacion-concurrencia.log). Las pruebas están fuera de Tests para no incorporar a la batería habitual afirmaciones que esperan fallos. Para repetirlas, se pueden copiar temporalmente a Tests/iCloudyTests y ejecutar «swift test --filter AuditProbeTests»; después deben retirarse o convertirse en regresiones que exijan el comportamiento correcto.

**Prioridad alta — P1**

**A01. Un reflejo puede sobrescribir el archivo que el usuario decidió conservar. Reproducido.**

[FolderMirror.swift:258](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/FolderMirror.swift:258)

Escenario probado: el destino contiene «a.txt» de otra procedencia; en la primera sincronización se elige conservar ambas copias y se crea «a (2).txt». Tras editar el origen, la siguiente sincronización sustituye el «a.txt» original y deja «a (2).txt» desactualizado. El reflejo conserva tamaños y fechas, pero no la correspondencia entre archivo local y objeto remoto; además activa reemplazo para todo el lote desde la segunda ejecución. También afecta a archivos nuevos que coincidan con objetos ajenos del destino.

**Corrección:** persistir por ruta local el ID remoto, nombre elegido, versión y resultado real. Reemplazar únicamente objetos identificados como propios; preguntar por nuevas colisiones y modificaciones remotas. La regresión debe comprobar el contenido de ambas copias, no solo su número.

**A02. Un error de integridad puede convertirse en éxito al reintentar. Reproducido en Box.**

[Box.swift:232](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/Box.swift:232), [Dropbox.swift:210](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/Dropbox.swift:210), [ResumableUpload.swift:161](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/ResumableUpload.swift:161)

Box y Dropbox guardan el checkpoint como completo antes de comparar el hash. Si la comparación falla, el reintento encuentra ese checkpoint y devuelve éxito sin volver a verificar ni retransmitir. La reproducción de Box recibió un SHA-1 incorrecto y el segundo intento terminó sin ninguna petición adicional.

**Corrección:** distinguir «servidor confirmó», «verificación pendiente», «verificado» y «integridad fallida». Conservar ID remoto y hashes necesarios para recuperar la comprobación. Una discrepancia conocida nunca debe degradarse a «sin verificar» mediante Reintentar.

**A03. Dropbox admite una mezcla de dos versiones del origen y la marca como verificada. Reproducido.**

[Dropbox.swift:175](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/Dropbox.swift:175)

Se cambió el archivo después del primer bloque de 4 MiB, manteniendo su tamaño. La subida terminó con el comienzo antiguo y el final nuevo; la suma del proveedor coincidió con esa mezcla y se declaró verificada. Faltan comprobaciones de modificación entre bloques. Mega también lee bloques sin comprobar la fecha entre ellos; FTP y la copia de volúmenes merecen la misma revisión.

**Corrección:** aplicar un contrato común de estabilidad del origen y, para garantías fuertes, subir desde una instantánea o copia estable. Tamaño y fecha antes y después de leer son una defensa inicial; no sustituyen una instantánea frente a escrituras simultáneas.

**A04. Los tiempos de espera de FTP pueden quedarse bloqueados indefinidamente. Reproducido.**

[FTPSession.swift:183](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/FTPSession.swift:183), [FTPSession.swift:163](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/FTPSession.swift:163)

Con un servidor que acepta la conexión pero no envía saludo, un límite de 50 ms seguía bloqueado después de 400 ms y solo terminó al cerrar explícitamente la conexión. La tarea temporizadora cancela el grupo, pero la continuación de Network.framework sigue esperando. Los grupos de tareas esperan a sus hijos y la cancelación es cooperativa. [Documentación de concurrencia de Swift](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html).

**Corrección:** cerrar la conexión al vencer el plazo o al cancelar, resolver la continuación exactamente una vez y aplicar límites a conexión, lectura, envío y cierre. Revisar también la descarga FTP: su bucle no comprueba cancelación y trata cualquier error de lectura como fin de datos.

**A05. La protección de rutas de volúmenes no controla enlaces simbólicos intermedios. Reproducido.**

[Volume.swift:32](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/Volume.swift:32)

Una ruta que empieza dentro de la carpeta conectada puede atravesar un enlace hacia fuera. La prueba accedió a «inside/link/private.txt», cuyo contenido estaba en «outside». La interfaz no permite navegar un enlace recién listado como carpeta, pero una ruta o favorito previamente válido puede quedar bajo un directorio sustituido por un enlace.

**Corrección:** validar los componentes y el destino real, rechazar ancestros simbólicos y usar operaciones sobre descriptores con protección frente a sustituciones cuando proceda. Esto prueba un fallo del límite interno del proveedor; no demuestra una evasión del sandbox de macOS, que puede bloquear destinos sin autorización.

**A06. La política de redirecciones no cubre todos los transportes ni el origen completo. Parcialmente reproducido.**

[CloudAPI.swift:28](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/CloudAPI.swift:28), [CloudAPI.swift:173](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/CloudAPI.swift:173), [WebDAV.swift:200](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/WebDAV.swift:200)

RedirectGuard compara solo el hostname. La prueba confirmó que mantiene Authorization cuando cambia el puerto. Además, el reintento tras 401, las descargas con DownloadProgress, varias subidas y la conexión inicial WebDAV no usan esa protección común. Los comentarios prometen una política que no se aplica de forma uniforme.

**Corrección:** comparar esquema, host y puerto efectivo; impedir degradaciones de TLS; aplicar una misma política a todas las peticiones y valorar si se permite reenviar cuerpos de subida fuera del origen. Añadir pruebas HTTP reales de redirecciones 302/307/308. No se ha demostrado una filtración real de credenciales; el alcance exacto depende también del comportamiento de URLSession.

**A07. Guardar en el Llavero elimina primero la única copia anterior. Riesgo confirmado por código.**

[Models.swift:344](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Models.swift:344), [AppModel.swift:303](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:303)

Vault.write ejecuta SecItemDelete antes de SecItemAdd. Si la segunda operación falla, desaparece el valor anterior, incluida la lista completa de cuentas cuando se guarda «accounts». La reparación de ACL lee y reescribe en segundo plano, por lo que también debe coordinarse con renovaciones o desconexiones.

**Corrección:** usar actualización normal para escrituras ordinarias; separar la migración de ACL, serializarla y conservar capacidad de recuperación. Inyectar el almacenamiento de cuentas igual que se hace con los tokens para probar errores de escritura sin tocar el Llavero real. No se forzó este fallo sobre las credenciales del usuario.

**Prioridad media — P2**

**A08. O2 pierde las cookies SSO guardadas al persistir una renovación. Reproducido.**

[O2Cloud.swift:167](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/O2Cloud.swift:167)

o2Persist reconstruye el secreto sin pasar las cookies SSO; el parámetro por defecto las sustituye por una lista vacía. Se confirmó que desaparecen del almacenamiento después de actualizar la clave. Esto puede romper la renovación silenciosa tras reiniciar.

**Corrección:** preservar SSO y todos los campos de la sesión anterior, escribir antes de dar por persistida la renovación y mostrar los errores del Llavero. Añadir una prueba que abarque login → rotación → persistencia → reinicio.

**A09. El límite de descarga autorizado para la vista previa no es uniforme. Reproducido en O2.**

[CloudAPI.swift:413](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/CloudAPI.swift:413), [O2Cloud.swift:339](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/O2Cloud.swift:339)

O2 y Mega ignoran maxBytes. Se pidió un máximo de un byte a O2 y se recibieron y aceptaron cien. FTP y volúmenes comprueban el límite después de copiar todo, por lo que tampoco limitan el consumo durante la operación.

**Corrección:** propagar el máximo a todos los proveedores, interrumpir al alcanzar el límite y eliminar parciales. Validar metadatos y bytes efectivos; no confiar en el tamaño anunciado para decidir el consumo autorizado.

**A10. Cancelar nube a nube utiliza la cuenta de origen para abandonar la subida. Reproducido.**

[TransferQueue.swift:160](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/TransferQueue.swift:160), [AppModel.swift:144](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:144)

Las sesiones pertenecen al destino, pero abandonSessions consulta transfer.accountID, que es el origen. En particular, la limpieza de sesiones Box puede omitirse o usar la credencial equivocada. La notificación de finalización también refresca únicamente el origen, dejando el listado y la cuota del destino sin actualizar.

**Corrección:** seleccionar targetAccountID en transferencias entre cuentas y notificar por separado las cuentas afectadas. Verificar con origen y destino de proveedores distintos.

**A11. Los reflejos arrancan antes de que las cuentas estén cargadas. Riesgo de carrera por código.**

[AppModel.swift:159](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:159), [AppModel.swift:279](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:279)

mirrors.start se invoca antes de la lectura asíncrona del Llavero. Si esta se demora y hay un reflejo pendiente o modificado, el trabajo puede solicitar una cuenta todavía ausente y fallar. La carga posterior no programa explícitamente otra sincronización.

**Corrección:** introducir un estado de inicialización y comenzar reflejos y acciones de Atajos cuando las cuentas estén listas. Probar un arranque con lectura del Llavero retrasada, sin simular falta de credenciales.

**A12. Renombrar o mover rompe referencias en proveedores que usan rutas como ID. Confirmado por código.**

[AppModel.swift:954](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:954), [AppModel.swift:828](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:828)

Dropbox, WebDAV, FTP y volúmenes cambian de ID al cambiar de ruta. commitName conserva file.id; relocate actualiza parte de las migas pero no todas las identidades. Los favoritos, Spotlight, copias locales y destinos de reflejos pueden seguir apuntando a rutas antiguas. También hay que actualizar descendientes al mover una carpeta.

**Corrección:** hacer que las mutaciones devuelvan el objeto actualizado o un mapa de identidades. Propagarlo de forma centralizada a los índices, favoritos y trabajos pendientes. En Dropbox, considerar IDs estables del proveedor.

**A13. El ciclo de vida del reflejo no coincide con sus controles. Confirmado por código.**

[FolderMirror.swift:163](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/FolderMirror.swift:163), [FolderMirror.swift:220](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/FolderMirror.swift:220), [FolderMirror.swift:274](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/FolderMirror.swift:274)

«Dejar de reflejar» retira el observador y la configuración, pero no cancela el trabajo activo. Una sincronización manual sobre un trabajo pausado puede crear otro en vez de resolver el existente. Al completar un lote, se promueven todas las marcas previstas, incluidas las de archivos omitidos. El planificador solo representa archivos regulares y no detecta nuevas carpetas vacías.

**Corrección:** representar estados y resultados por elemento, detener el trabajo asociado al retirar el reflejo, mantener la pausa y registrar carpetas. Promover únicamente elementos transferidos con éxito.

**A14. Un puerto FTP fuera de rango puede cerrar la aplicación. Verificado el parseo; conversión insegura en código.**

[OAuth.swift:226](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/OAuth.swift:226), [FTP.swift:19](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/FTP.swift:19)

URLComponents acepta «ftp://localhost:70000» y devuelve 70000 en este entorno. Convertirlo mediante UInt16 sin validación provoca un trap, en vez de un error de formulario.

**Corrección:** validar 1…65535 y usar conversión exacta opcional. Probar cero, valores superiores al máximo y direcciones mal formadas antes de abrir sockets.

**A15. OneDrive anuncia una copia terminada cuando solo ha sido aceptada. Confirmado por código y contrato de la API.**

[ResumableUpload.swift:73](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/ResumableUpload.swift:73), [AppModel.swift:851](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:851)

Se acepta HTTP 202 y se muestra «copiado» sin conservar ni consultar Location. La operación puede fallar después, incluso por conflicto. Microsoft documenta expresamente la consulta de la URL de seguimiento hasta el estado final. [Microsoft Graph: copiar driveItem](https://learn.microsoft.com/en-us/graph/api/driveitem-copy?view=graph-rest-1.0).

**Corrección:** incorporar estas copias a una cola de operaciones remotas, persistir el seguimiento y mostrar «pendiente» hasta confirmar el resultado.

**A16. La limpieza puede borrar temporales en uso y no vacía toda la caché de listados. Confirmado por código.**

[SettingsView.swift:183](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/SettingsView.swift:183), [Maintenance.swift:99](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Maintenance.swift:99), [ListingCache.swift:11](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/ListingCache.swift:11)

Vaciar no coordina las carpetas de vista previa, transferencias o portapapeles con sus consumidores. Puede retirar fuentes de una subida pendiente o contenidos de una transferencia activa. En listados borra disco, pero conserva la copia en memoria; escrituras pendientes pueden reconstruir la caché inmediatamente.

**Corrección:** limpiar a través del propietario de cada recurso, excluir archivos en uso, cerrar vistas previas y serializar el vaciado con las escrituras. La limpieza de datos necesarios para trabajos pendientes debe explicar y aplicar una política específica.

**A17. La comprobación de copias locales ignora sus bookmarks. Riesgo funcional en sandbox.**

[LocalCopies.swift:113](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/LocalCopies.swift:113)

verify comprueba rutas con fileExists sin resolver ni abrir su permiso persistente. Un archivo existente fuera del contenedor puede confundirse con uno borrado después de reiniciar. Tampoco sigue correctamente una ubicación trasladada antes de decidir si descarta la copia.

**Corrección:** resolver el bookmark, mantener el ámbito abierto durante la comprobación y distinguir «sin permiso», «volumen desconectado» y «archivo inexistente». Validarlo en un .app firmado y sandboxed; las pruebas actuales con temporales no cubren este caso.

**A18. Tras un borrado definitivo se afirma que el archivo está en la papelera. Confirmado por código.**

[AppModel.swift:893](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:893)

FTP y WebDAV borran definitivamente, pero el mensaje de éxito usa siempre «papelera» y puede indicar que se restaure desde la web. La confirmación previa sí distingue el caso: el fallo está en el resultado comunicado. Para volúmenes, la recuperación corresponde al Finder.

**Corrección:** devolver una semántica explícita de eliminación y adaptar tanto la confirmación como el resultado a cada proveedor.

**A19. Mega oculta el fallo al retirar la versión anterior de un reemplazo. Confirmado por código.**

[Mega.swift:360](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/Providers/Mega.swift:360)

El traslado de la copia antigua a la papelera usa try?, y después el árbol local se modifica como si hubiera funcionado. Si falla, quedan dos archivos remotos y la app anuncia éxito con una vista local que no refleja el servidor.

**Corrección:** conservar el nuevo archivo, comunicar el reemplazo parcial y actualizar el árbol solo tras confirmación. Persistir el paso pendiente para reintentar únicamente la retirada de la versión antigua.

**A20. La paginación de búsqueda puede usar filtros diferentes de los de su primera página. Confirmado por código.**

[AppModel.swift:220](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:220), [GlobalSearch.swift:104](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/GlobalSearch.swift:104)

El texto se captura al empezar, pero la función de consulta lee los filtros actuales en cada petición. Cambiarlos mientras llegan páginas o antes de «Cargar más» envía el cursor anterior junto con otra consulta a Google. La interfaz dice que se envían al pulsar Buscar, pero no los congela.

**Corrección:** guardar una solicitud inmutable con texto y filtros remotos; cambiarla debe reiniciar cursores. Marcar también resultados parciales en los topes de Mega (500) y Box (10.000), que ahora no siempre lo indican.

**A21. Existe una ventana de duplicación tras completar una subida entre nubes. Riesgo por orden de persistencia.**

[TransferQueue.swift:469](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/TransferQueue.swift:469), [TransferQueue.swift:495](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/TransferQueue.swift:495)

El proveedor puede haber guardado un checkpoint completo y después se elimina el archivo temporal antes de persistir completedPaths. Si el proceso termina en esa ventana, al reiniciar se encuentra el temporal ausente y se descarta el checkpoint, incluso si decía «completo». La siguiente subida puede duplicar el archivo o terminar en conflicto.

**Corrección:** persistir ID remoto y estado terminal del elemento antes de borrar su temporal; procesar primero los checkpoints completos. Probar interrupciones en cada transición con un almacén que permita inyectar fallos.

**A22. Desactivar la caché de listados no impide seguir guardando metadatos. Confirmado por código.**

[AppModel.swift:753](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:753), [AppModel.swift:766](/Users/ruvelro/Documents/src/iCloudy/Sources/iCloudy/AppModel.swift:766)

La preferencia se consulta al recuperar una copia, pero un listado exitoso siempre llama a listings.store. La opción para no recordar listados no evita su escritura. Además, el máximo de 5.000 se aplica por carpeta: no existe un presupuesto global o caducidad para todas las carpetas visitadas.

**Corrección:** aplicar la preferencia a lectura y escritura, ofrecer eliminación del historial existente y añadir límites globales por bytes, entradas y antigüedad.

**Calidad, arquitectura y aspectos pendientes de validar**

- **Concurrencia:** los 57 diagnósticos distintos se concentran en Mega, FTP, volúmenes, App Intents, Spotlight y sus callbacks. Son deuda técnica observable, no 57 carreras demostradas. Resolver aislamiento y Sendable mediante contratos explícitos; no silenciarlos de forma general con @unchecked.
- **Modelo de proveedores:** CloudAPI concentra conmutaciones y comparte estado mutable entre transportes muy diferentes. Extraer interfaces para navegación, escritura, transferencia y seguimiento, con tipos de respuesta que incluyan identidad, versión, integridad y capacidades por elemento.
- **Pruebas:** hay buena cobertura de respuestas simuladas y primitivas, pero algunas pruebas inspeccionan cadenas del fuente. MirrorTests comprueba que la segunda sincronización use reemplazo, sin comprobar qué archivo reemplazó. Es necesario probar los resultados observables de secuencias completas.
- **CI:** no se encontró una configuración de integración continua versionada. Automatizar pruebas, release, localización, validación del bundle y checks de concurrencia. Añadir pruebas de contratos contra cuentas dedicadas cuando estén disponibles.
- **Rendimiento:** la cola es secuencial y recorre árboles completos; serializa estructuras JSON crecientes y aún hace parte del trabajo de disco en MainActor. Medir antes de sustituir persistencia por SQLite o añadir paralelismo. Faltan mediciones de memoria, latencia de interfaz y carpetas grandes.
- **Sesiones O2:** la renovación silenciosa no se conserva como tarea cancelable de la cuenta y su adopción no comprueba que siga conectada. Revisar la carrera con Desconectar. El vigilante de login usa try? al dormir y no comprueba Task.isCancelled, por lo que cancelarlo no garantiza detener sus comprobaciones. Las coincidencias de dominio de cookies deben exigir frontera de dominio y las sesiones WebKit deben aislarse por cuenta.
- **FTP:** RNFR y RNTO son operaciones exclusivas separadas; otra orden puede intercalarse. Deben formar una operación indivisible. La estrategia de reintento tampoco distingue suficientemente lectura, mutación y resultado remoto incierto.
- **Identidad WebDAV:** el ID de cuenta no incorpora puerto ni esquema; dos servidores del mismo host y ruta, con distinto puerto y el mismo usuario, colisionan. Normalizar el origen completo.
- **Integridad de descargas:** salvo la verificación específica de Mega, el camino general no compara hashes del proveedor. Las descargas normales tampoco aplican la comprobación de tamaño que sí aparece en nube a nube. Añadirla, junto con versionado o condiciones de lectura, evitando confundir un archivo cambiado con corrupción.
- **Integración de escritorio:** revisar arranque en frío de Dock, Servicios y Atajos, porque pueden llegar antes de que exista el modelo o terminen de cargar las cuentas.
- **Spotlight:** el límite local no elimina del índice del sistema los elementos expulsados; sus tareas de publicar/borrar tampoco se ordenan entre sí. Serializar estas acciones, retirar identificadores antiguos y hacer que Vaciar alcance todo lo publicado.
- **Presentación:** hay textos construidos como String sin localizar y un RelativeDateTimeFormatter fijado a es_ES. También se ofrecen algunas acciones a carpetas de Mega que el proveedor rechaza después. Añadir validación de interfaz en inglés y capacidades por tipo de elemento.
- **Documentación:** README muestra 0.5.0 y conserva el aviso «Versión 0.1». Sus promesas sobre comprobar cambios de origen en todos los proveedores y sobre ausencia de restos requieren ajuste a los defectos anteriores. Las capturas son maquetas, como se indica correctamente.
- **Distribución:** la firma estable y notarización están pendientes y documentadas. El script fuerza timestamp=none y compila para la arquitectura actual. Antes de publicar, separar compilación local y distribución, limpiar el bundle de salida, validar Intel/Apple Silicon y producir un artefacto firmado, notarizado y reproducible.

**Lo que merece conservarse**

Uso del Llavero, OAuth con PKCE y state, enlace de retorno limitado a loopback, permisos privados de los archivos de estado, checkpoints, escrituras atómicas de JSON, protección contra inyección de comandos FTP, temporales de vista previa acotados por propiedad, separación de errores por cuenta, y ausencia de dependencias externas del paquete. Hay una base suficiente para corregir los problemas sin reescribir toda la aplicación.

**Mejoras y nuevas funciones propuestas**

| Propuesta | Beneficio concreto | Prioridad / esfuerzo relativo |
|---|---|---|
| Plan previo de transferencia | Mostrar archivos, bytes, espacio temporal, conflictos y elementos no exportables antes de empezar. | Alta / medio |
| Informe final por archivo | Distinguir copiado, omitido, fallido, verificado y pendiente de comprobación; exportar el resultado. | Alta / medio |
| Reflejos con exclusiones | Ignorar patrones, ocultos, paquetes y archivos temporales; permitir pausar y ver cambios pendientes. | Alta / medio |
| Diagnóstico para todos los proveedores | Eventos estructurados con identificador de trabajo, etapa y causa; exportación sin secretos. | Alta / medio |
| Recuperación guiada | Explicar qué quedó en destino y ofrecer reintentar solo lo pendiente, verificar o conservar duplicados. | Alta / medio |
| Cola configurable | Paralelismo limitado por cuenta, límite de ancho de banda, prioridad, horario y restricciones de red. | Media / medio-alto |
| Doble panel y pestañas | Trabajar entre dos destinos y conservar varias ubicaciones abiertas. | Media / medio |
| Búsquedas guardadas | Colecciones reutilizables, búsqueda por nombre/contenido y claridad sobre cobertura o caché. | Media / bajo-medio |
| Gestión de enlaces | Enumerar y revocar enlaces; caducidad, contraseña y permisos cuando el proveedor los admita. | Media / medio |
| Versiones y restauración | Consultar versiones remotas y restaurarlas con confirmación y registro. | Media / alto |
| SFTP y FTPS explícito | Ampliar la compatibilidad con servidores sin depender de montajes del Finder. | Media / alto |
| Copias sin conexión administradas | Elegir carpetas disponibles offline, presupuesto de disco y política de actualización. | Media / alto |
| Comparador entre nubes | Comparar inventarios, tamaños, versiones y hashes; sugerir duplicados sin borrado automático. | Media / alto |
| Sincronización bidireccional | Cambios en ambos sentidos, conflictos y borrados controlados, con diario y recuperación. | Posterior / muy alto |
| Integración File Provider | Mostrar archivos bajo demanda dentro del Finder. | Posterior / muy alto |

Los esfuerzos son comparativos, no estimaciones en días. La sincronización bidireccional depende de resolver identidad estable, versiones, conflictos y recuperación; los indicadores de copia local actuales no bastan para implementarla de forma fiable.

**Orden de ejecución recomendado**

1. **Integridad y seguridad:** A01–A07; convertir sus reproducciones en regresiones que exijan preservación de datos. Completar transporte común y almacenamiento recuperable.
2. **Recuperación y sesiones:** A08–A15, A19 y A21; probar cancelación, pausa, reinicio, cambio de origen, clave rotada y respuesta final perdida.
3. **Coherencia del producto:** A16–A18, A20 y A22; corregir limpieza, metadatos, mensajes y resultados parciales. Añadir un informe final de operaciones.
4. **Publicación y evolución:** CI, validación sandbox y macOS mínimo, concurrencia, firma y notarización. A continuación, plan previo, exclusiones y diagnóstico; después las funciones de mayor alcance.

El criterio de salida debe ser que cada fallo identificado tenga una regresión sobre su resultado real, que una interrupción conserve los datos y que la interfaz distinga inequívocamente éxito, omisión, incertidumbre e integridad fallida.

