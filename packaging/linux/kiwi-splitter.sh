#!/bin/sh
# Launcher do pacote Debian. O Python e as dependências ficam em /opt/kiwi-splitter.
set -eu

APPDIR="/opt/kiwi-splitter"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DATA="$DATA_HOME/Kiwi-Splitter"
mkdir -p "$APP_DATA"

# O aplicativo grava cache e o JSON de seleções no diretório de trabalho,
# no mesmo espírito do launcher Windows (LOCALAPPDATA\Kiwi-Splitter).
export LOCALAPPDATA="$DATA_HOME"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1

if [ -z "${SSL_CERT_FILE:-}" ] && [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
fi
if [ -z "${SSL_CERT_DIR:-}" ] && [ -d /etc/ssl/certs ]; then
    export SSL_CERT_DIR=/etc/ssl/certs
fi

PLUGIN_PATH=""
for site in "$APPDIR"/python/lib/python*/site-packages; do
    if [ -d "$site/PyQt6/Qt6/plugins" ]; then
        PLUGIN_PATH="$site/PyQt6/Qt6/plugins"
        break
    fi
done
if [ -n "$PLUGIN_PATH" ]; then
    export QT_PLUGIN_PATH="$PLUGIN_PATH"
    if [ -d "$PLUGIN_PATH/platforms" ]; then
        export QT_QPA_PLATFORM_PLUGIN_PATH="$PLUGIN_PATH/platforms"
    fi
fi

cd "$APP_DATA"
exec "$APPDIR/python/bin/python3" "$APPDIR/kiwi_splitter.py" "$@"
