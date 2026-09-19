#!/bin/bash
# Qué despierta este Mac mientras duerme.
#
# Existe por una razón concreta del proyecto: la sesión de O2 Cloud muere tras algo más de una hora sin peticiones,
# y iCloudy la mantiene viva con un toque periódico. Ese toque solo sale si macOS despierta el equipo a oscuras y le
# da hueco. Cuando una sesión se cae de madrugada, la pregunta no es si iCloudy falló, sino si el Mac llegó a
# despertar. Esto responde a eso.
#
# Uso:  bash scripts/despertares.sh
set -uo pipefail
# El grep del sistema, porque un alias a ripgrep interpreta -E como «codificación» y falla.
grep=/usr/bin/grep
registro="$(pmset -g log 2>/dev/null)"

echo "== Quién fija la hora del próximo despertar =="
echo "   (el ganador de cada negociación; dasd es el planificador de tareas de fondo)"
printf '%s\n' "$registro" | "$grep" -oE '\*process=[A-Za-z]+' | sed 's/\*process=//' | sort | uniq -c | sort -rn | head -6

echo
echo "== Por qué despertó =="
# Solo las líneas de despertar: "due to" aparece también al dormirse, y mezclarlas hacía que
# 'Maintenance Sleep' apareciera como si fuera un motivo de despertar, que es justo lo contrario.
printf '%s\n' "$registro" | "$grep" -E 'DarkWake|^[0-9-]+ [0-9:]+ [^ ]+ Wake ' | "$grep" -v 'Wake Requests' \
    | "$grep" -oE 'due to [^:]*' | sed 's/due to //' | cut -c1-58 | sort | uniq -c | sort -rn | head -6

echo
echo "== Por qué se durmió =="
printf '%s\n' "$registro" | "$grep" -E 'Entering Sleep' \
    | "$grep" -oE "due to '[^']*'" | sed "s/due to //" | sort | uniq -c | sort -rn | head -5

echo
echo "== Tramos dormido sin despertar ni una vez (ahí es donde muere la sesión) =="
# Lo que importa no es el hueco entre despertares: si el Mac está despierto no despierta, y eso salía como
# un hueco enorme cuando en realidad todo funcionaba. Lo que cuenta es cuánto durmió de un tirón, así que se
# empareja cada entrada en reposo con el despertar siguiente.
printf '%s\n' "$registro" | python3 -c '
import sys, re
from datetime import datetime
eventos = []
for linea in sys.stdin:
    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", linea)
    if not m: continue
    cuando = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
    # "Wake Requests" no es un despertar, es la lista de quién ha pedido el siguiente, y se escribe un
    # segundo después de dormirse. Contarla daba tramos de sueño de cero minutos.
    if re.search(r"Wake Requests", linea): continue
    if re.search(r"Entering Sleep", linea): eventos.append((cuando, "duerme"))
    elif re.search(r"\bDarkWake\b|\bWake\b", linea): eventos.append((cuando, "despierta"))
eventos.sort()
tramos, dormido = [], None
for cuando, tipo in eventos:
    if tipo == "duerme" and dormido is None: dormido = cuando
    elif tipo == "despierta" and dormido is not None:
        tramos.append((dormido, (cuando-dormido).total_seconds()/60)); dormido = None
largos = [t for t in tramos if t[1] > 60]
print(f"   {len(tramos)} tramos de sueño; el más largo, {max((t[1] for t in tramos), default=0):.0f} min")
if not largos: print("   ninguno pasó de una hora: la sesión nunca estuvo en peligro por esto")
for inicio, minutos in largos[-6:]:
    print(f"   {inicio:%d %b %H:%M}  durmió {minutos:.0f} min seguidos")
'
echo
echo "== Despertares programados pendientes =="
pmset -g sched 2>/dev/null | tail -n +2 | head -5
