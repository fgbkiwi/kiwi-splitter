# ============================================================
# Build script: Kiwi-Splitter (Pynsist + NSIS) com version bump
# e publicacao da Release no GitHub.
#
# Prerequisitos:
#   uv / venv .venv
#   uv pip install pynsist
#   NSIS instalado (https://nsis.sourceforge.io)
#   GitHub CLI (gh) autenticado — so necessario se for publicar
#
# Uso:
#   .\build_kiwi_splitter_pynsist.ps1                 # patch + publica Release
#   .\build_kiwi_splitter_pynsist.ps1 minor           # minor + publica Release
#   .\build_kiwi_splitter_pynsist.ps1 major           # major + publica Release
#   .\build_kiwi_splitter_pynsist.ps1 -NoPublish      # so gera o .exe (sem Release)
#   .\build_kiwi_splitter_pynsist.ps1 minor -NoPublish
# ============================================================

param(
    [ValidateSet("patch", "minor", "major")]
    [string]$Bump = "patch",

    # Escape hatch: builds de teste sem criar Release no GitHub
    [switch]$NoPublish
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$APP_NAME     = "Kiwi-Splitter"
$ICON_SOURCE  = "KiwiSplitterSquared.png"
$ICON_COPY    = "kiwi-splitter.ico"
$CONFIG_FILE  = "kiwi_splitter_pynsist.cfg"
$BUMP_SCRIPT  = "bump_version.py"
$PYTHON_EXE   = ".venv\Scripts\python.exe"
$GITHUB_REPO  = "fgbkiwi/kiwi-splitter"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Building Kiwi-Splitter Windows Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-Path $PYTHON_EXE)) {
    Write-Error "Python do venv nao encontrado em '$PYTHON_EXE'."
    exit 1
}

if (-not (Test-Path $BUMP_SCRIPT)) {
    Write-Error "Script de bump nao encontrado: '$BUMP_SCRIPT'."
    exit 1
}

if (-not (Test-Path $ICON_SOURCE)) {
    Write-Error "Imagem de icone nao encontrada: '$ICON_SOURCE'."
    exit 1
}

if (-not $NoPublish) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI (gh) nao encontrado. Instale-o ou use -NoPublish para gerar so o instalador."
        exit 1
    }
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GitHub CLI nao autenticado. Rode 'gh auth login' ou use -NoPublish."
        exit 1
    }
}

# --- Bump de versao (fonte unica: APP_VERSION em kiwi_splitter.py) --------
Write-Host "`n[0/4] Incrementando versao ($Bump)..." -ForegroundColor Cyan
$bumpOutput = & $PYTHON_EXE $BUMP_SCRIPT $Bump 2>&1
$bumpExit = $LASTEXITCODE
$bumpOutput | ForEach-Object { Write-Host $_ }
if ($bumpExit -ne 0) {
    Write-Error "Falha ao incrementar a versao (exit code $bumpExit)."
    exit 1
}
$VERSION = ($bumpOutput | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Select-Object -Last 1)
if (-not $VERSION) {
    Write-Error "bump_version.py nao retornou a nova versao em stdout."
    exit 1
}
$VERSION = $VERSION.ToString().Trim()
Write-Host "Nova versao: $VERSION" -ForegroundColor Green

$INSTALLER = Join-Path $ScriptDir "build\nsis\${APP_NAME}_${VERSION}.exe"
$TAG = "v$VERSION"

# --- Garantir pynsist instalado -----------------------------------------
Write-Host "`n[1/4] Instalando pynsist..." -ForegroundColor Cyan
uv pip install --quiet pynsist --python $PYTHON_EXE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao instalar pynsist."
    exit 1
}
Write-Host "  pynsist OK" -ForegroundColor Gray

