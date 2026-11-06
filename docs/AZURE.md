# Azure Blob Storage

iCloudy se conecta a las cuentas de almacenamiento de Azure (Blob Storage) sin SDK: cada petición se firma en el Mac
con **Shared Key**, escrita sobre CryptoKit, o lleva un **token SAS** que alguien generó para la cuenta. La clave de la
cuenta se guarda en el Llavero y **nunca viaja**: solo sirve para firmar.

> 🧪 **Experimental.** Está probado contra un servidor simulado que responde como Azure (`AzureProviderTests`) y
> contra los ejemplos de la documentación de Microsoft, pero no contra una cuenta real ni contra Azurite. Si lo usas,
> cuéntanos qué tal va.

El código está en `Sources/iCloudy/Providers/Azure/`:

| Archivo | Qué hace |
|---|---|
| `AzureSigner.swift` | Shared Key (cadena a firmar, cabeceras y recurso canónicos) y SAS de servicio para un blob. |
| `AzureProvider.swift` | Dirección de la cuenta, transporte con reintentos, listados, carpetas, búsqueda, enlaces y el contrato `CloudProvider`. |
| `AzureTransfers.swift` | Subidas simples y por bloques con reanudación, descargas por rangos, copias, movimientos y borrados. |
| `AzureXML.swift` | Lectura de `EnumerationResults` y de los `<Error>` con el mismo árbol XML que S3. |
| `AzureAuthentication.swift` | Comprobación de la credencial al conectar y construcción de la cuenta. |

## Conectar

En «Añade tu nube» → «Almacenamiento de objetos» → «Conectar Azure Blob Storage». El formulario pide:

- **Nombre de la cuenta de almacenamiento**: el de `cuenta.blob.core.windows.net`, de 3 a 24 minúsculas y números.
- **Credencial**:
  - **Clave de la cuenta**, la de «Claves de acceso» en el portal (Base64). Con ella iCloudy firma cada petición y
    puede crear enlaces temporales.
  - **Token SAS**, tal y como lo da el portal (`sv=…&ss=…&sp=…&sig=…`, con o sin el `?` del principio). Se añade a
    cada petición y no firma nada más: iCloudy solo hace lo que el token permite, y no puede crear enlaces, porque un
    SAS no firma otro y repartir el propio token daría acceso a todo lo que él permite.
- **Contenedor (opcional)**. Vacío, la raíz es la lista de contenedores que la credencial puede listar; con un
  nombre, la raíz es ese contenedor. Un SAS limitado a un contenedor no puede listar los demás, y el formulario lo
  explica si se deja vacío.
- **Avanzado → dirección**: para nubes soberanas (`*.blob.core.chinacloudapi.cn`…), dominios propios o Azurite
  (`http://127.0.0.1:10000/devstoreaccount1`, que lleva la cuenta en la ruta). `http://` solo en la red local.

Antes de guardar nada, iCloudy lista el contenedor (o los contenedores) con esa credencial. La cuenta se identifica
por la dirección, el contenedor y el tipo de credencial (`azure:host/ruta/contenedor#sharedKey`).

## Firma

**Shared Key** (versión de la API `2021-08-06`): HMAC-SHA256, con la clave decodificada, de

```
VERBO \n Content-Encoding \n Content-Language \n Content-Length \n Content-MD5 \n Content-Type \n Date \n
If-Modified-Since \n If-Match \n If-None-Match \n If-Unmodified-Since \n Range \n
cabeceras x-ms- en minúsculas, ordenadas, «nombre:valor\n»
/cuenta/ruta-codificada \n parámetro:valor … (nombres en minúsculas, ordenados, valores decodificados)
```

`Content-Length` va vacío cuando el cuerpo está vacío, como piden las versiones desde la 2015-02-21. La fecha va en
`x-ms-date`, así que `Date` queda vacío. La prueba `testTheSharedKeyStringToSignMatchesMicrosoftsExample` reproduce
el ejemplo de «Get Container Metadata» de la documentación y su firma con la clave pública de desarrollo de Azurite.

