#!/usr/bin/env bash
# ============================================================
# Build script: Kiwi-Splitter (pacote .deb) com version bump
# e publicacao da Release no GitHub.
#
# Gera um instalador Debian para Pop!_OS e Ubuntu, no mesmo
# papel do build_kiwi_splitter_pynsist.ps1 no Windows. O .deb
# leva um CPython proprio (via uv) e as dependencias, porque
# o Python do sistema no Pop!_OS 24.04 / Ubuntu 24.04 e 3.12
# e o projeto exige 3.14.
#
# O pacote acompanha a arquitetura da maquina que o gera
# (amd64 ou arm64) e as wheels manylinux_2_35, para rodar em
# Pop!_OS / Ubuntu 22.04 ou mais novo. Se essa pinagem nao
# existir, o script cai para a glibc deste sistema e avisa.
#
# Prerequisitos:
#   uv                          (https://docs.astral.sh/uv/)
#   dpkg-deb                    (pacote dpkg, ja presente)
#   GitHub CLI (gh) autenticado — so necessario se for publicar
#
# Uso:
#   ./build_kiwi_splitter_deb.sh                  # patch + publica Release
#   ./build_kiwi_splitter_deb.sh minor            # minor + publica Release
#   ./build_kiwi_splitter_deb.sh major            # major + publica Release
#   ./build_kiwi_splitter_deb.sh --no-publish     # so gera o .deb
#   ./build_kiwi_splitter_deb.sh minor --no-publish
#   ./build_kiwi_splitter_deb.sh --no-bump        # empacota a versao atual
#                                                  # (util depois do build Windows)
# ============================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

APP_NAME="Kiwi-Splitter"
PKG_NAME="kiwi-splitter"
ICON_FILE="kiwi-splitter.ico"
LOGO_PNG="KiwiSplitterSquared.png"
SPLASH_GIF="kiwi_splitter_splash.gif"
BUMP_SCRIPT="bump_version.py"
SOURCE_FILE="kiwi_splitter.py"
PACKAGING_DIR="$SCRIPT_DIR/packaging/linux"
GITHUB_REPO="fgbkiwi/kiwi-splitter"
WORKDIR="$SCRIPT_DIR/build/linux"

if [ -t 1 ]; then
    CYAN=$'\033[36m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    GRAY=$'\033[90m'
    RESET=$'\033[0m'
else
    CYAN=""
    GREEN=""
    YELLOW=""
    GRAY=""
    RESET=""
fi

die() {
    echo "${YELLOW}ERRO:${RESET} $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Uso: $0 [patch|minor|major] [--no-publish] [--no-bump]

  patch|minor|major   componente do bump (padrao: patch)
  --no-publish        so gera o .deb, sem Release no GitHub
  --no-bump           usa APP_VERSION atual, sem alterar os fontes
EOF
}

BUMP="patch"
PUBLISH=1
DO_BUMP=1

for arg in "$@"; do
    case "$arg" in
        patch|minor|major) BUMP="$arg" ;;
        --no-publish|-NoPublish) PUBLISH=0 ;;
        --no-bump|-NoBump) DO_BUMP=0 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Argumento desconhecido: $arg" >&2
            usage
            exit 2
            ;;
    esac
done

echo "${CYAN}========================================${RESET}"
echo "${CYAN} Building Kiwi-Splitter Debian package${RESET}"
echo "${CYAN}========================================${RESET}"

command -v uv >/dev/null 2>&1 || die "uv nao encontrado. Instale em https://docs.astral.sh/uv/"
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb nao encontrado."
command -v dpkg >/dev/null 2>&1 || die "dpkg nao encontrado."

