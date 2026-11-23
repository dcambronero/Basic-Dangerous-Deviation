<#
=============================================================================
 dd-lab.ps1 (v5) - Lab del demo Dangerous Deviation (Azure OpenAI + Lakera Guard)
 Windows PowerShell 5.1 / PowerShell 7
-----------------------------------------------------------------------------
 CAMBIOS v5:
   [CAMBIO] 'run' usa automáticamente el dd_demo_v*.py MÁS RECIENTE de la carpeta
            (hoy dd_demo_v4.py). Ya no hay que editar este script al cambiar de versión.
 CAMBIOS v4: los argumentos del demo pasan a Python sin tocarlos (fix --pause / --list).
 CAMBIOS v3: modelo/versión NO deprecada + alternativos, comando 'models', 'up' re-ejecutable.
 CAMBIOS v2: fix "call depth overflow", stderr de az en PS 5.1, UTF-8 para Python.

 Acciones:
   .\dd-lab.ps1 up                      Crea RG + Azure OpenAI + deployment, genera .env
   .\dd-lab.ps1 models                  Lista modelos/versiones desplegables en el recurso
   .\dd-lab.ps1 env [-ShowSecrets]      Muestra las variables (desde .env)
   .\dd-lab.ps1 run <args del demo>     Carga .env y ejecuta el demo
                                        Ej: .\dd-lab.ps1 run --scenario 01 --pause
   .\dd-lab.ps1 status                  Muestra qué existe del lab
   .\dd-lab.ps1 down                    Borra TODO: RG, purge de Azure OpenAI y .env

 Opciones de 'up':  -Location eastus2  -Model gpt-4.1-mini  -Sku GlobalStandard|Standard  -Capacity 10
 NO hay rollback automático: si 'up' falla, vuelve a ejecutar 'up' (reutiliza) o ejecuta 'down'.
=============================================================================
#>
# Solo la acción es parámetro de PowerShell; lo demás se parsea a mano desde $args
param([string]$Action)

$Location = "eastus2"; $Model = "gpt-4.1-mini"; $Sku = "GlobalStandard"; $Capacity = 10
$ShowSecrets = $false
$DemoArgs = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($Action -eq "run") { $DemoArgs += $a; continue }   # en 'run' todo va a Python tal cual
    switch -Regex ($a) {
        '^-Location$'    { $i++; $Location = [string]$args[$i]; continue }
        '^-Model$'       { $i++; $Model    = [string]$args[$i]; continue }
        '^-Sku$'         { $i++; $Sku      = [string]$args[$i]; continue }
        '^-Capacity$'    { $i++; $Capacity = [int]$args[$i]; continue }
        '^-ShowSecrets$' { $ShowSecrets = $true; continue }
        default          { Write-Host "[AVISO] Argumento ignorado: $a" -ForegroundColor Yellow }
    }
}

$ErrorActionPreference = "Stop"

$RG       = "rg-dd-demo"
$Tags     = @("project=dd-demo", "owner=demo", "purpose=dangerous-deviation-demo")
$EnvFile  = Join-Path $PSScriptRoot ".env"
$VarNames = @("AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_DEPLOYMENT",
              "LAKERA_GUARD_API_KEY", "LAKERA_PROJECT_ID")
$FallbackModels = @("gpt-4.1-mini", "gpt-4o-mini", "gpt-4.1", "gpt-4o", "gpt-5-mini")

function Log($m)  { Write-Host "[dd-lab] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[AVISO] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# [NUEVO v5] Script del demo más reciente (dd_demo_v4.py, dd_demo_v5.py, ...)
function Get-DemoPy {
    $f = Get-ChildItem -Path $PSScriptRoot -Filter "dd_demo_v*.py" -ErrorAction SilentlyContinue |
         Sort-Object { [int]($_.BaseName -replace '\D', '') } -Descending | Select-Object -First 1
    if (-not $f) { Die "No encuentro dd_demo_v*.py en $PSScriptRoot. Colócalo junto a este script." }
    return $f.FullName
}

# ----------------------------------------------------------------------------
# Azure CLI (ruta real de az.cmd)
# ----------------------------------------------------------------------------
function Find-AzCli {
    $cmd = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Die "Azure CLI no está instalado: winget install -e --id Microsoft.AzureCLI (luego abre una terminal nueva)" }
    $script:AzExe = $cmd.Source
}

