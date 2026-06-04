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
$ICON        = "Kiwi Logo borda reduzida.ico"
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

# Copiar icone para nome sem espacos (NSIS nao suporta espacos no path do icone)
Copy-Item -Force $ICON $ICON_COPY

# --- Compilar com Pynsist ------------------------------------------------
Write-Host "`n[1/2] Gerando instalador com Pynsist + NSIS..." -ForegroundColor Cyan
& $PYTHON_EXE -m nsist $CONFIG_FILE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pynsist falhou (exit code $LASTEXITCODE). Abortando."
    exit 1
}

Write-Host "`nInstalador gerado em: $INSTALLER" -ForegroundColor Green
Write-Host "`nBuild concluido!" -ForegroundColor Green
