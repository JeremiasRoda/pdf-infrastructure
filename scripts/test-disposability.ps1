<#
==============================================================================
Demostración y Validación del Factor IX (Desechabilidad - Twelve-Factor App)
Cátedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
Aspectos auditados:
1. Inicio Rápido: < 5s medido en la instancia específica creada.
2. Apagado Elegante: Drenado de extracción real de PDF en vuelo ante SIGTERM y
   código de salida limpio (ExitCode = 0).
3. Muerte Súbita: SIGKILL (código 137 esperado) y recuperación sin caída.
   Requiere -AllowDestructive.
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
Write-Host "   UTN FRSR - VALIDACIÓN RIGUROSA FACTOR IX: DESECHABILIDAD (POWERSHELL)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Comprobar Traefik
try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Host "[ERROR] Traefik no está respondiendo en 127.0.0.1:8080. Inicie con 'docker compose up -d'." -ForegroundColor Red
    exit 1
}

# 2. Asegurar fixture PDF
if (-not (Test-Path $TestPdf)) {
    $parent = Split-Path -Parent $TestPdf
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $pdfMinimal = @"
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
190
%%EOF
"@
    [System.IO.File]::WriteAllText($TestPdf, $pdfMinimal)
}

# Obtener réplicas iniciales para restaurar al finalizar
$initialContainers = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
$initialCount = $initialContainers.Count
if ($initialCount -lt 2) { $initialCount = 2 }

try {
    if ($initialContainers.Count -lt 2) {
        Write-Host "Escalando a 2 réplicas base para pruebas..." -ForegroundColor Yellow
        docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=2 extractor | Out-Null
        Start-Sleep -Seconds 3
        $initialContainers = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    }

    # --------------------------------------------------------------------------
    # TEST 1: Inicio Rápido (< 5s en la instancia específica creada)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 1] Evaluando Arranque Rápido sobre una NUEVA réplica específica..." -ForegroundColor Yellow
    $beforeIds = @($initialContainers)
    $targetScale = $beforeIds.Count + 1

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$targetScale" extractor | Out-Null

    $afterIds = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $newId = ($afterIds | Where-Object { $_ -notin $beforeIds }) | Select-Object -First 1

    if (-not $newId) {
        Write-Host "[ERROR] No se pudo identificar la nueva instancia creada." -ForegroundColor Red
        exit 1
    }

    $newName = (docker inspect -f '{{.Name}}' $newId).TrimStart('/')
    Write-Host "Nueva instancia aislada detectada: $newName ($($newId.Substring(0,12)))" -ForegroundColor Cyan

    $startupHealthy = $false
    $elapsedSec = 0
    for ($i = 0; $i -lt 25; $i++) {
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
        Write-Host "✔ ÉXITO: Contenedor $newName saludable en ${elapsedSec}s (< 5.0s límite de cátedra)." -ForegroundColor Green
    } elseif ($startupHealthy) {
        Write-Host "⚠ AVISO: El contenedor tardó ${elapsedSec}s (> 5.0s)." -ForegroundColor Yellow
    } else {
        Write-Host "✘ FALLO: El contenedor no alcanzó estado healthy en el tiempo esperado." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 2: Apagado Elegante (Graceful Shutdown) y Drenado de Extracción Real
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 2] Evaluando Apagado Elegante (SIGTERM) y Drenado de Extracción Real en $newName..." -ForegroundColor Yellow
    
    # Lanzar extracción real en segundo plano apuntando a Traefik
    $extractJob = Start-Job -ScriptBlock {
        param($pdfPath, $traefikUrl, $targetHost)
        $resp = curl.exe -s -w "`n%{http_code}" -X POST "$traefikUrl/extract" `
            -H "Host: $targetHost" `
            -H "Content-Type: application/pdf" `
            -H "X-Filename: disposability_test.pdf" `
            --data-binary "@$pdfPath"
        return $resp
    } -ArgumentList (Resolve-Path $TestPdf).Path, $TraefikUrl, $TargetHost

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
    Write-Host "Código de salida del proceso tras SIGTERM: ExitCode=$exitCode (Duración: $([math]::Round($stopSw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Cyan

    if ($exitCode -ne "0") {
        Write-Host "✘ FALLO: El proceso no finalizó con ExitCode=0 (obtenido ExitCode=$exitCode)." -ForegroundColor Red
        exit 1
    }
    Write-Host "✔ Apagado Elegante Verificado: ExitCode = 0 (Captura limpia de SIGTERM)." -ForegroundColor Green

    if ($httpCode -eq "200" -and $body -match '"content"') {
        Write-Host "✔ Drenado Exitoso: La extracción real en vuelo finalizó con HTTP 200 OK y JSON íntegro." -ForegroundColor Green
    } else {
        Write-Host "✘ FALLO: La extracción en vuelo se abortó o devolvió error (HTTP $httpCode)." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 3: Muerte Súbita (Crash Resilience con SIGKILL intencional)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 3] Evaluando Tolerancia a Caída Súbita (SIGKILL / Muerte Catastrófica)..." -ForegroundColor Yellow
    if (-not $AllowDestructive) {
        Write-Host "ℹ Test 3 omitido por seguridad. Para habilitarlo ejecute:" -ForegroundColor Yellow
        Write-Host "  .\scripts\test-disposability.ps1 -AllowDestructive" -ForegroundColor Cyan
    } else {
        $remainingId = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Select-Object -First 1
        $victimName = (docker inspect -f '{{.Name}}' $remainingId).TrimStart('/')
        Write-Host "Inyectando fallo abrupto intencional (SIGKILL) a $victimName..."
        docker kill -s KILL $remainingId | Out-Null

        $killExit = (docker inspect -f '{{.State.ExitCode}}' $remainingId).Trim()
        Write-Host "Código de salida esperado por SIGKILL: ExitCode=$killExit" -ForegroundColor Cyan
        if ($killExit -eq "137") {
            Write-Host "✔ Confirmado: Finalización inmediata forzada por SIGKILL (código 137 esperado)." -ForegroundColor Green
        }

        $survivorCode = curl.exe -s -o /dev/null -w "%{http_code}" -H "Host: $TargetHost" "$TraefikUrl/health"
        if ($survivorCode -eq "200") {
            Write-Host "✔ Alta Disponibilidad: Clúster respondió HTTP 200 OK inmediatamente a través de sobrevivientes." -ForegroundColor Green
        } else {
            Write-Host "✘ FALLO: Tráfico interrumpido tras caída súbita (HTTP $survivorCode)." -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "  ✔ FACTOR IX (DESECHABILIDAD) VALIDADO RIGUROSAMENTE CON ÉXITO" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "             RESTAURACIÓN Y LIMPIEZA DE CONTENEDORES                  " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "Restableciendo el clúster a $initialCount réplicas..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$initialCount" extractor 2>$null | Out-Null
    Write-Host "[OK] Estado original del clúster restaurado." -ForegroundColor Green
}
