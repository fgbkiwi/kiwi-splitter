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
#   .\build_kiwi_splitter_pynsist.ps1                 # patch + commit/tag/push + Release
#   .\build_kiwi_splitter_pynsist.ps1 minor           # minor + commit/tag/push + Release
#   .\build_kiwi_splitter_pynsist.ps1 major           # major + commit/tag/push + Release
#   .\build_kiwi_splitter_pynsist.ps1 -NoPublish      # so gera o .exe (sem git/Release)
#   .\build_kiwi_splitter_pynsist.ps1 -NoBump         # versao atual + tag/push + Release
#   .\build_kiwi_splitter_pynsist.ps1 -NoBump -NoPublish
#   .\build_kiwi_splitter_pynsist.ps1 ... -AllowDirty # permite working tree sujo
#
# Ao publicar, o script exige working tree limpo e em dia com o remoto,
# faz commit do bump (kiwi_splitter.py, .cfg, pyproject.toml), cria a
# tag vX.Y.Z, faz push de branch + tag e cria a Release (ou anexa o .exe
# se a Release da mesma versao ja existir — p.ex. criada pelo build Linux).
# Para anexar o .exe a uma versao ja publicada: -NoBump (a partir do commit da tag).
# ============================================================

param(
    [ValidateSet("patch", "minor", "major")]
    [string]$Bump = "patch",

    # Escape hatch: builds de teste sem commit, push ou Release
    [switch]$NoPublish,

    # Reutiliza APP_VERSION atual sem incrementar
    [switch]$NoBump,

    # Permite publicar com alteracoes nao commitadas (o .exe nao correspondera a tag)
    [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$APP_NAME      = "Kiwi-Splitter"
$ICON_FILE     = "kiwi-splitter.ico"
$LOGO_PNG      = "KiwiSplitterSquared.png"
$CONFIG_FILE   = "kiwi_splitter_pynsist.cfg"
$BUMP_SCRIPT   = "bump_version.py"
$PYTHON_EXE    = ".venv\Scripts\python.exe"
$GITHUB_REPO   = "fgbkiwi/kiwi-splitter"
$VERSION_FILES = @("kiwi_splitter.py", "kiwi_splitter_pynsist.cfg", "pyproject.toml")

# Roda git sem que stderr vire erro terminante sob ErrorActionPreference=Stop.
function Invoke-Git {
    $ErrorActionPreference = "Continue"
    $out = & git @args 2>$null
    return $out
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Building Kiwi-Splitter Windows Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-Path $PYTHON_EXE)) {
    Write-Error "Python do venv nao encontrado em '$PYTHON_EXE'."
    exit 1
}

if (-not $NoBump -and -not (Test-Path $BUMP_SCRIPT)) {
    Write-Error "Script de bump nao encontrado: '$BUMP_SCRIPT'."
    exit 1
}

if (-not (Test-Path $ICON_FILE)) {
    Write-Error "Icone do aplicativo nao encontrado: '$ICON_FILE'."
    exit 1
}

if (-not (Test-Path $LOGO_PNG)) {
    Write-Error "Logo PNG nao encontrado: '$LOGO_PNG'."
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

    # --- Git preflight (antes do build, para nao desperdicar um build longo) ---
    Invoke-Git fetch --quiet --tags origin | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git fetch falhou."
        exit 1
    }
    if (-not $AllowDirty) {
        $dirty = Invoke-Git status --porcelain
        if ($dirty) {
            $dirty | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            Write-Host "Se so os arquivos de versao aparecem, um build anterior deixou o bump para tras:" -ForegroundColor Gray
            Write-Host "  git checkout -- $($VERSION_FILES -join ' ')" -ForegroundColor Gray
            Write-Error "Working tree com alteracoes nao commitadas. Faca commit antes, ou use -AllowDirty."
            exit 1
        }
    }
    # HEAD destacado = build a partir de "git checkout vX.Y.Z"
    Invoke-Git symbolic-ref -q HEAD | Out-Null
    $DETACHED = ($LASTEXITCODE -ne 0)
    if ($DETACHED) {
        if (-not $NoBump) {
            Write-Error "Nao da para fazer bump com HEAD destacado; faca checkout de um branch (ou use -NoBump)."
            exit 1
        }
    } else {
        Invoke-Git rev-parse --abbrev-ref --symbolic-full-name '@{u}' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "O branch atual nao tem upstream; faca push antes (git push -u origin HEAD)."
            exit 1
        }
        $behind = Invoke-Git rev-list --count 'HEAD..@{u}'
        if ([int]$behind -ne 0) {
            Write-Error "O branch local esta atras do remoto. Rode 'git pull' antes."
            exit 1
        }
    }
}

# Reverte os arquivos de versao se o script falhar depois do bump e antes do commit.
$script:BumpPending = $false
trap {
    if ($script:BumpPending) {
        Write-Host "Build falhou - revertendo bump em: $($VERSION_FILES -join ', ')" -ForegroundColor Yellow
        Invoke-Git checkout HEAD @VERSION_FILES | Out-Null
    }
    break
}

# --- Versao (fonte unica: APP_VERSION em kiwi_splitter.py) ----------------
if ($NoBump) {
    Write-Host "`n[0/4] Mantendo versao atual (-NoBump)..." -ForegroundColor Cyan
    $mainSource = Get-Content -Raw -Path (Join-Path $ScriptDir "kiwi_splitter.py")
    if ($mainSource -notmatch 'APP_VERSION\s*=\s*["''](\d+\.\d+\.\d+)["'']') {
        Write-Error "Nao foi possivel ler APP_VERSION de kiwi_splitter.py."
        exit 1
    }
    $VERSION = $Matches[1]
    Write-Host "Versao (sem bump): $VERSION" -ForegroundColor Green
} else {
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
    if (-not $NoPublish -and -not $AllowDirty) {
        $script:BumpPending = $true
    }
}

