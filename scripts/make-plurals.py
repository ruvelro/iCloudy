#!/usr/bin/env python3
"""Writes Resources/es.lproj and Resources/en.lproj Localizable.stringsdict from the table below.

Each sentence that carries a count, and can carry a 1, is listed with the words that agree with that count in each
language. The key is the Spanish sentence as the code writes it, with %lld for the count; String(localized:) finds the
entry by that key and picks the singular or the plural form. Run it after editing the table:

    python3 scripts/make-plurals.py
"""
import plistlib, pathlib

# key, Spanish format, Spanish variables, English format, English variables. A variable is (name, one, other).
TABLE = [
    ("%lld elementos", "%#@n@", [("n", "%lld elemento", "%lld elementos")], "%#@n@", [("n", "%lld item", "%lld items")]),
    ("%lld elementos.", "%#@n@.", [("n", "%lld elemento", "%lld elementos")], "%#@n@.", [("n", "%lld item", "%lld items")]),
    ("%lld finalizadas", "%#@n@", [("n", "%lld finalizada", "%lld finalizadas")], "%#@n@", [("n", "%lld finished", "%lld finished")]),
    ("%lld seleccionados", "%#@n@", [("n", "%lld seleccionado", "%lld seleccionados")], "%#@n@", [("n", "%lld selected", "%lld selected")]),
    ("%lld transferencias en espera", "%#@n@ en espera", [("n", "%lld transferencia", "%lld transferencias")],
     "%#@n@ waiting", [("n", "%lld transfer", "%lld transfers")]),
    ("%lld transferencias en curso", "%#@n@ en curso", [("n", "%lld transferencia", "%lld transferencias")],
     "%#@n@ in progress", [("n", "%lld transfer", "%lld transfers")]),
    ("%lld transferencias en pausa.", "%#@n@ en pausa.", [("n", "%lld transferencia", "%lld transferencias")],
     "%#@n@ paused.", [("n", "%lld transfer", "%lld transfers")]),
    ("%lld transferencias reanudadas.", "%#@n@.", [("n", "%lld transferencia reanudada", "%lld transferencias reanudadas")],
     "%#@n@ resumed.", [("n", "%lld transfer", "%lld transfers")]),
    ("Comprobando %lld carpetas reflejadas.", "Comprobando %#@n@.", [("n", "%lld carpeta reflejada", "%lld carpetas reflejadas")],
     "Checking %#@n@.", [("n", "%lld mirrored folder", "%lld mirrored folders")]),
    ("%lld subidos", "%#@n@", [("n", "%lld subido", "%lld subidos")], "%#@n@", [("n", "%lld uploaded", "%lld uploaded")]),
    ("%lld bajados", "%#@n@", [("n", "%lld bajado", "%lld bajados")], "%#@n@", [("n", "%lld downloaded", "%lld downloaded")]),
    ("%lld borrados en la nube", "%#@n@ en la nube", [("n", "%lld borrado", "%lld borrados")],
     "%#@n@ in the cloud", [("n", "%lld deleted", "%lld deleted")]),
    ("%lld enviados a la papelera del Mac", "%#@n@ a la papelera del Mac", [("n", "%lld enviado", "%lld enviados")],
     "%#@n@ to the Mac's Trash", [("n", "%lld sent", "%lld sent")]),
    ("%lld conflictos", "%#@n@", [("n", "%lld conflicto", "%lld conflictos")], "%#@n@", [("n", "%lld conflict", "%lld conflicts")]),
    ("%lld enlaces", "%#@n@", [("n", "%lld enlace", "%lld enlaces")], "%#@n@", [("n", "%lld link", "%lld links")]),
    ("%lld archivos en cola hacia %@.", "%#@n@ en cola hacia %@.", [("n", "%lld archivo", "%lld archivos")],
     "%#@n@ queued to %@.", [("n", "%lld file", "%lld files")]),
    ("%lld archivos enviados a la papelera.", "%#@n@ a la papelera.", [("n", "%lld archivo enviado", "%lld archivos enviados")],
     "%#@n@ to the trash.", [("n", "%lld file moved", "%lld files moved")]),
    ("%lld carpetas · %lld archivos", "%#@folders@ · %#@files@", [("folders", "%lld carpeta", "%lld carpetas"), ("files", "%lld archivo", "%lld archivos")],
     "%#@folders@ · %#@files@", [("folders", "%lld folder", "%lld folders"), ("files", "%lld file", "%lld files")]),
    ("%lld archivos en %lld carpetas", "%#@files@ en %#@folders@", [("files", "%lld archivo", "%lld archivos"), ("folders", "%lld carpeta", "%lld carpetas")],
     "%#@files@ in %#@folders@", [("files", "%lld file", "%lld files"), ("folders", "%lld folder", "%lld folders")]),
    ("Comprobados %lld archivos.", "%#@n@.", [("n", "Comprobado %lld archivo", "Comprobados %lld archivos")],
     "%#@n@ checked.", [("n", "%lld file", "%lld files")]),
    ("%lld completadas, %@. Ábrelas en el panel de transferencias para reintentarlas.",
     "%#@n@, %@. Ábrelas en el panel de transferencias para reintentarlas.", [("n", "%lld completada", "%lld completadas")],
     "%#@n@ completed, %@. Open the transfers panel to retry them.", [("n", "%lld", "%lld")]),
    ("%lld coinciden con la suma del proveedor.", "%#@n@ con la suma del proveedor.", [("n", "%lld coincide", "%lld coinciden")],
     "%#@n@ the provider's checksum.", [("n", "%lld matches", "%lld match")]),
    ("%lld coinciden en tamaño; no hay suma con la que compararlos.", "%#@n@; no hay suma con la que compararlos.",
     [("n", "%lld coincide en tamaño", "%lld coinciden en tamaño")],
     "%#@n@ in size; there is no checksum to compare them with.", [("n", "%lld matches", "%lld match")]),
    ("%lld no se pudieron comprobar.", "%#@n@.", [("n", "%lld no se pudo comprobar", "%lld no se pudieron comprobar")],
     "%#@n@ be checked.", [("n", "%lld could not", "%lld could not")]),
    ("%lld se dejaron fuera a propósito.", "%#@n@ a propósito.", [("n", "%lld se dejó fuera", "%lld se dejaron fuera")],
     "%#@n@ left out on purpose.", [("n", "%lld was", "%lld were")]),
    ("%lld no están en el destino o no coinciden: quedan pendientes.", "%#@n@.",
     [("n", "%lld no está en el destino o no coincide: queda pendiente", "%lld no están en el destino o no coinciden: quedan pendientes")],
     "%#@n@.", [("n", "%lld is not at the destination or does not match: it is pending again",
                  "%lld are not at the destination or do not match: they are pending again")]),
    ("Quedan %lld por transferir o por comprobar.", "%#@n@ por transferir o por comprobar.", [("n", "Queda %lld", "Quedan %lld")],
     "%#@n@ still to be transferred or checked.", [("n", "%lld is", "%lld are")]),
    ("%lld archivos ya están en el destino (%@).", "%#@n@ en el destino (%@).", [("n", "%lld archivo ya está", "%lld archivos ya están")],
     "%#@n@ already at the destination (%@).", [("n", "%lld file is", "%lld files are")]),
    ("En pausa · %lld cambios esperando", "En pausa · %#@n@", [("n", "%lld cambio esperando", "%lld cambios esperando")],
     "Paused · %#@n@", [("n", "%lld change waiting", "%lld changes waiting")]),
]

def entry(format_key, variables):
    value = {"NSStringLocalizedFormatKey": format_key}
    for name, one, other in variables:
        value[name] = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld", "one": one, "other": other}
    return value

root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
for language, index in (("es", 1), ("en", 3)):
    table = {row[0]: entry(row[index], row[index + 1]) for row in TABLE}
    folder = root / f"{language}.lproj"
    folder.mkdir(exist_ok=True)
    with open(folder / "Localizable.stringsdict", "wb") as handle:
        plistlib.dump(table, handle, sort_keys=True)
print(f"{len(TABLE)} entries written")
