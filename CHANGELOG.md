# Changelog

Todos los cambios relevantes de este proyecto se documentan aquí.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).

## [2026-10-20]

### Seguridad
- Chat y bloques (`Resources/Web/chat.html`, `block.html`): el Markdown que llega de la
  IA (o del PDF) se sanea en `render.js` mediante la configuración de `marked`: el HTML
  crudo se escapa salvo etiquetas de formato sin atributos (`br`, `sub`, `sup`, `b`, `i`,
  `em`, `strong`, `u`, `s`, `del`, `ins`, `mark`, `small`, `kbd`, `hr`); los enlaces solo
  se permiten con `http(s):`, `mailto:`, `mdobe:` o `#`, y las imágenes además con
  `data:image/`. Hallazgo de auditoría: inyección de HTML/JS en el WebView.
- Content-Security-Policy estricta en ambas páginas (`script-src file:`, sin red, sin
  `object`, `base-uri` ni formularios). Los scripts en línea se movieron a
  `Resources/Web/chat.js` y `Resources/Web/block.js`.

### Corregido
- Los observadores de `NotificationCenter` con bloque (`Editor`, `PadEditor`, `OpenDoc`)
  guardan su token y se eliminan en `deinit`, evitando observadores huérfanos al cerrar
  documentos.
- Renovación automática del iPad: la tarea de launchd no podía leer el repo en el
  Escritorio (privacidad de macOS). Ahora se ejecuta desde una copia en
  `~/Library/Application Support/MDobe/ipad-src`.

### Añadido
- `scripts/install-ipad-agent.sh`: copia fuentes, recursos, `project.yml` e
  `install-ipad.sh` a la ruta anterior e instala/recarga el LaunchAgent
  (`--sync-only` solo copia).
- `scripts/com.mateobenaa1.mdobe.refresh.plist` pasa a ser una plantilla con `__HOME__`
  que sustituye el script anterior (ya no tiene rutas de usuario fijas).
- `install-ipad.sh`, al ejecutarse desde el repo, sincroniza la copia de la tarea
  automática.

### Notas
- Los cambios de la app de Mac requieren volver a ejecutar `./scripts/install.sh`.
- Los cambios de código del iPad llegan a la copia de renovación automática tras ejecutar
  `./scripts/install-ipad.sh` o `./scripts/install-ipad-agent.sh`.
