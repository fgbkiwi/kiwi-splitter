# ============================================================
# Build script: Kiwi-Splitter (Pynsist + NSIS)
# Prerequisitos:
#   uv pip install pynsist
#   NSIS instalado (https://nsis.sourceforge.io)
# ============================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$APP_NAME    = "Kiwi-Splitter"
$ICON_SOURCE = "KiwiSplitterSquared.png"
$ICON_COPY   = "kiwi-splitter.ico"
$CONFIG_FILE  = "kiwi_splitter_pynsist.cfg"
$PYPROJECT    = "pyproject.toml"
$PYTHON_EXE   = ".venv\Scripts\python.exe"

# Fonte unica da versao do app (PEP 621)
$VERSION = (Select-String -Path $PYPROJECT -Pattern '^version\s*=\s*"(.+)"' | Select-Object -First 1).Matches.Groups[1].Value.Trim()
if (-not $VERSION) {
    Write-Error "Nao foi possivel ler version em '$PYPROJECT'."
    exit 1
}

# Sincronizar versao do app (secao [Application] apenas) no .cfg do Pynsist
$cfgLines = Get-Content $CONFIG_FILE
$inApplication = $false
$versionLineFound = $false
$cfgLines = $cfgLines | ForEach-Object {
    if ($_ -eq '[Application]') { $inApplication = $true; return $_ }
    if ($_ -eq '[Python]') { $inApplication = $false }
    if ($inApplication -and $_ -match '^version=') {
        $versionLineFound = $true
        return "version=$VERSION"
    }
    $_
}
if (-not $versionLineFound) {
    Write-Error "Linha version= nao encontrada na secao [Application] de '$CONFIG_FILE'."
    exit 1
}
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines((Join-Path $ScriptDir $CONFIG_FILE), $cfgLines, $utf8NoBom)

$INSTALLER = "build\nsis\${APP_NAME}_${VERSION}.exe"
Write-Host "Versao do build: $VERSION (pyproject.toml)" -ForegroundColor Gray

if (-not (Test-Path $PYTHON_EXE)) {
    Write-Error "Python do venv nao encontrado em '$PYTHON_EXE'."
    exit 1
}

# --- Garantir pynsist instalado -----------------------------------------
Write-Host "`n[0/2] Instalando pynsist..." -ForegroundColor Cyan
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

# --- Compilar com Pynsist ------------------------------------------------
Write-Host "`n[1/2] Gerando instalador com Pynsist + NSIS..." -ForegroundColor Cyan
& $PYTHON_EXE -m nsist $CONFIG_FILE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pynsist falhou (exit code $LASTEXITCODE). Abortando."
    exit 1
}

Copy-Item -Force (Join-Path $ScriptDir $ICON_SOURCE) (Join-Path $ScriptDir 'build\nsis\KiwiSplitterSquared.png')

Write-Host "`nInstalador gerado em: $INSTALLER" -ForegroundColor Green
Write-Host "`nBuild concluido!" -ForegroundColor Green
