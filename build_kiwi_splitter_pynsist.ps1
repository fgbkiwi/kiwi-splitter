# ============================================================
# Build script: Kiwi-Splitter (Pynsist + NSIS) com version bump
# Prerequisitos:
#   uv / venv .venv
#   uv pip install pynsist
#   NSIS instalado (https://nsis.sourceforge.io)
#
# Uso (igual ao Kiwiscribe):
#   .\build_kiwi_splitter_pynsist.ps1            # patch (padrao)
#   .\build_kiwi_splitter_pynsist.ps1 minor
#   .\build_kiwi_splitter_pynsist.ps1 major
# ============================================================

param(
    [ValidateSet("patch", "minor", "major")]
    [string]$Bump = "patch"
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

# --- Bump de versao (fonte unica: APP_VERSION em kiwi_splitter.py) --------
Write-Host "`n[0/3] Incrementando versao ($Bump)..." -ForegroundColor Cyan
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

$INSTALLER = "build\nsis\${APP_NAME}_${VERSION}.exe"

# --- Garantir pynsist instalado -----------------------------------------
Write-Host "`n[1/3] Instalando pynsist..." -ForegroundColor Cyan
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
Write-Host "`n[2/3] Gerando instalador com Pynsist + NSIS..." -ForegroundColor Cyan
& $PYTHON_EXE -m nsist $CONFIG_FILE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pynsist falhou (exit code $LASTEXITCODE). Abortando."
    exit 1
}

# pynsist pode retornar 0 mesmo se makensis falhar; confirmar o .exe
Write-Host "`n[3/3] Verificando saida do instalador..." -ForegroundColor Cyan
$produced = Get-ChildItem -Path "build\nsis" -Filter "*.exe" -ErrorAction SilentlyContinue
if (-not $produced) {
    Write-Error "Nenhum instalador .exe foi gerado em build\nsis. makensis provavelmente falhou."
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
Write-Host ""
Write-Host "Publique em GitHub Releases (nao versionar o .exe no Git):" -ForegroundColor Yellow
Write-Host "  gh release create v$VERSION `"$INSTALLER`" --title `"$APP_NAME $VERSION`" --latest" -ForegroundColor Gray
Write-Host "`nBuild concluido!" -ForegroundColor Green
