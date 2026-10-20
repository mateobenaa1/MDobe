# MDobe

Visor y editor de PDF nativo para macOS (SwiftUI + PDFKit) con asistente de Apple Intelligence integrado. Gratis y local.

Requisitos: macOS 26+, Apple Silicon, Xcode. Instalar o actualizar:

```sh
./scripts/install.sh
```

iPad (firma gratuita de 7 días): `./scripts/install-ipad.sh` instala; `./scripts/install-ipad-agent.sh` activa la renovación automática (copia lo necesario a `~/Library/Application Support/MDobe/ipad-src`, porque launchd no puede leer el Escritorio).

Cambios de código: la app de Mac solo se actualiza tras volver a ejecutar `./scripts/install.sh`. Los cambios del iPad llegan a la copia que usa la renovación automática al ejecutar `./scripts/install-ipad.sh` o `./scripts/install-ipad-agent.sh`. Historial de cambios en `CHANGELOG.md`.
