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

$ErrorActionPreference = "Stop"
$TargetHost = "extractor.universidad.localhost"
$TraefikUrl = "http://127.0.0.1:80"
$TestPdf = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - VALIDACION RIGUROSA FACTOR IX: DESECHABILIDAD (PS)      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Comprobar Docker y entorno de integracion
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker offline" }
} catch {
    Write-Host "[ERROR] El daemon de Docker no esta en ejecucion." -ForegroundColor Red
    Write-Host "Inicie Docker y el entorno de integracion antes de ejecutar esta prueba."
    exit 1
}

$initialContainers = (docker compose -f docker-compose.integration.yml ps -q extractor 2>$null) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
$initialCount = $initialContainers.Count

if ($initialCount -eq 0) {
    Write-Host "[AVISO] No se detecto un entorno de integracion iniciado con replicas de extractor." -ForegroundColor Yellow
    Write-Host "Debe iniciar previamente el cluster con: docker compose -f docker-compose.integration.yml up -d" -ForegroundColor Cyan
    Write-Host "La prueba no modificara el entorno y se detiene sin alterar contenedores."
    exit 1
}

# 2. Comprobar Traefik
try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Host "[ERROR] Traefik no esta respondiendo en 127.0.0.1:8080. Inicie con 'docker compose up -d'." -ForegroundColor Red
    exit 1
}

