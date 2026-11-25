#!/bin/zsh
# Compila MDobe para iPad firmado con el Apple ID gratuito de Xcode y lo instala en el iPad (cable o wifi).
# Con --if-due solo actúa si al perfil de firma instalado le quedan menos de 2 días (lo usa la tarea automática,
# que corre desde la copia de ~/Library/Application Support/MDobe/ipad-src: ver install-ipad-agent.sh).
set -e
cd "$(dirname "$0")/.."
STAMP="$HOME/Library/Application Support/MDobe/ipad-last-install"
mkdir -p "$(dirname "$STAMP")"
log() { echo "$(date '+%F %T') $*"; }

APP=build/ios-signed/Build/Products/Release-iphoneos/MDobe.app
BUNDLE=com.mateobenaa1.mdobe.ipad
MARGIN=$((2 * 86400))
# Caducidad (epoch) de un perfil de aprovisionamiento; 0 si no se puede leer
expiry() {
  local d=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)
  [[ -n "$d" ]] && date -juf '%Y-%m-%dT%H:%M:%SZ' "$d" +%s || echo 0
}

# Lo que caduca es el perfil (7 días desde que Xcode lo crea), no la instalación: reinstalar con el mismo perfil
# no alarga nada. Por eso se mira la fecha del perfil que lleva la app instalada.
if [[ "$1" == "--if-due" && -f "$APP/embedded.mobileprovision" ]] && (( $(expiry "$APP/embedded.mobileprovision") - $(date +%s) > MARGIN )); then
  exit 0
fi

# A partir de aquí toca renovar: si algo falla, aviso en el Mac (como mucho uno cada 12 h para no repetirlo
# en cada intento de la tarea automática, salvo que cambie el motivo)
REASON="la compilación o la instalación ha fallado"
NOTIFIED="$HOME/Library/Application Support/MDobe/ipad-last-alert"
notify_failure() {
  local until="" last_reason="" last_time=0
  [[ -f "$APP/embedded.mobileprovision" ]] && until=" La app actual caduca el $(date -r $(expiry "$APP/embedded.mobileprovision") '+%d/%m %H:%M')."
  [[ -f "$NOTIFIED" ]] && { last_time=$(head -1 "$NOTIFIED"); last_reason=$(tail -1 "$NOTIFIED"); }
  [[ "$last_reason" == "$REASON" ]] && (( $(date +%s) - last_time < 12 * 3600 )) && return
  printf '%s\n%s\n' "$(date +%s)" "$REASON" > "$NOTIFIED"
  local msg="No se ha podido renovar: $REASON.$until"
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"MDobe iPad\" sound name \"Basso\"" >/dev/null 2>&1 || true
}
trap 'rc=$?; (( rc != 0 )) && { log "Fallo: $REASON"; notify_failure; }' EXIT

# Equipo personal de Xcode (se crea al añadir el Apple ID en Xcode → Ajustes → Cuentas)
TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -m1 -oE 'teamID = [A-Z0-9]{10}' | awk '{print $3}')
[[ -z "$TEAM" ]] && TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -m1 -oE 'teamID = [A-Z0-9]{10}' | awk '{print $3}')
if [[ -z "$TEAM" ]]; then REASON="no encuentro tu Apple ID en Xcode (Ajustes → Cuentas)"; exit 1; fi

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
if [[ -z "$DEVICE" ]]; then REASON="el iPad no está disponible (¿misma wifi y desbloqueado?)"; exit 1; fi

# Borra el perfil guardado de MDobe si está a punto de caducar, para que Xcode pida uno nuevo de 7 días
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision(N); do
  security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null | grep -q "\.$BUNDLE\$" || continue
  (( $(expiry "$f") - $(date +%s) <= MARGIN )) && rm -f "$f"
done

xcodegen generate --quiet
BUILDLOG=$(mktemp)
REASON="la compilación ha fallado (mira ~/Library/Logs/MDobe-ipad.log)"
if ! xcodebuild -project MDobe.xcodeproj -scheme MDobeiPad -configuration Release -destination generic/platform=iOS \
  -derivedDataPath build/ios-signed -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -quiet build >"$BUILDLOG" 2>&1; then
  cat "$BUILDLOG"
  grep -q "No Accounts" "$BUILDLOG" && REASON="Xcode ha cerrado la sesión de tu Apple ID; vuelve a iniciarla en Xcode → Ajustes → Cuentas"
  rm -f "$BUILDLOG"; exit 1
fi
cat "$BUILDLOG"; rm -f "$BUILDLOG"
REASON="no se ha podido instalar en el iPad"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
date +%s > "$STAMP"
rm -f "$NOTIFIED"
log "MDobe instalado en el iPad (válido hasta el $(date -r $(expiry "$APP/embedded.mobileprovision") '+%d/%m %H:%M'); se renueva solo)."
# Ejecutado desde el repo: actualiza la copia que usa la tarea automática con este código
[[ -x scripts/install-ipad-agent.sh && "$PWD" != "$HOME/Library/Application Support/MDobe/ipad-src" ]] && ./scripts/install-ipad-agent.sh --sync-only
exit 0
