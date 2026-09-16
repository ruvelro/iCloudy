# Vista previa — primera versión implementada

Objetivo: consultar un archivo sin elegir dónde guardarlo y sin dejar una copia permanente administrada por iCloudy. No significa cero descarga: para Quick Look necesitamos una copia local temporal.

## Comportamiento

- Un archivo seleccionado + barra espaciadora, o menú contextual «Vista previa». Escape cierra. El doble clic mantiene su comportamiento actual.
- PDF, imágenes habituales (JPEG, PNG, HEIC) y texto plano/código en modo de lectura. No ejecutar HTML, scripts, aplicaciones ni macros. Carpetas, archivos comprimidos y formatos no admitidos muestran información y la opción de descargar.
- PDF e imágenes mediante Quick Look en una ventana de iCloudy; texto/código en un visor nativo de texto plano sin ejecución ni enlaces automáticos. Sin edición ni subida automática. Botón «Guardar copia…» para conservarlo expresamente, sin sobrescribir archivos existentes.
- Los textos grandes muestran únicamente el primer MB para mantener el visor ligero. «Guardar copia…» conserva el contenido completo descargado.
- Google Docs/Sheets/Slides: mantener «Abrir en navegador» y exportación explícita en esta primera versión. Una segunda fase podría exportar a PDF temporal, respetando los límites de Google.
- Audio/vídeo y documentos Office quedan para una segunda fase, tras validar formatos, codecs y tamaño. No prometer reproducción en streaming: Quick Look trabaja con un archivo local.

## Descarga, tamaño y limpieza

1. Descargar únicamente al solicitar la vista previa; nunca al seleccionar una fila o listar una carpeta.
2. Mostrar tamaño, progreso y Cancelar. Pedir confirmación por encima de 100 MB o si el tamaño es desconocido. El límite autorizado es 100 MB para tamaños desconocidos/pequeños y el tamaño anunciado para archivos mayores confirmados. Cancelar si el servidor anuncia o envía más bytes. Reservar margen de 20 MB al comprobar el espacio libre; macOS puede necesitar espacio adicional para generar la representación.
3. Guardar en una carpeta temporal privada de iCloudy, identificada por cuenta + archivo + sesión, con nombres locales seguros. No usar Descargas ni añadir contenido a favoritos/caché offline.
4. Reutilizar la copia solo mientras la vista previa esté abierta. Al cambiar de archivo, cerrar el visor o desconectar la cuenta, cancelar las descargas pendientes y eliminar sus temporales después de que el visor deje de usarlos.
5. Limpiar también al salir y al siguiente arranque para recuperar residuos tras un cierre inesperado. No borrar carpetas ajenas ni archivos guardados expresamente.
6. Si no hay conexión, permisos o soporte de formato, mostrar un mensaje claro y conservar la navegación. No descargar ni abrir en otra aplicación automáticamente como alternativa.

La limpieza cubre los temporales creados por iCloudy; no es una garantía de borrado seguro ni de ausencia de cachés internas de Quick Look/macOS.

## Verificación

- Vista previa desde lista y cuadrícula; teclado y menú contextual.
- Ambos proveedores; mismo nombre en dos cuentas sin mezcla de contenidos.
- Archivos vacíos, grandes, tamaño desconocido, nombre malicioso y formato no soportado.
- Cambiar rápidamente de selección, cerrar durante la descarga y desconectar la cuenta.
- Fallo de red, falta de espacio y recuperación tras cierre inesperado.
- «Guardar copia» conserva únicamente el destino elegido y no cambia el archivo remoto.

La suite automatizada cubre selección de formatos, consentimiento por tamaño, límites de bytes, disco insuficiente, texto vacío y truncado, contenido inválido, cambio de cuenta, cancelación, fallo de red, copia sin sobrescritura y limpieza de temporales tras cierre/arranque. La inspección del visor nativo requiere ejecutar la app en macOS; las pruebas locales no autorizan operaciones sobre cuentas reales.

Verificación manual en macOS: Espacio en lista y cuadrícula, Escape/Espacio para cerrar, texto de demo, menú contextual y rechazo de binarios no compatibles; PDF real de Google Drive renderizado en Quick Look. Se corrigió un doble cierre del visor nativo detectado en esta prueba. Cierre posterior verificado sin terminar la app y sin archivos restantes en su carpeta de temporales. OneDrive no se ha validado con una cuenta real: sigue pendiente su configuración OAuth.

Referencias: [QLPreviewPanel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel), [URL local requerida](https://developer.apple.com/documentation/quicklookui/qlpreviewitem/previewitemurl).
