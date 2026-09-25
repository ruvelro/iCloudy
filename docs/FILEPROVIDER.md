# La extensión del Finder

## Qué es

Una extensión File Provider (`NSFileProviderReplicatedExtension`) que enseña cada cuenta de iCloudy como una ubicación en la barra lateral del Finder, con los archivos bajo demanda: se listan al entrar en cada carpeta, se descargan al abrirlos y lo que se crea, renombra, mueve, borra o guarda en el Finder se aplica en la nube con los mismos proveedores que usa la ventana de iCloudy.

## Cómo está montada

- El paquete tiene tres targets. `iCloudy` es una librería con toda la aplicación, y conserva el nombre de módulo de siempre para que las pruebas, los metadatos de Atajos y el script de empaquetado no cambien. `iCloudyMain` es el binario del `.app`: un `main.swift` que llama a `AppLauncher.run()`. `iCloudyFileProvider` es la extensión, que enlaza la librería y se enlaza con `NSExtensionMain` como punto de entrada.
- La extensión no ve el código interno de la app: habla con `FileProviderBackend`, una fachada pública sobre `CloudAPI` que lista, descarga, sube, crea carpetas, renombra, mueve y borra, con `FPItem` como único tipo de intercambio. Los proveedores no saben de qué proceso los llaman.
- El Finder pregunta por los elementos uno a uno, por identificador, y `CloudFile` no lleva su carpeta padre. `FileProviderIndex` recuerda cada elemento listado con su padre, en un JSON en la carpeta temporal del dominio, para que otro arranque del proceso de la extensión sepa dónde vive cada cosa. Un listado nuevo de una carpeta sustituye a sus hijos conocidos, así que lo borrado en la nube desaparece también del índice.
- Cada cuenta es un dominio (`NSFileProviderDomain`) cuyo identificador es el de la cuenta. `FileProviderDomains` mantiene la lista de dominios igual a la de cuentas mientras el ajuste «Mostrar las nubes en el Finder» esté activado, y la retira al apagarlo o desconectar la cuenta. Los volúmenes del propio Mac y la demo no se publican.
- La app y la extensión viven en sandboxes distintos. Comparten dos cosas: la lista de cuentas (identidad, dirección y opciones; nunca un secreto), que la app exporta a un contenedor de App Group, y las credenciales, que siguen en el Llavero y se leen desde la extensión a través de un grupo de acceso al Llavero. El identificador de ese grupo lo escribe el script de empaquetado en los dos `Info.plist` (`iCloudyAppGroup`) y en los dos ficheros de permisos.

## Qué falta, y por qué

Tanto el App Group como el grupo de acceso al Llavero exigen un identificador de equipo de Apple: sin él, macOS no concede esos permisos y la extensión no tiene forma de saber qué cuentas hay ni con qué credenciales entrar. Por eso la extensión **solo se compila y se incrusta en el `.app` cuando `ICLOUDY_APP_GROUP` indica el grupo**:

```bash
ICLOUDY_APP_GROUP=group.com.ejemplo.icloudy ICLOUDY_SIGNING_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
```

Sin esa variable, el `.app` es exactamente el de antes y el ajuste del Finder aparece desactivado con la explicación. Con ella, el script copia el binario a `Contents/PlugIns/iCloudyFileProvider.appex`, le da su `Info.plist` (identificador `<app>.FileProvider`, punto de extensión `com.apple.fileprovider-nonui`, clase principal `iCloudyFileProvider.FileProviderExtension`) y firma la extensión y la app con el grupo en ambos.

Lo que no se ha podido verificar todavía, por no existir ese identificador: que el Finder cargue la extensión, que el Llavero entregue las credenciales al proceso de la extensión y el comportamiento con archivos grandes o carpetas de miles de elementos. Lo que sí está probado, contra la demo local: la forma de los elementos, el índice, el cálculo de dominios y el backend de punta a punta (listar, crear carpeta, subir, renombrar, mover, descargar y borrar).

## Lo que la extensión no hace

- No mantiene un flujo de cambios: los proveedores no lo ofrecen, así que `enumerateChanges` no informa de nada y el Finder vuelve a listar cuando le hace falta.
- No enseña la papelera ni el «conjunto de trabajo» (`workingSet`): ambos devuelven listas vacías para que el Finder no se quede esperando.
- Los documentos de Google no tienen contenido descargable sin exportar; en el Finder se listan pero no se abren. La ventana de iCloudy los exporta.