# Gerar icone a partir do PNG base para usar no app e no instalador
Add-Type -AssemblyName System.Drawing
$sourceImage = [System.Drawing.Image]::FromFile((Join-Path $ScriptDir $ICON_SOURCE))
try {
    $iconSize = 256
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $iconSize, $iconSize
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

            $scale = [Math]::Min($iconSize / $sourceImage.Width, $iconSize / $sourceImage.Height)
            $drawWidth = [int][Math]::Round($sourceImage.Width * $scale)
            $drawHeight = [int][Math]::Round($sourceImage.Height * $scale)
            $offsetX = [int][Math]::Round(($iconSize - $drawWidth) / 2)
            $offsetY = [int][Math]::Round(($iconSize - $drawHeight) / 2)
            $graphics.DrawImage($sourceImage, $offsetX, $offsetY, $drawWidth, $drawHeight)
        } finally {
            $graphics.Dispose()
        }

        $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        try {
            $stream = [System.IO.File]::Open((Join-Path $ScriptDir $ICON_COPY), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            try {
                $icon.Save($stream)
            } finally {
                $stream.Dispose()
            }
        } finally {
            $icon.Dispose()
        }
    } finally {
        $bitmap.Dispose()
    }
} finally {
    $sourceImage.Dispose()
}

# Limpar saida anterior para validar que o .exe atual veio deste build
if (Test-Path "build\nsis") {
    Remove-Item -Recurse -Force "build\nsis"
}

# --- Compilar com Pynsist ------------------------------------------------
Write-Host "`n[2/4] Gerando instalador com Pynsist + NSIS..." -ForegroundColor Cyan
& $PYTHON_EXE -m nsist $CONFIG_FILE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pynsist falhou (exit code $LASTEXITCODE). Abortando."
    exit 1
}

# pynsist pode retornar 0 mesmo se makensis falhar; confirmar o .exe
Write-Host "`n[3/4] Verificando saida do instalador..." -ForegroundColor Cyan
$produced = Get-ChildItem -Path "build\nsis" -Filter "*.exe" -ErrorAction SilentlyContinue
if (-not $produced) {
    Write-Error "Nenhum instalador .exe foi gerado em build\nsis. makensis provavelmente falhou."
    exit 1
}
if (-not (Test-Path $INSTALLER)) {
    Write-Error "Instalador esperado nao encontrado: $INSTALLER"
    exit 1
}

if (Test-Path (Join-Path $ScriptDir $ICON_SOURCE)) {
    Copy-Item -Force (Join-Path $ScriptDir $ICON_SOURCE) (Join-Path $ScriptDir 'build\nsis\KiwiSplitterSquared.png')
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " INSTALLER BUILD SUCCESSFUL!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Versao:     $VERSION"
Write-Host "Instalador: $INSTALLER"

# --- Publicar Release no GitHub ------------------------------------------
if ($NoPublish) {
    Write-Host "`nPublicacao no GitHub omitida (-NoPublish)." -ForegroundColor Yellow
    Write-Host "Para publicar depois:" -ForegroundColor Gray
    Write-Host "  gh release create $TAG `"$INSTALLER`" --repo $GITHUB_REPO --title `"$APP_NAME $VERSION`" --latest" -ForegroundColor Gray
} else {
    Write-Host "`n[4/4] Publicando Release $TAG no GitHub..." -ForegroundColor Cyan

    $existing = gh release view $TAG --repo $GITHUB_REPO 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Error "A Release $TAG ja existe em $GITHUB_REPO. Abortando publicacao (o instalador local permanece em $INSTALLER)."
        exit 1
    }

    $notes = @"
Instalador Windows do $APP_NAME $VERSION.

Baixe o arquivo .exe e execute o assistente de instalacao.

O aplicativo verifica atualizacoes automaticamente (no maximo 1x por dia) nesta pagina de Releases.
"@

    gh release create $TAG $INSTALLER `
        --repo $GITHUB_REPO `
        --title "$APP_NAME $VERSION" `
        --notes $notes `
        --latest

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Falha ao criar a Release $TAG. O instalador local esta em: $INSTALLER"
        exit 1
    }

    $releaseUrl = "https://github.com/$GITHUB_REPO/releases/tag/$TAG"
    Write-Host "Release publicada: $releaseUrl" -ForegroundColor Green
    Write-Host "Lembre-se de fazer commit/push do bump de versao ($VERSION) se ainda nao estiver no remoto." -ForegroundColor Yellow
}

Write-Host "`nBuild concluido!" -ForegroundColor Green
