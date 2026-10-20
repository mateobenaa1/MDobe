#!/bin/zsh
# Compila MDobe para iPad firmado con el Apple ID gratuito de Xcode y lo instala en el iPad (cable o wifi).
# Con --if-due solo actúa si la última instalación tiene más de 4 días (lo usa la tarea automática, que corre
# desde la copia de ~/Library/Application Support/MDobe/ipad-src: ver install-ipad-agent.sh).
set -e
cd "$(dirname "$0")/.."
STAMP="$HOME/Library/Application Support/MDobe/ipad-last-install"
mkdir -p "$(dirname "$STAMP")"
log() { echo "$(date '+%F %T') $*"; }

if [[ "$1" == "--if-due" && -f "$STAMP" ]] && (( $(date +%s) - $(cat "$STAMP") < 4 * 86400 )); then
  exit 0
fi

# Equipo personal de Xcode (se crea al añadir el Apple ID en Xcode → Ajustes → Cuentas)
TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -m1 -oE 'teamID = [A-Z0-9]{10}' | awk '{print $3}')
[[ -z "$TEAM" ]] && TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -m1 -oE 'teamID = [A-Z0-9]{10}' | awk '{print $3}')
if [[ -z "$TEAM" ]]; then log "No encuentro tu Apple ID en Xcode (Ajustes → Cuentas)."; exit 1; fi

# Primer iPad emparejado y disponible
JSON=$(mktemp)
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
DEVICE=$(/usr/bin/python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("result",{}).get("devices",[]):
    hw=x.get("hardwareProperties",{}); cp=x.get("connectionProperties",{})
    # solo iPads reales (los simuladores aparecen como "sameMachine")
    if hw.get("deviceType")=="iPad" and cp.get("pairingState")=="paired" and cp.get("transportType") in ("wired","localNetwork"):
        print(x["identifier"]); break
' "$JSON")
rm -f "$JSON"
if [[ -z "$DEVICE" ]]; then log "iPad no disponible (¿misma wifi y desbloqueado?)."; exit 1; fi

xcodegen generate --quiet
xcodebuild -project MDobe.xcodeproj -scheme MDobeiPad -configuration Release -destination generic/platform=iOS \
  -derivedDataPath build/ios-signed -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -quiet build
xcrun devicectl device install app --device "$DEVICE" build/ios-signed/Build/Products/Release-iphoneos/MDobe.app >/dev/null
date +%s > "$STAMP"
log "MDobe instalado en el iPad (válido 7 días; se renueva solo)."
# Ejecutado desde el repo: actualiza la copia que usa la tarea automática con este código
[[ -x scripts/install-ipad-agent.sh && "$PWD" != "$HOME/Library/Application Support/MDobe/ipad-src" ]] && ./scripts/install-ipad-agent.sh --sync-only
exit 0