**Enlaces**: un SAS de servicio para un blob, de solo lectura (`sp=r`, `sr=b`), solo HTTPS, válido desde cinco minutos
antes (por los relojes) hasta la caducidad elegida (1 hora, 1 día o 7 días). La cadena a firmar es la de las versiones
2020-12-06 y posteriores, con el ámbito de cifrado vacío. Como en S3, un enlace no se puede revocar antes de que caduque
salvo regenerando la clave de la cuenta.

## Carpetas

Blob Storage no tiene carpetas, solo nombres con barras (salvo las cuentas con espacio de nombres jerárquico, que
iCloudy trata igual). Se dibujan con los `BlobPrefix` de un listado con delimitador `/`, siguiendo los `NextMarker`.
«Nueva carpeta» crea un blob vacío `nombre/` con el metadato `hdi_isfolder=true`, el que usan las herramientas de
Azure. El identificador de cada elemento es `contenedor/nombre`; el de una carpeta termina en `/`. iCloudy no crea,
renombra ni borra contenedores.

## Operaciones

| Operación | Cómo |
|---|---|
| Listar | `List Containers` y `List Blobs` con `prefix`, `delimiter=/` y `marker`, página a página. |
| Subir hasta 16 MB | Un `Put Blob` con `Content-MD5`; Azure rechaza un cuerpo que no coincida y devuelve el MD5 guardado, que se compara. |
| Subir más | `Put Block` por bloques de 8 MB (más si hacen falta más de 50 000), cada uno con su `Content-MD5`, y `Put Block List` con los identificadores en orden y el MD5 del archivo entero en `x-ms-blob-content-md5`. |
| Reanudar | El punto de control guarda la sesión (`azure-blocks`, un prefijo propio de identificadores y el blob destino) y los bloques aceptados. Un reintento sigue con el siguiente bloque y vuelve a calcular en el Mac el MD5 de lo ya enviado. Si Azure ya no tiene los bloques (caducan a la semana), lo dice y el siguiente intento empieza de cero. |
| No sobrescribir | `If-None-Match: *` al crear; al renombrar o mover se comprueba antes que el destino está libre. |
| Descargar | Por rangos de 32 MB con `x-ms-range`, cada uno fijado con `If-Match` a la versión del primero y repetido si se corta la conexión. Al final, el archivo entero se compara con el `Content-MD5` del listado cuando el blob lo tiene. |
| Copiar | `Copy Blob` dentro de la cuenta. Si Azure la deja `pending`, se sigue con `HEAD` hasta que termina, de modo que mover nunca borra un origen cuya copia no ha llegado. Una carpeta es cada blob bajo su prefijo. |
| Renombrar y mover | Copia y borrado, como en S3. |
| Borrar | `DELETE` con `x-ms-delete-snapshots: include`. Es definitivo: la eliminación temporal de Azure es un ajuste de la cuenta que iCloudy no puede listar, y la confirmación lo dice. |
| Buscar | Por prefijo desde el principio de cada contenedor, como S3. Siempre se marca como incompleta. |
| Espacio | No hay: una cuenta de almacenamiento no tiene un límite que consultar. |

Los 500 y los 503 (`ServerBusy`) se repiten tras una pausa que respeta `Retry-After`, solo para métodos que se pueden
repetir. Un 403 `AuthenticationFailed` marca la cuenta como caducada y pide volver a conectarla.

## Lo que falta

- **Azure AD / Entra ID** (OAuth con tokens de usuario) y **SAS de delegación de usuario**: necesitarían registrar una
  aplicación en Entra. Hoy, clave de la cuenta o SAS.
- **Niveles de acceso** (Hot, Cool, Archive): un blob archivado no se puede leer sin rehidratarlo, y iCloudy lo
  informa con el error de Azure.
- **Versiones e instantáneas** de blobs, y la papelera de eliminación temporal.
- **Azure Files** y **Data Lake Gen2** con su API propia (`dfs`): el endpoint `blob` de una cuenta con espacio de
  nombres jerárquico funciona como el de cualquier otra.