# 3. Asegurar fixture PDF con offsets exactos (183 bytes)
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
    # TEST 1: Inicio Rapido (< 5s en la instancia especifica creada)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 1] Evaluando Arranque Rapido sobre una NUEVA replica especifica..." -ForegroundColor Yellow
    $beforeIds = @($initialContainers)
    $targetScale = $beforeIds.Count + 1

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$targetScale" extractor | Out-Null

    $afterIds = (docker compose -f docker-compose.integration.yml ps -q extractor) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $newId = ($afterIds | Where-Object { $_ -notin $beforeIds }) | Select-Object -First 1

    if (-not $newId) {
        Write-Host "[ERROR] No se pudo identificar inequivocamente la nueva instancia creada." -ForegroundColor Red
        exit 1
    }

    $newName = (docker inspect -f '{{.Name}}' $newId).TrimStart('/')
    Write-Host "Nueva instancia aislada detectada: $newName ($($newId.Substring(0,12)))" -ForegroundColor Cyan

    $startupHealthy = $false
    $elapsedSec = 0
    for ($i = 0; $i -lt 30; $i++) {
        $health = docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' $newId 2>$null
        if ($health -eq "healthy") {
            $sw.Stop()
            $elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            $startupHealthy = $true
            break
        }
        Start-Sleep -Milliseconds 200
    }

    if ($startupHealthy -and ($elapsedSec -le 5.0)) {
        Write-Host "OK: Contenedor $newName saludable en ${elapsedSec}s (< 5.0s limite estricto)." -ForegroundColor Green
    } else {
        Write-Host "FALLO: El contenedor no cumplio el limite de arranque de 5.0s (tiempo: ${elapsedSec}s, healthy: $startupHealthy)." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 2: Apagado Elegante (Graceful Shutdown) y Drenado de Extraccion Real
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 2] Evaluando Apagado Elegante (SIGTERM) y Drenado de Extraccion Real en $newName..." -ForegroundColor Yellow
    $auditId = "drain-test-" + [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + "-" + (Get-Random -Minimum 1000 -Maximum 9999)

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

    Start-Sleep -Milliseconds 80

    $stopSw = [System.Diagnostics.Stopwatch]::StartNew()
    docker stop $newId | Out-Null
    $stopSw.Stop()

    $jobResult = Receive-Job -Job $extractJob -Wait
    Remove-Job -Job $extractJob -Force | Out-Null

    $lines = $jobResult -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $httpCode = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)]) -join ""

    $exitCode = (docker inspect -f '{{.State.ExitCode}}' $newId).Trim()
    Write-Host "Codigo de salida del proceso tras SIGTERM: ExitCode=$exitCode (Duracion: $([math]::Round($stopSw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Cyan

    if ($exitCode -ne "0") {
        Write-Host "FALLO: El proceso no finalizo con ExitCode=0 tras SIGTERM (obtenido ExitCode=$exitCode)." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Apagado Elegante Verificado: ExitCode = 0 (Captura limpia de SIGTERM)." -ForegroundColor Green

    if ($httpCode -ne "200" -or -not ($body -match '"content"')) {
        Write-Host "FALLO: La extraccion en curso se aborto o devolvio error (HTTP $httpCode)." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Extraccion exitosa con HTTP 200 OK y JSON integro." -ForegroundColor Green

    # Comprobacion de si la solicitud fue atendida por la replica detenida
    $targetLogs = docker logs $newId 2>&1
    if ($targetLogs -match $auditId) {
        Write-Host "OK: Drenado Concluyente Verificado: Se comprobo en los logs de $newName (Audit ID: $auditId) que proceso y completo la extraccion antes de finalizar." -ForegroundColor Green
    } else {
        Write-Host "AVISO: Comprobacion de Drenado: La extraccion en vuelo finalizo con exito (HTTP 200 OK), pero el balanceador Traefik la derivo a otra replica sobreviviente (Audit ID $auditId no presente en logs de $newName). No se presenta como demostracion concluyente del drenaje en esta instancia especifica." -ForegroundColor Yellow
    }

    # --------------------------------------------------------------------------
    # TEST 3: Muerte Subita (Crash Resilience con SIGKILL intencional)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 3] Evaluando Tolerancia a Caida Subita (SIGKILL / Muerte Catastrofica)..." -ForegroundColor Yellow
    if (-not $AllowDestructive) {
        Write-Host "AVISO: Test 3 omitido: No se ejecuto la prueba destructiva (-AllowDestructive no especificado)." -ForegroundColor Yellow
        Write-Host "       No se declara validada la totalidad del Factor IX." -ForegroundColor Yellow
    } else {
        $remainingId = (docker compose -f docker-compose.integration.yml ps -q extractor) -split "`n" | Select-Object -First 1
        $victimName = (docker inspect -f '{{.Name}}' $remainingId).TrimStart('/')
        Write-Host "Inyectando fallo abrupto intencional (SIGKILL) a $victimName..."
        docker kill -s KILL $remainingId | Out-Null

        $killExit = (docker inspect -f '{{.State.ExitCode}}' $remainingId).Trim()
        Write-Host "Codigo de salida esperado por SIGKILL: ExitCode=$killExit" -ForegroundColor Cyan
        if ($killExit -eq "137") {
            Write-Host "OK: Confirmado: Finalizacion inmediata forzada por SIGKILL (codigo 137 esperado)." -ForegroundColor Green
        } else {
            Write-Host "FALLO: Se esperaba codigo 137 para SIGKILL, obtenido: $killExit." -ForegroundColor Red
            exit 1
        }

        $survivorCode = curl.exe -s -o /dev/null -w "%{http_code}" -H "Host: $TargetHost" "$TraefikUrl/health"
        if ($survivorCode -eq "200") {
            Write-Host "OK: Alta Disponibilidad: Cluster respondio HTTP 200 OK inmediatamente a traves de sobrevivientes." -ForegroundColor Green
        } else {
            Write-Host "FALLO: Trafico interrumpido tras caida subita (HTTP $survivorCode)." -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "  OK: EVALUACION DE FACTOR IX (DESECHABILIDAD) FINALIZADA (PS)         " -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "             RESTAURACION Y LIMPIEZA DE CONTENEDORES                  " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "Restableciendo el cluster a exactamente $initialCount replicas originales..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$initialCount" extractor 2>$null | Out-Null
    Write-Host "OK: Estado original del cluster restaurado ($initialCount replicas)." -ForegroundColor Green
}