function Invoke-AzCli {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & $script:AzExe @args
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { throw "az $($args -join ' ') falló (código $code)" }
    return $out
}

function Test-AzCli {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $script:AzExe @args 2>$null | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return ($code -eq 0)
}

function Preflight {
    Find-AzCli
    if (-not (Test-AzCli account show -o none)) { Die "No hay sesión de Azure. Ejecuta: az login" }
    $script:SubId   = Invoke-AzCli account show --query id -o tsv
    $script:SubName = Invoke-AzCli account show --query name -o tsv
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:SubId))
    $script:Suffix = (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 6)
    $script:AOAI = "aoai-dd-demo-$($script:Suffix)"
    Log "Suscripción:  $($script:SubName)"
    Log "RG: $RG  |  Azure OpenAI: $($script:AOAI)  |  Región: $Location"
}

# ----------------------------------------------------------------------------
# Modelo/versión desplegable (no deprecada)
# ----------------------------------------------------------------------------
function Get-AvailableModels {
    $json = Invoke-AzCli cognitiveservices account list-models -n $AOAI -g $RG -o json
    return ($json -join "`n") | ConvertFrom-Json
}

function Test-Deployable($m) {
    $now = Get-Date
    if ($m.format -ne "OpenAI") { return $false }
    if ($m.lifecycleStatus -and ($m.lifecycleStatus -match "Deprecat|Retir")) { return $false }
    if ($m.deprecation -and $m.deprecation.inference) {
        try { if ([datetime]$m.deprecation.inference -lt $now.AddDays(30)) { return $false } } catch {}
    }
    $s = $m.skus | Where-Object { $_.name -eq $Sku } | Select-Object -First 1
    if (-not $s) { return $false }
    if ($s.deprecationDate) {
        try { if ([datetime]$s.deprecationDate -lt $now.AddDays(30)) { return $false } } catch {}
    }
    return $true
}

function Select-ModelVersion {
    $all = Get-AvailableModels
    $candidates = @($Model) + ($FallbackModels | Where-Object { $_ -ne $Model })
    foreach ($name in $candidates) {
        $ok = $all | Where-Object { $_.name -eq $name -and (Test-Deployable $_) } |
              Sort-Object { $_.version } -Descending | Select-Object -First 1
        if ($ok) {
            if ($name -ne $Model) { Warn "El modelo $Model no tiene versión desplegable con SKU $Sku en $Location; se usa $name" }
            return @{ Name = $name; Version = $ok.version }
        }
        Log "Sin versión válida para $name (SKU $Sku) en $Location"
    }
    return $null
}

function Show-Models {
    Preflight
    if (-not (Test-AzCli cognitiveservices account show -n $AOAI -g $RG -o none)) {
        Die "El recurso $AOAI no existe todavía. Ejecuta primero: .\dd-lab.ps1 up"
    }
    Get-AvailableModels | Where-Object { $_.format -eq "OpenAI" -and $_.name -match "^gpt" } |
        Select-Object name, version, lifecycleStatus,
            @{n="skus"; e={ ($_.skus.name) -join "," }},
            @{n="desplegable($Sku)"; e={ Test-Deployable $_ }} |
        Sort-Object name, version | Format-Table -AutoSize
}

# ----------------------------------------------------------------------------
# .env
# ----------------------------------------------------------------------------
function Read-EnvFile {
    if (-not (Test-Path $EnvFile)) { Die "No existe $EnvFile. Ejecuta primero: .\dd-lab.ps1 up" }
    $vars = [ordered]@{}
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match "^\s*([A-Z_]+)=(.*)$") { $vars[$Matches[1]] = $Matches[2].Trim() }
    }
    return $vars
}

function Mask($name, $value) {
    if ($ShowSecrets -or $name -notmatch "KEY") { return $value }
    if ($value.Length -le 8) { return "****" }
    return $value.Substring(0, 4) + "****" + $value.Substring($value.Length - 4)
}

