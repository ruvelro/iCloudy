#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Escribe las maquetas HTML del README a partir de una sola definición de los datos de ejemplo.

Las capturas del README no son capturas: una captura real de iCloudy enseña correos, nombres de archivo y cuánto
ocupa la cuenta de alguien. Estas maquetas reproducen la interfaz con una cuenta inventada, y los iconos de archivo
y de nube son los mismos trazos y los mismos colores que dibuja la app, para que no prometan nada que no haga.

    python3 scripts/mockups/generar.py     # escribe los .html
    swift scripts/render-mockups.swift     # los convierte en docs/images/*.png
"""
import io, os

NUBE = '<svg viewBox="0 0 24 24"><path d="M6.5 19A4.5 4.5 0 0 1 6 10.1a6 6 0 0 1 11.6-1.6A4.2 4.2 0 0 1 18 19H6.5Z"/></svg>'
LUPA = '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>'
MAS  = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/></svg>'
ENGR = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.5v3M12 18.5v3M21.5 12h-3M5.5 12h-3M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1M18.7 18.7l-2.1-2.1M7.4 7.4 5.3 5.3"/></svg>'

HERR = ''.join([
 '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.5v3M12 18.5v3M21.5 12h-3M5.5 12h-3"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v4h-4"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M12 15V3M8 7l4-4 4 4"/><path d="M4 15v4h16v-4"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M3 7h6l2 2h10v10H3z"/><path d="M17 11v6M14 14h6"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M12 3v12M8 11l4 4 4-4"/><path d="M4 19h16"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6S2 12 2 12Z"/><circle cx="12" cy="12" r="2.6"/></svg>',
 '<svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
 '<svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
 '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 16v.01M12 13c0-2 2-2 2-3.6A2 2 0 0 0 10 9"/></svg>',
])


# Las nubes, con su icono. Drive y OneDrive usan las mismas coordenadas que el Canvas de AccountAppearance.swift,
# para que la maqueta y la app dibujen exactamente la misma forma.
DRIVE = ('<svg viewBox="0 0 32 32">'
  '<polygon points="11,2 0,22 6,31 17,11" fill="#0f9d59"/>'
  '<polygon points="11,2 21,2 32,22 21,22" fill="#fabc05"/>'
  '<polygon points="6,31 26,31 32,22 11,22" fill="#4285f4"/></svg>')
ONEDRIVE = ('<svg viewBox="0 0 32 32"><defs><linearGradient id="od" x1="0" y1="0" x2="1" y2="1">'
  '<stop offset="0" stop-color="#0545a6"/><stop offset="1" stop-color="#28c8f0"/></linearGradient></defs>'
  '<path d="M3 13C1 5 10 0 15 7c6-5 14-2 13 6 6 1 6 11 0 12H6C-1 25-3 15 3 13Z" fill="url(#od)"/></svg>')
DROPBOX = ('<svg viewBox="0 0 32 32"><g fill="#0d7ff2">'
  '<path d="M8 1 0 6.2l8 5.2 8-5.2Z"/><path d="M24 1l-8 5.2 8 5.2 8-5.2Z"/>'
  '<path d="M0 16.6l8 5.2 8-5.2-8-5.2Z"/><path d="M32 16.6l-8 5.2-8-5.2 8-5.2Z"/>'
  '<path d="M8 23.5l8 5.2 8-5.2-8-5.2Z"/></g></svg>')
BOX = ('<svg viewBox="0 0 32 32"><g fill="#0d7ff2">'
  '<polygon points="8,3 0,9 8,15 16,9"/><polygon points="24,3 32,9 24,15 16,9"/>'
  '<polygon points="8,17 0,11 8,5 16,11" opacity="0"/>'
  '<polygon points="8,15 16,9 24,15 16,21"/><polygon points="10,23 16,19 22,23 16,27"/></g></svg>')
BOX = ('<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="15" fill="#0061d5"/>'
  '<text x="16" y="23" font-size="17" font-weight="700" fill="#fff" text-anchor="middle"'
  ' font-family="-apple-system,Helvetica,sans-serif">b</text></svg>')
NEXTCLOUD = ('<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="15" fill="#0082c9"/>'
  '<g fill="none" stroke="#fff" stroke-width="2.6"><circle cx="11" cy="16" r="3.6"/><circle cx="21" cy="16" r="3.6"/></g>'
  '<circle cx="16" cy="16" r="1.9" fill="#fff"/></svg>')
NAS = ('<svg viewBox="0 0 32 32"><rect x="3" y="6" width="26" height="8" rx="2" fill="#7b8494"/>'
  '<rect x="3" y="18" width="26" height="8" rx="2" fill="#5d6675"/>'
  '<circle cx="8" cy="10" r="1.6" fill="#b9c0cc"/><circle cx="8" cy="22" r="1.6" fill="#43c463"/></svg>')
MEGA = ('<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="15" fill="#d9273e"/>'
  '<path d="M7 22V10l9 7 9-7v12" fill="none" stroke="#fff" stroke-width="2.8" stroke-linejoin="round"/></svg>')

CUENTAS = [
  ("Google Drive",  "ana@ejemplo.com",        DRIVE,     "6,9 GB de 18,3 GB", 38, "#4c8bf5"),
  ("OneDrive",      "ana.trabajo@ejemplo.com",ONEDRIVE,  "796 GB de 1,26 TB", 63, "#2f9ae0"),
  ("Dropbox",       "ana@ejemplo.com",        DROPBOX,   "389 MB de 2,95 GB", 13, "#3b8ff5"),
  ("Box",           "ana@estudio.es",         BOX,       "2,1 GB de 10 GB",   21, "#2f86e8"),
  ("Nextcloud",     "casa.ejemplo.net",       NEXTCLOUD, "148 GB de 500 GB",  30, "#19a7ef"),
  ("Fotos (SMB)",   "NAS del salón",          NAS,       "1,4 TB de 4 TB",    35, "#8b93a3"),
]

def lateral(activa=0, pestana="nubes"):
    filas = []
    for i, (nombre, correo, icono, medida, pct, color) in enumerate(CUENTAS):
        filas.append(f'''      <div class="cuenta{' activa' if i == activa else ''}">
        <div class="chapa">{icono}</div>
        <div class="texto">
          <div class="nombre" style="color:{color}">{nombre}</div>
          <div class="correo">{correo}</div>
          <div class="medida"><div class="carril"><i style="width:{pct}%;background:{color}"></i></div><span>{medida}</span></div>
        </div>
      </div>''')
    FAVS = [("Contratos 2026", "Google Drive", DRIVE), ("Memoria técnica.docx", "OneDrive", ONEDRIVE),
            ("Administración", "Dropbox", DROPBOX), ("Escáner", "NAS del salón", NAS)]
    favs = "".join(f'''      <div class="favorito"><div class="chapa chica">{ico}</div>
        <div class="texto"><div class="fnombre">{nom}</div><div class="correo">{cuenta}</div></div></div>'''
        for nom, cuenta, ico in FAVS)
    activa_nubes = ' sel' if pestana == "nubes" else ''
    activa_favs = ' sel' if pestana == "favoritos" else ''
    return f'''  <aside class="lateral">
    <div class="marca">{NUBE}<span>iCloudy</span></div>
    <div class="buscador">{LUPA}<span>Buscar en todas las nubes</span></div>
    <div class="pestanas"><span class="pestana{activa_nubes}">Nubes</span><span class="pestana{activa_favs}">Favoritos (4)</span></div>
    <div class="cuentas">
{chr(10).join(filas) if pestana == "nubes" else favs}
    </div>
    <div class="pie-lateral">
      <div class="fila">{MAS}<span>Añadir cuenta</span></div>
      <div class="fila">{ENGR}<span>Configuración</span></div>
    </div>
    <div class="nota">Solo se descarga lo que eliges</div>
  </aside>'''

def pagina(titulo, contenido, activa=0, pestana="nubes"):
    return f'''<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
<title>{titulo}</title><link rel="stylesheet" href="estilo.css"></head><body>
<div class="ventana">
  <div class="barra">
    <span class="semaforo rojo"></span><span class="semaforo ambar"></span><span class="semaforo verde"></span>
    <span class="titulo">{titulo}</span>
    <div class="herramientas">{HERR}</div>
  </div>
  <div class="cuerpo">
{lateral(activa, pestana)}
{contenido}
  </div>
</div></body></html>'''

# --- Iconos de archivo y estado -------------------------------------------------
# Un glifo por FileKind, con el color exacto de FileKind.tint. Las capturas del README tienen que enseñar lo que la
# app dibuja de verdad, así que estas formas siguen a los símbolos de SF que usa FileIcon.swift.
PDF, DOCU, HOJA, PRES = "#de544d", "#4c8cf5", "#409e59", "#de8c3d"
IMG, VIDEO, AUDIO, ZIP, CODE, GRIS = "#a373e8", "#5978eb", "#e8669e", "#998770", "#33aeae", "#8b91a0"

def _svg(cuerpo, size=16):
    return f'<svg class="estado" viewBox="0 0 24 24" style="width:{size}px;height:{size}px">{cuerpo}</svg>'
def hoja(color, interior=""):
    """La silueta de doc.fill: papel con la esquina doblada."""
    return (f'<path d="M6 2h7l5 5v15H6z" fill="{color}"/>'
            f'<path d="M13 2l5 5h-5z" fill="#000" opacity=".22"/>{interior}')
def DOC_PDF():   return _svg(hoja(PDF, '<g fill="#fff" opacity=".9"><rect x="8.4" y="11" width="7" height="1.3" rx=".6"/><rect x="8.4" y="14" width="7" height="1.3" rx=".6"/><rect x="8.4" y="17" width="4.4" height="1.3" rx=".6"/></g>'))
def DOC_TXT():   return _svg(hoja(DOCU, '<g fill="#fff" opacity=".9"><rect x="8.4" y="11" width="7" height="1.3" rx=".6"/><rect x="8.4" y="14" width="7" height="1.3" rx=".6"/><rect x="8.4" y="17" width="4.4" height="1.3" rx=".6"/></g>'))
def DOC_PLANO(): return _svg(hoja(GRIS, '<g fill="#fff" opacity=".85"><rect x="8.4" y="11" width="7" height="1.2" rx=".6"/><rect x="8.4" y="14" width="7" height="1.2" rx=".6"/></g>'))
def TABLA():     return _svg(f'<rect x="3" y="4.5" width="18" height="15" rx="2.4" fill="{HOJA}"/>'
                             '<g stroke="#fff" stroke-width="1.15" opacity=".92"><path d="M3 9.6h18M3 14.5h18M9.6 4.5v15M15.2 4.5v15"/></g>')
def DIAPOS():    return _svg(f'<rect x="5" y="3" width="15" height="11" rx="1.8" fill="{PRES}" opacity=".55"/>'
                             f'<rect x="3" y="7" width="15" height="12" rx="1.8" fill="{PRES}"/>')
def FOTO():      return _svg(f'<rect x="3" y="5" width="18" height="14" rx="2.4" fill="{IMG}"/>'
                             '<circle cx="8.4" cy="10" r="1.9" fill="#fff" opacity=".95"/>'
                             '<path d="M4.6 18.2l5-5.2 3.4 3.4 3.2-3.1 3.2 4.9z" fill="#fff" opacity=".9"/>')
def PELI():      return _svg(f'<rect x="2.5" y="5" width="19" height="14" rx="2.2" fill="{VIDEO}"/>'
                             '<g fill="#fff" opacity=".92"><rect x="4.4" y="7" width="2.4" height="2.2" rx=".5"/><rect x="4.4" y="11" width="2.4" height="2.2" rx=".5"/><rect x="4.4" y="15" width="2.4" height="2.2" rx=".5"/><rect x="17.2" y="7" width="2.4" height="2.2" rx=".5"/><rect x="17.2" y="11" width="2.4" height="2.2" rx=".5"/><rect x="17.2" y="15" width="2.4" height="2.2" rx=".5"/></g>')
def ONDA():      return _svg(f'<g stroke="{AUDIO}" stroke-width="1.8" stroke-linecap="round" fill="none">'
                             '<path d="M3 12h1.6M20.4 12H22"/><path d="M7 8.5v7M10.5 5.5v13M14 7v10M17.5 9.5v5"/></g>')
def CREMA():     return _svg(hoja(ZIP, '<g fill="#fff" opacity=".95"><rect x="10.7" y="8" width="2.6" height="1.6"/><rect x="10.7" y="11" width="2.6" height="1.6"/><rect x="10.7" y="14" width="2.6" height="1.6"/><rect x="10.4" y="17" width="3.2" height="3.6" rx="1"/></g>'))
def CODIGO():    return _svg(f'<g stroke="{CODE}" stroke-width="2.1" fill="none" stroke-linecap="round" stroke-linejoin="round">'
                             '<path d="M9 8l-5 4 5 4M15 8l5 4-5 4"/></g>')
CARPETA = _svg('<path d="M3 6.5h5.6l2 2H21v10.5a1.6 1.6 0 0 1-1.6 1.6H4.6A1.6 1.6 0 0 1 3 19V6.5Z" fill="#4c8bf5"/>'
               '<path d="M3 6.5h5.6l2 2H3Z" fill="#6ea2f7"/>')
EN_MAC = '<svg class="estado" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="#43c463"/><path d="m8 12.4 2.7 2.7L16 9.8" fill="none" stroke="#10241a" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
SOLO_NUBE = '<svg class="estado" viewBox="0 0 24 24"><path d="M6.5 18A4 4 0 0 1 6 10.2a5.6 5.6 0 0 1 10.8-1.5A3.9 3.9 0 0 1 17.5 18Z" fill="none" stroke="#6a7180" stroke-width="1.5"/></svg>'
DESFASE = '<svg class="estado" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="#e8a33d"/><path d="M12 7.5v5M12 16v.01" stroke="#2a1c06" stroke-width="2.2" stroke-linecap="round"/></svg>'

# --- 1. Explorador --------------------------------------------------------------
FILAS = [
 (CARPETA, "Contratos 2026", "12 sept 2026", "—", SOLO_NUBE, False),
 (CARPETA, "Fotos del viaje", "3 sept 2026", "—", SOLO_NUBE, False),
 (CARPETA, "Proyecto Aurora", "28 ago 2026", "—", SOLO_NUBE, False),
 (DOC_PDF(), "Contrato-marco-firmado.pdf", "15 sept 2026", "2,4 MB", EN_MAC, True),
 (TABLA(), "Presupuesto anual.xlsx", "14 sept 2026", "884 KB", EN_MAC, False),
 (DOC_TXT(), "Memoria técnica.docx", "11 sept 2026", "1,2 MB", SOLO_NUBE, False),
 (FOTO(), "Portada-nueva.jpg", "9 sept 2026", "6,8 MB", DESFASE, False),
 (DIAPOS(), "Presentación cliente.key", "8 sept 2026", "24,1 MB", SOLO_NUBE, False),
 (PELI(), "Demo del producto.mp4", "5 sept 2026", "412 MB", SOLO_NUBE, False),
 (ONDA(), "Banda sonora.m4a", "3 sept 2026", "18,2 MB", SOLO_NUBE, False),
 (CREMA(), "Entrega-v3.zip", "1 sept 2026", "88,6 MB", SOLO_NUBE, False),
 (CODIGO(), "informe.swift", "30 ago 2026", "24 KB", EN_MAC, False),
 (TABLA(), "Clientes-export.csv", "29 ago 2026", "310 KB", EN_MAC, False),
 (DOC_PLANO(), "notas.txt", "27 ago 2026", "4 KB", SOLO_NUBE, False),
]
filas = "".join(
  f'<tr class="{"sel" if sel else ""}"><td><div class="nom">{est}{ico}<span>{nom}</span></div></td>'
  f'<td class="num">{mod}</td><td class="num">{tam}</td></tr>'
  for ico, nom, mod, tam, est, sel in FILAS)

explorador = f'''  <section class="principal">
    <div class="cabecera"><h1>Mis archivos</h1><div class="sub">ana@ejemplo.com · Google Drive</div></div>
    <div class="controles">
      <div class="miga"><span class="chip">Inicio</span><span>›</span><span class="chip">Trabajo</span></div>
      <div class="campo">Filtrar esta carpeta</div><div class="orden">Nombre ⌄</div>
    </div>
    <div class="lista">
      <table><thead><tr><th>Nombre</th><th style="width:150px">Modificado</th><th style="width:110px">Tamaño</th></tr></thead>
      <tbody>{filas}</tbody></table>
    </div>
    <div class="pie"><span>14 elementos</span><span class="verdecito">✓ 3 en este Mac</span>
      <span class="der">Arrastra aquí para subir una copia</span></div>
  </section>'''

# --- 2. Transferencias ----------------------------------------------------------
FLECHAS = {"sube": '<path d="M12 19V5M6 11l6-6 6 6"/>', "baja": '<path d="M12 5v14M6 13l6 6 6-6"/>',
           "cruza": '<path d="M4 9h16M16 5l4 4-4 4M20 15H4M8 11l-4 4 4 4"/>'}
def sello(tipo, color):
    return (f'<span class="sello" style="background:{color}"><svg viewBox="0 0 24 24" fill="none" stroke="#fff"'
            f' stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round">{FLECHAS[tipo]}</svg></span>')
def tarjeta(nube, tipo, nom, destino, estado, metrica, pct, color="#6f9dff", activa=False):
    barra = (f'<div class="rail"><i style="width:{pct}%;background:{color}"></i></div>') if pct is not None else ''
    derecha = f'<span class="pct">{estado}</span>'
    return f'''<div class="tarjeta{' viva' if activa else ''}">
      <div class="tcab"><span class="tnube">{nube}{sello(tipo, color)}</span>
        <span class="tnom">{nom}</span>{derecha}</div>
      <div class="tsub">{destino}</div>
      <div class="tmeta"><span>{metrica[0]}</span><span class="der">{metrica[1]}</span></div>
      {barra}</div>'''

cajon = f'''<aside class="cajon">
  <div class="cjcab"><span class="cjtit">Transferencias</span><span class="cjnum">4 en cola</span></div>
  {tarjeta(DRIVE, "sube", "Demo del producto.mp4", "Trabajo / Proyecto Aurora", "65 %", ("Subiendo", "268 de 412 MB · 9,4 MB/s"), 65, "#6f9dff", True)}
  {tarjeta(DRIVE, "sube", "Fotos del viaje", "Trabajo / Fotos del viaje", "40 %", ("Carpeta", "84 de 210 archivos"), 40, "#6f9dff")}
  {tarjeta(DROPBOX, "sube", "Entrega-v3.zip", "/Administración", "En espera", ("En cola", "88,6 MB"), 0)}
  {tarjeta(BOX, "cruza", "Memoria técnica.docx", "De OneDrive a Box", "22 %", ("Descargando", "1,2 MB"), 22, "#a78bfa")}
  <div class="hoy">
    <div class="hoytit">COMPLETADAS HOY</div>
    <div class="hoyfila"><span class="ok">✓</span><span class="hnom">Contrato-marco-firmado.pdf</span><span class="hhora">17:42</span></div>
    <div class="hoyfila"><span class="ok">✓</span><span class="hnom">Presupuesto anual.xlsx</span><span class="hhora">17:31</span></div>
    <div class="hoyfila"><span class="ok">✓</span><span class="hnom">Clientes-export.csv</span><span class="hhora">16:58</span></div>
  </div>
</aside>'''

principal_corta = explorador.replace('<div class="lista">', '<div class="lista" style="max-width:100%">')
transferencias = principal_corta + "\n" + cajon

# --- 3. Búsqueda global ---------------------------------------------------------
def hit(icono, ico, nom, ruta, cuenta, tam):
    return f'''<tr><td><div class="nom">{ico}<span>{nom}</span></div></td>
      <td class="num"><span style="display:inline-flex;align-items:center;gap:7px">
      <span class="chapa chica">{icono}</span>{cuenta}</span></td>
      <td class="num">{ruta}</td><td class="num">{tam}</td></tr>'''

hits = "".join([
 hit(DRIVE, DOC_PDF(), "Contrato-marco-firmado.pdf", "Trabajo / Contratos 2026", "Google Drive", "2,4 MB"),
 hit(ONEDRIVE, DOC_TXT(), "Contrato de mantenimiento.docx", "Documentos / Legal", "OneDrive", "640 KB"),
 hit(DROPBOX, DOC_PDF(), "Contrato-proveedor-2025.pdf", "/Administración", "Dropbox", "1,1 MB"),
 hit(BOX, CARPETA, "Contratos archivados", "Estudio / Histórico", "Box", "—"),
 hit(NEXTCLOUD, TABLA(), "Contratos-resumen.xlsx", "/Casa/Papeleo", "Nextcloud", "98 KB"),
 hit(NAS, DOC_PDF(), "Contrato alquiler local.pdf", "Fotos (SMB) / Escáner", "NAS del salón", "3,7 MB"),
])

busqueda = f'''  <section class="principal">
    <div class="cabecera"><h1>Buscar en todas las nubes</h1>
      <div class="sub">6 resultados para «contrato» en 6 cuentas · 0,9 s</div></div>
    <div class="controles">
      <div class="miga"><span class="chip" style="background:rgba(122,167,255,.2);color:#cfe0ff">contrato</span>
        <span class="chip">Todas las cuentas</span><span class="chip">Cualquier tipo</span><span class="chip">Cualquier fecha</span></div>
      <div class="orden">Relevancia ⌄</div>
    </div>
    <div class="lista">
      <table><thead><tr><th>Nombre</th><th style="width:170px">Cuenta</th><th style="width:210px">Ubicación</th><th style="width:90px">Tamaño</th></tr></thead>
      <tbody>{hits}</tbody></table>
      <div style="padding:14px 10px;font-size:12px;color:#6f9dff">Cargar más resultados</div>
    </div>
    <div class="pie"><span>Se buscan nombres, nunca contenidos</span>
      <span class="der">⇧⌘F para buscar desde cualquier sitio</span></div>
  </section>'''

os.makedirs("scripts/mockups", exist_ok=True)
io.open("scripts/mockups/explorador.html","w",encoding="utf-8").write(pagina("iCloudy — Mis archivos", explorador, 0))
io.open("scripts/mockups/transferencias.html","w",encoding="utf-8").write(pagina("iCloudy — Transferencias", transferencias, 0))
io.open("scripts/mockups/busqueda.html","w",encoding="utf-8").write(pagina("iCloudy — Búsqueda global", busqueda, 0))
io.open("scripts/mockups/favoritos.html","w",encoding="utf-8").write(pagina("iCloudy — Favoritos", explorador, 0, "favoritos"))
print("maquetas escritas")