$INSTALLER = Join-Path $ScriptDir "build\nsis\${APP_NAME}_${VERSION}.exe"
$TAG = "v$VERSION"

if (-not $NoPublish) {
    $tagCommit = Invoke-Git rev-list -n 1 $TAG
    if ($LASTEXITCODE -eq 0 -and $tagCommit) {
        if (-not $NoBump) {
            Write-Error "A tag $TAG ja existe; nao da para publicar um bump para uma versao existente."
            exit 1
        }
        $headCommit = Invoke-Git rev-parse HEAD
        if ($tagCommit -ne $headCommit) {
            Write-Error "A tag $TAG existe mas aponta para outro commit que nao o HEAD. Faca 'git checkout $TAG' ou publique uma nova versao (sem -NoBump)."
            exit 1
        }
    }
}

# --- Garantir pynsist instalado -----------------------------------------
Write-Host "`n[1/4] Instalando pynsist..." -ForegroundColor Cyan
uv pip install --quiet pynsist --python $PYTHON_EXE
if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao instalar pynsist."
    exit 1
}
Write-Host "  pynsist OK" -ForegroundColor Gray
Write-Host "  Usando icone: $ICON_FILE" -ForegroundColor Gray

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

if (Test-Path (Join-Path $ScriptDir $LOGO_PNG)) {
    Copy-Item -Force (Join-Path $ScriptDir $LOGO_PNG) (Join-Path $ScriptDir 'build\nsis\KiwiSplitterSquared.png')
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " INSTALLER BUILD SUCCESSFUL!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Versao:     $VERSION"
Write-Host "Instalador: $INSTALLER"

# --- Commit/tag/push e publicacao da Release -----------------------------
if ($NoPublish) {
    Write-Host "`nPublicacao no GitHub omitida (-NoPublish)." -ForegroundColor Yellow
    if (-not $NoBump) {
        Write-Host "O incremento de versao ficou sem commit." -ForegroundColor Gray
        Write-Host "Para desfazer: git checkout -- $($VERSION_FILES -join ' ')" -ForegroundColor Gray
    }
    Write-Host "Para publicar depois:" -ForegroundColor Gray
    Write-Host "  gh release upload $TAG `"$INSTALLER`" --repo $GITHUB_REPO --clobber   # Release ja existe" -ForegroundColor Gray
    Write-Host "  gh release create $TAG `"$INSTALLER`" --repo $GITHUB_REPO --title `"$APP_NAME $VERSION`" --latest" -ForegroundColor Gray
} else {
    Write-Host "`n[4/4] Commit/tag/push e publicacao de $TAG no GitHub..." -ForegroundColor Cyan

    if (-not $NoBump) {
        git add @VERSION_FILES
        if ($LASTEXITCODE -ne 0) { Write-Error "git add falhou."; exit 1 }
        git commit --quiet -m "Release $TAG" @VERSION_FILES
        if ($LASTEXITCODE -ne 0) { Write-Error "git commit falhou."; exit 1 }
        $script:BumpPending = $false
        Write-Host "  Commit do bump criado: $(Invoke-Git rev-parse --short HEAD)" -ForegroundColor Gray
    }
    Invoke-Git rev-parse -q --verify "refs/tags/$TAG" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git tag -a $TAG -m "Release $TAG"
        if ($LASTEXITCODE -ne 0) { Write-Error "git tag falhou."; exit 1 }
        Write-Host "  Tag $TAG criada em $(Invoke-Git rev-parse --short HEAD)" -ForegroundColor Gray
    }
    $pushRefs = @("refs/tags/$TAG")
    if (-not $DETACHED) { $pushRefs = @("HEAD") + $pushRefs }
    $ErrorActionPreference = "Continue"   # git push escreve progresso em stderr
    git push --atomic origin @pushRefs
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($pushExit -ne 0) {
        Write-Error "git push falhou. O instalador local esta em: $INSTALLER"
        exit 1
    }
    if ($AllowDirty -and (Invoke-Git status --porcelain)) {
        Write-Host "Aviso: build feito com -AllowDirty; o .exe inclui alteracoes que nao estao em $TAG." -ForegroundColor Yellow
    }

    $notes = @"
Instalador Windows do $APP_NAME $VERSION.

Baixe o arquivo .exe e execute o assistente de instalacao.

O aplicativo verifica atualizacoes automaticamente (no maximo 1x por dia) nesta pagina de Releases.
"@

    $ErrorActionPreference = "Continue"
    gh release view $TAG --repo $GITHUB_REPO 2>$null | Out-Null
    $releaseExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = "Stop"

    if ($releaseExists) {
        Write-Host "  Release $TAG ja existe - anexando o .exe (sem recriar)." -ForegroundColor Gray
        gh release upload $TAG $INSTALLER --repo $GITHUB_REPO --clobber
    } else {
        gh release create $TAG $INSTALLER `
            --repo $GITHUB_REPO `
            --title "$APP_NAME $VERSION" `
            --notes $notes `
            --verify-tag `
            --latest
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Falha ao publicar na Release $TAG. O instalador local esta em: $INSTALLER"
        exit 1
    }

    $releaseUrl = "https://github.com/$GITHUB_REPO/releases/tag/$TAG"
    Write-Host "Release publicada: $releaseUrl" -ForegroundColor Green
}

Write-Host "`nBuild concluido!" -ForegroundColor Green
