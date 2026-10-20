#!/bin/zsh
# Activa la renovación automática de la app del iPad (firma gratuita de 7 días).
# launchd no puede leer el Escritorio (permisos de privacidad de macOS), así que se copia lo necesario para
# compilar (fuentes, recursos, project.yml y el script) a ~/Library/Application Support/MDobe/ipad-src y la
# tarea automática se ejecuta desde ahí. Vuelve a ejecutarlo (o ./scripts/install-ipad.sh) tras cambiar el código.
# Uso: ./scripts/install-ipad-agent.sh            → copia + (re)carga la tarea
#      ./scripts/install-ipad-agent.sh --sync-only → solo copia
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Application Support/MDobe/ipad-src"
mkdir -p "$DEST/scripts"
rsync -a --delete "$REPO/Sources" "$REPO/Resources" "$REPO/project.yml" "$DEST/"
cp "$REPO/scripts/install-ipad.sh" "$DEST/scripts/"
[[ "$1" == "--sync-only" ]] && exit 0

LABEL=com.mateobenaa1.mdobe.refresh
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed "s|__HOME__|$HOME|g" "$REPO/scripts/$LABEL.plist" > "$PLIST"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Renovación automática del iPad activada (se ejecuta desde $DEST)"