[ -f "$BUMP_SCRIPT" ] || die "Script de bump nao encontrado: '$BUMP_SCRIPT'."
[ -f "$ICON_FILE" ] || die "Icone do aplicativo nao encontrado: '$ICON_FILE'."
[ -f "$LOGO_PNG" ] || die "Logo PNG nao encontrado: '$LOGO_PNG'."
[ -f "$SPLASH_GIF" ] || die "Splash GIF nao encontrado: '$SPLASH_GIF'."
[ -f "$PACKAGING_DIR/kiwi-splitter.sh" ] || die "Launcher nao encontrado em packaging/linux/."

if [ "$PUBLISH" -eq 1 ]; then
    command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) nao encontrado. Instale-o ou use --no-publish."
    gh auth status >/dev/null 2>&1 || die "GitHub CLI nao autenticado. Rode 'gh auth login' ou use --no-publish."
fi

PY_VER=$(tr -d '[:space:]' < "$SCRIPT_DIR/.python-version")
[ -n "$PY_VER" ] || die "Nao foi possivel ler .python-version."

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) WHEEL_PLATFORM="x86_64-manylinux_2_35" ;;
    arm64) WHEEL_PLATFORM="aarch64-manylinux_2_35" ;;
    *) WHEEL_PLATFORM="" ;;
esac

echo "${GRAY}  Python alvo: $PY_VER${RESET}"
echo "${GRAY}  Arquitetura: $ARCH${RESET}"

# --- Interpretador empacotado (python-build-standalone via uv) -----------
echo ""
echo "${CYAN}[0/5] Preparando CPython $PY_VER...${RESET}"
if ! uv python find "$PY_VER" >/dev/null 2>&1; then
    uv python install "$PY_VER"
fi
PY_BIN=$(readlink -f "$(uv python find "$PY_VER")")
PY_PREFIX=$(dirname "$(dirname "$PY_BIN")")
[ -x "$PY_BIN" ] || die "Interpretador nao encontrado em '$PY_BIN'."
[ -d "$PY_PREFIX/lib" ] || die "Prefixo do CPython incompleto: '$PY_PREFIX'."

# --- Bump de versao (fonte unica: APP_VERSION em kiwi_splitter.py) --------
if [ "$DO_BUMP" -eq 1 ]; then
    echo ""
    echo "${CYAN}[1/5] Incrementando versao ($BUMP)...${RESET}"
    bump_output=$("$PY_BIN" "$BUMP_SCRIPT" "$BUMP")
    VERSION=$(printf '%s\n' "$bump_output" | tail -n 1 | tr -d '[:space:]')
