## Qué cambia y por qué

<!-- Una o dos frases. Si cierra un aviso: «Cierra #123». -->

## Cómo se ha probado

- [ ] `swift build -Xswiftc -warnings-as-errors`
- [ ] `swift test` (y `swift test --parallel` si toca pruebas o estado compartido)
- [ ] `scripts/lint.sh`
- [ ] Probado en la app (`ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/build-app.sh`), si cambia algo visible
- [ ] Pruebas de integración con servidor real (`scripts/ci/*.sh`), si toca S3, SFTP o FTPS

## Antes de pedir revisión

- [ ] Textos nuevos de la interfaz en castellano con `L(…)` y su traducción en `Resources/en.lproj/Localizable.strings`
      (plurales en `scripts/make-plurals.py`)
- [ ] Comentarios del código en inglés
- [ ] Pruebas nuevas en el archivo del área que tocan, con `TestSupport.swift` (sin `Task.sleep` fijos)
- [ ] `CHANGELOG.md` actualizado en «Sin publicar», si el cambio se nota al usarla
