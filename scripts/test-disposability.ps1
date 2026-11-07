<#
==============================================================================
Demostracion y Validacion del Factor IX (Desechabilidad - Twelve-Factor App)
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

[CmdletBinding()]
param(
    [switch]$AllowDestructive = $false
)

$ErrorActionPreference = "Continue"
$TargetHost = "extractor.universidad.localhost"
$TraefikUrl = "http://127.0.0.1:80"
$TestPdf = "load-tests/pdfs/doc1.pdf"

$test1Failed = $false
$test2Failed = $false
$test3Failed = $false

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - VALIDACION RIGUROSA FACTOR IX: DESECHABILIDAD (PS)      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Comprobar Docker y entorno de integracion
# ------------------------------------------------------------------------------
cmd.exe /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] El daemon de Docker no esta en ejecucion." -ForegroundColor Red
    Write-Host "Inicie Docker y el entorno de integracion antes de ejecutar esta prueba."
    exit 1
}

$initialContainers = @(cmd.exe /c "docker compose -f docker-compose.integration.yml ps -q extractor 2>nul") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
$initialCount = $initialContainers.Count

if ($initialCount -eq 0) {
    Write-Host "[AVISO] No se detecto un entorno de integracion iniciado con replicas de extractor." -ForegroundColor Yellow
    Write-Host "Debe iniciar previamente el cluster con: docker compose -f docker-compose.integration.yml up -d" -ForegroundColor Cyan
    Write-Host "La prueba no modificara el entorno y se detiene sin alterar contenedores."
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Comprobar Traefik
# ------------------------------------------------------------------------------
try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
} catch {
    Write-Host "[ERROR] Traefik no esta respondiendo en 127.0.0.1:8080. Inicie con 'docker compose up -d'." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Asegurar fixture PDF con offsets exactos (183 bytes)
# ------------------------------------------------------------------------------
if (-not (Test-Path $TestPdf)) {
    $parent = Split-Path -Parent $TestPdf
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $pdfMinimal = @'
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
endobj
xref
0 4
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
trailer
<< /Size 4 /Root 1 0 R >>
startxref
183
%%EOF
'@
    [System.IO.File]::WriteAllText($TestPdf, $pdfMinimal, [System.Text.Encoding]::ASCII)
}

try {
    # --------------------------------------------------------------------------
    # TEST 1: Inicio Rapido (<= 5.0s en la instancia especifica creada)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 1] Evaluando Arranque Rapido sobre una NUEVA replica especifica..." -ForegroundColor Yellow
    $beforeIds = @($initialContainers)
    $targetScale = $beforeIds.Count + 1

    $observationTimeoutSec = 30.0
    $acceptanceLimitSec = 5.0
    $startupHealthy = $false
    $lastObservedState = "desconocido"
    $newId = $null

    # 1. Iniciar cronometro ANTES de ejecutar docker compose up
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $scaleUpOut = cmd.exe /c "docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=$targetScale extractor 2>&1"
    $scaleExit = $LASTEXITCODE
    if ($scaleExit -ne 0) {
        Write-Host "FALLO: Docker Compose devolvio error ($scaleExit) al escalar extractor a $targetScale." -ForegroundColor Red
        if ($scaleUpOut) { Write-Host "Detalle: $scaleUpOut" -ForegroundColor Red }
        exit 1
    }

    # 2. Identificar inequivocamente la nueva replica por diferencia de IDs
    $afterIds = @(cmd.exe /c "docker compose -f docker-compose.integration.yml ps -q extractor 2>nul") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
    $newId = ($afterIds | Where-Object { $_ -notin $beforeIds }) | Select-Object -First 1

    if (-not $newId) {
        Write-Host "FALLO: No se pudo identificar inequivocamente la nueva instancia creada." -ForegroundColor Red
        exit 1
    }

    $newName = ((docker inspect -f '{{.Name}}' $newId 2>$null) -as [string]).Trim().TrimStart('/')
    Write-Host "Nueva instancia aislada detectada: $newName ($($newId.Substring(0, [math]::Min(12, $newId.Length))))" -ForegroundColor Cyan

    # 3. Sondeo continuo con margen suficiente para observar healthcheck (interval: 5s, start_period: 5s)
    while ($sw.Elapsed.TotalSeconds -lt $observationTimeoutSec) {
        $healthRaw = (docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin_healthcheck{{end}}' $newId 2>$null)
        if ($healthRaw) {
            $lastObservedState = $healthRaw.Trim()
        }

        if ($lastObservedState -eq "healthy") {
            $sw.Stop()
            $startupHealthy = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ($sw.IsRunning) {
        $sw.Stop()
    }
    $elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)

    # 4. Validacion estricta: Limite inamovible de 5.0s y distincion clara de timeout de observacion
    if ($startupHealthy -and ($elapsedSec -le $acceptanceLimitSec)) {
        Write-Host "OK: Contenedor $newName saludable en ${elapsedSec}s (<= ${acceptanceLimitSec}s limite estricto)." -ForegroundColor Green
    } elseif ($startupHealthy -and ($elapsedSec -gt $acceptanceLimitSec)) {
        Write-Host "FALLO: Contenedor $newName alcanzo estado 'healthy' pero tardo ${elapsedSec}s, superando el limite estricto de ${acceptanceLimitSec}s." -ForegroundColor Red
        Write-Host "       (El tiempo medido desde la ejecucion de docker compose up excede el umbral debido a la inicializacion del contenedor y la ventana del healthcheck [start_period: 5s, interval: 5s])." -ForegroundColor Yellow
        $test1Failed = $true
    } else {
        Write-Host "FALLO (TIMEOUT DE OBSERVACION): Contenedor $newName no alcanzo estado 'healthy' tras ${elapsedSec}s de observacion. Ultimo estado observado: '$lastObservedState'." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 2: Apagado Elegante (Graceful Shutdown) y Drenado de Peticiones
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 2] Evaluando Apagado Elegante (SIGTERM) y Drenado en $newName..." -ForegroundColor Yellow
    $auditId = "drain-test-" + [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + "-" + (Get-Random -Minimum 1000 -Maximum 9999)

    # Lanzar la peticion HTTP hacia Traefik en segundo plano sin esperas arbitrarias
    $extractJob = Start-Job -ScriptBlock {
        param($pdfPath, $traefikUrl, $targetHost, $auditId)
        $resp = curl.exe -s -w "`n%{http_code}" -X POST "$traefikUrl/extract" `
            -H "Host: $targetHost" `
            -H "Content-Type: application/pdf" `
            -H "X-Filename: disposability_test.pdf" `
            -H "X-Audit-Id: $auditId" `
            -H "X-Request-Id: $auditId" `
            --data-binary "@$pdfPath"
        return $resp
    } -ArgumentList (Resolve-Path $TestPdf).Path, $TraefikUrl, $TargetHost, $auditId

    # Iniciar detencion concurrente del contenedor objetivo mediante SIGTERM (docker stop)
    $stopSw = [System.Diagnostics.Stopwatch]::StartNew()
    $stopOut = cmd.exe /c "docker stop $newId 2>&1"
    $stopSw.Stop()

    $jobResult = Receive-Job -Job $extractJob -Wait
    Remove-Job -Job $extractJob -Force | Out-Null

    $lines = $jobResult -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $httpCode = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)]) -join ""

    # Comprobar codigo de salida del contenedor tras SIGTERM (0 o 143 = 128 + SIGTERM 15)
    $exitCode = ((docker inspect -f '{{.State.ExitCode}}' $newId 2>$null) -as [string]).Trim()
    Write-Host "Codigo de salida del contenedor tras SIGTERM: ExitCode=$exitCode (Parada ejecutada en $([math]::Round($stopSw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Cyan

    if ($exitCode -ne "0" -and $exitCode -ne "143") {
        Write-Host "FALLO: El proceso no finalizo limpiamente tras SIGTERM (obtenido ExitCode=$exitCode)." -ForegroundColor Red
        $test2Failed = $true
    } else {
        Write-Host "OK: Apagado Elegante Verificado: ExitCode = $exitCode (Captura limpia de senal de terminacion sin interrupcion forzada)." -ForegroundColor Green
    }

    # Comprobar respuesta HTTP de la peticion
    if ($httpCode -ne "200" -or -not ($body -match '"content"')) {
        Write-Host "FALLO: La peticion de extraccion devolvio error o contenido invalido (HTTP $httpCode)." -ForegroundColor Red
        $test2Failed = $true
    } else {
        Write-Host "OK: Peticion respondio con HTTP 200 OK y estructura JSON integra." -ForegroundColor Green
    }

    # Demostracion fehaciente mediante logs: comprobar si la peticion fue atendida por la replica objetivo
    $targetLogs = docker logs $newId 2>&1
    $handledByTarget = ($targetLogs -match $auditId)

    if (-not $handledByTarget) {
        Write-Host "FALLO / NO CONCLUYENTE: La peticion de prueba no fue atendida por la replica objetivo ($newName)." -ForegroundColor Red
        Write-Host "       El balanceador Traefik derivo la solicitud a otra replica del cluster (Audit ID $auditId ausente en logs de $newName)." -ForegroundColor Yellow
        Write-Host "       No es posible certificar el drenado en esta instancia sin evidencia real de que haya procesado la peticion." -ForegroundColor Yellow
        Write-Host "       Limitacion arquitectonica: Traefik distribuye entre el pool disponible sin afinidad de sesion en el cliente de prueba." -ForegroundColor Yellow
        $test2Failed = $true
    } else {
        Write-Host "OK: Evidencia Confirmada: Se verifico en los logs de $newName (Audit ID: $auditId) que esta replica proceso la peticion." -ForegroundColor Green
        Write-Host "AVISO TECNICO: El microservicio extractor procesa PDFs en memoria en ~10ms sin mecanismos para pausar o demorar la respuesta." -ForegroundColor Yellow
        Write-Host "               Aunque la solicitud finalizo con HTTP 200 y el contenedor con ExitCode=$exitCode, la arquitectura actual" -ForegroundColor Yellow
        Write-Host "               no permite certificar de forma determinista la coincidencia exacta de la peticion en vuelo durante la recepcion de SIGTERM." -ForegroundColor Yellow
    }

    # --------------------------------------------------------------------------
    # TEST 3: Muerte Subita (Crash Resilience con SIGKILL intencional)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 3] Evaluando Tolerancia a Caida Subita (SIGKILL / Muerte Catastrofica)..." -ForegroundColor Yellow
    if (-not $AllowDestructive) {
        Write-Host "AVISO: Test 3 omitido: No se ejecuto la prueba destructiva (-AllowDestructive no especificado)." -ForegroundColor Yellow
        Write-Host "       No se declara validada la totalidad del Factor IX." -ForegroundColor Yellow
    } else {
        $remainingContainers = @(cmd.exe /c "docker compose -f docker-compose.integration.yml ps -q extractor 2>nul") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
        if ($remainingContainers.Count -lt 1) {
            Write-Host "FALLO: No hay replicas activas de extractor para ejecutar Test 3." -ForegroundColor Red
            $test3Failed = $true
        } else {
            $victimId = $remainingContainers[0]
            $victimName = ((docker inspect -f '{{.Name}}' $victimId 2>$null) -as [string]).Trim().TrimStart('/')
            Write-Host "Inyectando fallo abrupto intencional (SIGKILL) a $victimName ($($victimId.Substring(0, [math]::Min(12, $victimId.Length))))..."
            cmd.exe /c "docker kill -s KILL $victimId >nul 2>&1"

            $killExit = ((docker inspect -f '{{.State.ExitCode}}' $victimId 2>$null) -as [string]).Trim()
            Write-Host "Codigo de salida observado por SIGKILL: ExitCode=$killExit" -ForegroundColor Cyan
            if ($killExit -eq "137") {
                Write-Host "OK: Confirmado: Finalizacion inmediata forzada por SIGKILL (codigo 137 esperado)." -ForegroundColor Green
            } else {
                Write-Host "FALLO: Se esperaba codigo 137 para SIGKILL, obtenido: $killExit." -ForegroundColor Red
                $test3Failed = $true
            }

            $survivorCode = curl.exe -s -o nul -w "%{http_code}" -H "Host: $TargetHost" "$TraefikUrl/health"
            if ($survivorCode -eq "200") {
                Write-Host "OK: Alta Disponibilidad: Cluster respondio HTTP 200 OK inmediatamente a traves de sobrevivientes." -ForegroundColor Green
            } else {
                Write-Host "FALLO: Trafico interrumpido tras caida subita (HTTP $survivorCode)." -ForegroundColor Red
                $test3Failed = $true
            }
        }
    }

    # --------------------------------------------------------------------------
    # Evaluacion Final del Suite
    # --------------------------------------------------------------------------
    if ($test1Failed -or $test2Failed -or $test3Failed) {
        Write-Host "`n======================================================================" -ForegroundColor Red
        Write-Host "  RESULTADO: NO CONCLUYENTE O FALLIDO EN UNO O MAS ENSAYOS            " -ForegroundColor Red
        Write-Host "======================================================================" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "`n======================================================================" -ForegroundColor Green
        Write-Host "  OK: EVALUACION DE FACTOR IX (DESECHABILIDAD) FINALIZADA EXITOSAMENTE" -ForegroundColor Green
        Write-Host "======================================================================" -ForegroundColor Green
    }

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "             RESTAURACION Y LIMPIEZA DE CONTENEDORES                  " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "Restableciendo el cluster a exactamente $initialCount replicas originales..."

    $restoreOutput = cmd.exe /c "docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=$initialCount extractor 2>&1"
    $composeExit = $LASTEXITCODE

    if ($composeExit -ne 0) {
        Write-Host "FALLO EN RESTAURACION: Docker Compose devolvio codigo de error $composeExit." -ForegroundColor Red
        if ($restoreOutput) {
            Write-Host "Detalle: $restoreOutput" -ForegroundColor Red
        }
    } else {
        $restoredContainers = @(cmd.exe /c "docker compose -f docker-compose.integration.yml ps -q extractor 2>nul") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
        $restoredCount = $restoredContainers.Count

        if ($restoredCount -eq $initialCount) {
            Write-Host "OK: Estado original del cluster verificado exitosamente ($restoredCount replicas de extractor activas)." -ForegroundColor Green
        } else {
            Write-Host "FALLO EN RESTAURACION: Se esperaban $initialCount replicas de extractor, pero se detectaron $restoredCount activas." -ForegroundColor Red
        }
    }
}