function Show-Env {
    $vars = Read-EnvFile
    Write-Host ""
    Write-Host "==================== VARIABLES DE AMBIENTE ====================" -ForegroundColor Magenta
    Write-Host "Guardadas en: $EnvFile" -ForegroundColor DarkGray
    Write-Host "NO necesitas definirlas: '.\dd-lab.ps1 run ...' las carga solo." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "# PowerShell (solo si quieres ejecutar python directamente):" -ForegroundColor DarkGray
    foreach ($k in $vars.Keys) { Write-Host ('$env:{0} = "{1}"' -f $k, (Mask $k $vars[$k])) }
    Write-Host ""
    Write-Host "# Formato .env / Linux:" -ForegroundColor DarkGray
    foreach ($k in $vars.Keys) { Write-Host ("{0}={1}" -f $k, (Mask $k $vars[$k])) }
    if (-not $ShowSecrets) {
        Write-Host ""
        Warn "Keys enmascaradas. Para verlas completas: .\dd-lab.ps1 env -ShowSecrets"
    }
    Write-Host "===============================================================" -ForegroundColor Magenta
}

# ----------------------------------------------------------------------------
# Acciones
# ----------------------------------------------------------------------------
function Up {
    Preflight

    Log "1/5 Resource group..."
    Invoke-AzCli group create -n $RG -l $Location --tags @Tags -o none
    Ok "RG $RG listo"

    Log "2/5 Azure OpenAI..."
    if (Test-AzCli cognitiveservices account show -n $AOAI -g $RG -o none) {
        Ok "Ya existe $AOAI (se reutiliza)"
    } else {
        $deleted = Invoke-AzCli cognitiveservices account list-deleted --query "[?name=='$AOAI'].location | [0]" -o tsv
        if ($deleted) {
            Warn "$AOAI estaba en soft-delete; purgando antes de recrear..."
            Invoke-AzCli cognitiveservices account purge -n $AOAI -g $RG -l $deleted -o none
        }
        Invoke-AzCli cognitiveservices account create -n $AOAI -g $RG -l $Location --kind OpenAI --sku S0 `
            --custom-domain $AOAI --tags @Tags --yes -o none
        Ok "Creado $AOAI"
    }

    Log "3/5 Deployment del modelo..."
    $existing = Invoke-AzCli cognitiveservices account deployment list -g $RG -n $AOAI --query "[0].name" -o tsv
    if ($existing) {
        $deployName = $existing
        Ok "Deployment $deployName ya existe (se reutiliza)"
    } else {
        $sel = Select-ModelVersion
        if (-not $sel) {
            Die "No hay modelos desplegables con SKU $Sku en $Location. Revisa '.\dd-lab.ps1 models' o prueba: .\dd-lab.ps1 up -Sku Standard  /  -Location swedencentral"
        }
        $deployName = $sel.Name
        Log "Modelo: $($sel.Name)  |  Versión: $($sel.Version)  |  SKU: $Sku"
        try {
            Invoke-AzCli cognitiveservices account deployment create -g $RG -n $AOAI --deployment-name $deployName `
                --model-name $sel.Name --model-version $sel.Version --model-format OpenAI `
                --sku-name $Sku --sku-capacity $Capacity -o none
        } catch {
            Die "Falló el deployment. Lee el mensaje de az arriba. Opciones: -Sku Standard  /  -Location <otra región>  /  -Model <otro>"
        }
        Ok "Deployment $deployName ($($sel.Version)) creado"
    }

    Log "4/5 Obteniendo endpoint y key..."
    $endpoint = Invoke-AzCli cognitiveservices account show -n $AOAI -g $RG --query properties.endpoint -o tsv
    $key      = Invoke-AzCli cognitiveservices account keys list -n $AOAI -g $RG --query key1 -o tsv

    Log "5/5 Datos de Lakera (se guardan solo en el .env local)..."
    $lkKey = $null; $lkPid = $null
    if (Test-Path $EnvFile) {
        $old = Read-EnvFile
        $lkKey = $old["LAKERA_GUARD_API_KEY"]; $lkPid = $old["LAKERA_PROJECT_ID"]
    }
    if (-not $lkKey) {
        $sec = Read-Host "  Lakera Guard API key" -AsSecureString
        $lkKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    if (-not $lkPid) { $lkPid = Read-Host "  Lakera Project ID" }

    @(
        "AZURE_OPENAI_ENDPOINT=$endpoint"
        "AZURE_OPENAI_API_KEY=$key"
        "AZURE_OPENAI_DEPLOYMENT=$deployName"
        "LAKERA_GUARD_API_KEY=$lkKey"
        "LAKERA_PROJECT_ID=$lkPid"
    ) | Set-Content -Path $EnvFile -Encoding ASCII
    Ok ".env generado: $EnvFile"

    Show-Env
    Write-Host ""
    Ok "Lab listo. Siguientes pasos:"
    Write-Host "   .\dd-lab.ps1 run --check"
    Write-Host "   .\dd-lab.ps1 run --list"
    Write-Host "   .\dd-lab.ps1 run --all"
}

function Run-Demo {
    $demoPy = Get-DemoPy
    $vars = Read-EnvFile
    foreach ($k in $vars.Keys) { Set-Item -Path "Env:$k" -Value $vars[$k] }
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"

    $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $py) { Die "No encuentro Python: winget install -e --id Python.Python.3.12" }

    Write-Host "[dd-lab] python $(Split-Path $demoPy -Leaf) $($DemoArgs -join ' ')" -ForegroundColor DarkGray
    $ErrorActionPreference = "Continue"
    & $py.Source $demoPy @DemoArgs
}

function Status {
    Preflight
    if ((Invoke-AzCli group exists -n $RG) -eq "true") {
        Ok "RG $RG existe. Recursos:"
        Invoke-AzCli resource list -g $RG --query "[].{nombre:name, tipo:type}" -o table
        if (Test-AzCli cognitiveservices account show -n $AOAI -g $RG -o none) {
            Invoke-AzCli cognitiveservices account deployment list -g $RG -n $AOAI `
                --query "[].{deployment:name, modelo:properties.model.name, version:properties.model.version}" -o table
        }
    } else {
        Warn "RG $RG no existe"
    }
    $deleted = Invoke-AzCli cognitiveservices account list-deleted --query "[?name=='$AOAI'].location | [0]" -o tsv
    if ($deleted) { Warn "$AOAI está en soft-delete ($deleted)" } else { Ok "Nada en soft-delete" }
    if (Test-Path $EnvFile) { Warn ".env local existe: $EnvFile" } else { Ok "No hay .env local" }
}