else
    echo ""
    echo "${CYAN}[1/5] Lendo versao atual (--no-bump)...${RESET}"
    VERSION=$(sed -n 's/^APP_VERSION = ["'\'']\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)["'\''].*/\1/p' "$SOURCE_FILE" | head -n 1)
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Versao invalida obtida do projeto: '${VERSION:-}'."
fi
echo "${GREEN}Versao: $VERSION${RESET}"

TAG="v$VERSION"
DEB_NAME="${APP_NAME}_${VERSION}_${ARCH}.deb"
DEB_OUT="$SCRIPT_DIR/build/deb/$DEB_NAME"

# --- Copiar o interpretador e instalar dependencias ----------------------
echo ""
echo "${CYAN}[2/5] Montando runtime em $WORKDIR...${RESET}"
rm -rf "$WORKDIR"
BUNDLE="$WORKDIR/bundle"
mkdir -p "$BUNDLE"
cp -a "$PY_PREFIX" "$BUNDLE/python"

LOCKFILE="$WORKDIR/requirements.lock.txt"
uv export --frozen --no-dev --no-emit-project -o "$LOCKFILE" >/dev/null

install_deps() {
    local platform_args=()
    if [ -n "${1:-}" ]; then
        platform_args=(--python-platform "$1")
    fi
    uv pip install --quiet \
        --python "$BUNDLE/python/bin/python3" \
        --break-system-packages \
        --only-binary :all: \
        "${platform_args[@]}" \
        -r "$LOCKFILE"
}

if [ -n "$WHEEL_PLATFORM" ]; then
    echo "${GRAY}  Tentando wheels $WHEEL_PLATFORM (Ubuntu/Pop!_OS 22.04+)${RESET}"
    if ! install_deps "$WHEEL_PLATFORM"; then
        echo "${YELLOW}  Sem conjunto completo de wheels $WHEEL_PLATFORM. Usando a glibc deste sistema; o .deb pode nao abrir em Ubuntu/Pop mais antigos.${RESET}"
        install_deps ""
    fi
else
    install_deps ""
fi
echo "${GRAY}  Dependencias instaladas${RESET}"

install -m 0644 "$SOURCE_FILE" "$BUNDLE/kiwi_splitter.py"
install -m 0644 "$LOGO_PNG" "$BUNDLE/KiwiSplitterSquared.png"
install -m 0644 "$SPLASH_GIF" "$BUNDLE/kiwi_splitter_splash.gif"
install -m 0644 "$ICON_FILE" "$BUNDLE/kiwi-splitter.ico"

# --- Arvore do pacote ----------------------------------------------------
echo ""
echo "${CYAN}[3/5] Montando arvore do pacote .deb...${RESET}"
ROOT="$WORKDIR/root"
mkdir -p \
    "$ROOT/DEBIAN" \
    "$ROOT/opt" \
    "$ROOT/usr/bin" \
    "$ROOT/usr/share/applications" \
    "$ROOT/usr/share/doc/$PKG_NAME"

mv "$BUNDLE" "$ROOT/opt/$PKG_NAME"

echo "${GRAY}  Conferindo import no prefixo final...${RESET}"
(
    cd /tmp
    QT_QPA_PLATFORM=offscreen "$ROOT/opt/$PKG_NAME/python/bin/python3" -c \
        "import sys; sys.path.insert(0, '$ROOT/opt/$PKG_NAME'); import kiwi_splitter; print(kiwi_splitter.APP_VERSION)"
) | grep -qx "$VERSION" || die "O runtime empacotado nao importou o Kiwi-Splitter $VERSION."

install -m 0755 "$PACKAGING_DIR/kiwi-splitter.sh" "$ROOT/usr/bin/$PKG_NAME"
install -m 0644 "$PACKAGING_DIR/kiwi-splitter.desktop" "$ROOT/usr/share/applications/$PKG_NAME.desktop"
install -m 0755 "$PACKAGING_DIR/postinst" "$ROOT/DEBIAN/postinst"
install -m 0755 "$PACKAGING_DIR/postrm" "$ROOT/DEBIAN/postrm"

ICON_TMP="$WORKDIR/icons"
if QT_QPA_PLATFORM=offscreen "$ROOT/opt/$PKG_NAME/python/bin/python3" \
    "$PACKAGING_DIR/export_icons.py" "$ICON_FILE" "$ICON_TMP"
then
    for size in 16 24 32 48 64 128 256; do
        dest_dir="$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$dest_dir"
        install -m 0644 "$ICON_TMP/${size}.png" "$dest_dir/$PKG_NAME.png"
    done
    echo "${GRAY}  Icones hicolor gerados a partir de $ICON_FILE${RESET}"
else
    dest_dir="$ROOT/usr/share/icons/hicolor/256x256/apps"
    mkdir -p "$dest_dir"
    install -m 0644 "$LOGO_PNG" "$dest_dir/$PKG_NAME.png"
    echo "${YELLOW}  Exportacao do .ico falhou; usando $LOGO_PNG como icone do menu.${RESET}"
fi

cat > "$ROOT/usr/share/doc/$PKG_NAME/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $APP_NAME
Source: https://github.com/$GITHUB_REPO

Files: *
Copyright: fgbkiwi
License: LicenseRef-proprietary
 Distribuido pelo autor via GitHub Releases.
EOF

INSTALLED_KB=$(du -sk "$ROOT/opt" "$ROOT/usr" | awk '{s += $1} END {print s}')

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: fgbkiwi <fgbkiwi@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Depends: libc6, libstdc++6, libgcc-s1, zlib1g, ca-certificates, libglib2.0-0t64 | libglib2.0-0, libgl1, libegl1, libfontconfig1, libfreetype6, libxkbcommon0, libdbus-1-3, libxcb1, libxcb-cursor0, libxcb-xinerama0, libx11-6, libxext6, libxi6, libsm6, libice6, libwayland-client0, libwayland-cursor0, libwayland-egl1
Recommends: xdg-utils
Homepage: https://github.com/$GITHUB_REPO
Description: Fracionador e sanitizador de PDF (PJe) para LLMs
 Kiwi-Splitter particiona e sanitiza PDFs grandes do PJe-JT
 para envio a modelos de linguagem, com estimativa de tokens.
EOF

chmod -R u+rwX,go+rX "$ROOT"
chmod 0755 "$ROOT/usr/bin/$PKG_NAME" "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"
chmod 0755 "$ROOT/opt/$PKG_NAME/python/bin/python3" "$ROOT/opt/$PKG_NAME/python/bin/python3."* 2>/dev/null || true

# --- Empacotar -----------------------------------------------------------
echo ""
echo "${CYAN}[4/5] Gerando $DEB_NAME...${RESET}"
mkdir -p "$(dirname "$DEB_OUT")"
rm -f "$DEB_OUT"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB_OUT"

[ -f "$DEB_OUT" ] || die "Nenhum pacote .deb foi gerado em build/deb."
dpkg-deb --info "$DEB_OUT" >/dev/null || die "O pacote gerado nao passou na leitura do dpkg-deb."

echo ""
echo "${GREEN}========================================${RESET}"
echo "${GREEN} DEB BUILD SUCCESSFUL!${RESET}"
echo "${GREEN}========================================${RESET}"
echo "Versao:  $VERSION"
echo "Pacote:  $DEB_OUT"
echo "${GRAY}$(dpkg-deb --show "$DEB_OUT")${RESET}"

# --- Publicar Release no GitHub ------------------------------------------
if [ "$PUBLISH" -eq 0 ]; then
    echo ""
    echo "${YELLOW}Publicacao no GitHub omitida (--no-publish).${RESET}"
    echo "${GRAY}Para publicar depois:${RESET}"
    echo "${GRAY}  gh release create $TAG \"$DEB_OUT\" --repo $GITHUB_REPO --title \"$APP_NAME $VERSION\" --latest${RESET}"
else
    echo ""
    echo "${CYAN}[5/5] Publicando Release $TAG no GitHub...${RESET}"

    NOTES=$(cat <<EOF
Pacote Debian do $APP_NAME $VERSION para Pop!_OS e Ubuntu.

Baixe o arquivo .deb e abra-o (Eddy no Pop!_OS, ou o instalador de software no Ubuntu). No terminal:

    sudo apt install ./$DEB_NAME

O aplicativo verifica atualizacoes automaticamente (no maximo 1x por dia) nesta pagina de Releases.
EOF
)

    if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "${GRAY}  A Release $TAG ja existe. Anexando o .deb como asset.${RESET}"
        gh release upload "$TAG" "$DEB_OUT" --repo "$GITHUB_REPO" --clobber
    else
        gh release create "$TAG" "$DEB_OUT" \
            --repo "$GITHUB_REPO" \
            --title "$APP_NAME $VERSION" \
            --notes "$NOTES" \
            --latest
    fi

    release_url="https://github.com/$GITHUB_REPO/releases/tag/$TAG"
    echo "${GREEN}Release publicada: $release_url${RESET}"
    if [ "$DO_BUMP" -eq 1 ]; then
        echo "${YELLOW}Lembre-se de fazer commit/push do bump de versao ($VERSION) se ainda nao estiver no remoto.${RESET}"
    fi
fi

echo ""
echo "${GREEN}Build concluido!${RESET}"