function Down {
    Preflight
    Write-Host ""
    Warn "Se borrará el resource group '$RG' con TODO su contenido:"
    $rgExists = (Invoke-AzCli group exists -n $RG) -eq "true"
    if ($rgExists) {
        Invoke-AzCli resource list -g $RG --query "[].name" -o tsv | ForEach-Object { Write-Host "     - $_" }
    }
    $confirm = Read-Host "  Escribe BORRAR para confirmar"
    if ($confirm -ne "BORRAR") { Die "Cancelado." }

    if ($rgExists) {
        Log "1/3 Borrando resource group (tarda unos minutos)..."
        Invoke-AzCli group delete -n $RG --yes
        Ok "RG $RG eliminado"
    } else {
        Warn "RG $RG no existe (se omite)"
    }

    Log "2/3 Purgando Azure OpenAI en soft-delete..."
    $deleted = Invoke-AzCli cognitiveservices account list-deleted --query "[?name=='$AOAI'].location | [0]" -o tsv
    if ($deleted) {
        Invoke-AzCli cognitiveservices account purge -n $AOAI -g $RG -l $deleted -o none
        Ok "$AOAI purgado"
    } else {
        Ok "No hay nada en soft-delete"
    }

    Log "3/3 Eliminando .env local y variables de esta sesión..."
    if (Test-Path $EnvFile) { Remove-Item $EnvFile -Force; Ok ".env eliminado" } else { Ok "No había .env" }
    foreach ($k in $VarNames) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }

    Write-Host ""
    Ok "Limpieza completa. RG existe: $(Invoke-AzCli group exists -n $RG)"
    Warn "La carpeta .\logs (evidencia del Guard) NO se borra. Elimínala si no la necesitas."
    Warn "Si mostraste la API key de Lakera durante el demo, revócala en la consola de Lakera."
}

switch ($Action) {
    "up"     { Up }
    "models" { Show-Models }
    "env"    { Show-Env }
    "run"    { Run-Demo }
    "status" { Status }
    "down"   { Down }
    default  {
        Write-Host "Uso: .\dd-lab.ps1 {up|models|env|run|status|down}"
        Write-Host "  Ej: .\dd-lab.ps1 run --scenario 01 --pause"
        exit 1
    }
}

