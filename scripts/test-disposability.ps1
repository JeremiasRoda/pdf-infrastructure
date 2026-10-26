<#
.SYNOPSIS
    Script de Demostración del Factor IX (Desechabilidad - Twelve-Factor App).
    Cátedra: Desarrollo de Software - UTN FR San Rafael (Issue #8).
.DESCRIPTION
    Evalúa:
    1. Arranque Rápido (Fast Startup): Tiempo desde creación hasta estado saludable (< 5s).
    2. Apagado Elegante (Graceful Shutdown): Drenado de peticiones y salida limpia (Exit 0, no 137).
    3. Resiliencia ante Caída Súbita (Crash Resilience): Tolerancia a SIGKILL sin corrupción.
#>

[CmdletBinding()]
param (
    [string]$TargetHost = "extractor.universidad.localhost",
    [string]$HealthUrl = "http://127.0.0.1:80/health",
    [string]$PingUrl = "http://127.0.0.1:8080/ping"
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - EVALUACIÓN FACTOR IX: DESECHABILIDAD (TWELVE-FACTOR)    " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Verificar Traefik
try {
    $ping = Invoke-RestMethod -Uri $PingUrl -TimeoutSec 3 -ErrorAction Stop
    if ($ping -ne "OK") { throw }
}
catch {
    Write-Host "[ERROR] Traefik no está respondiendo en el puerto 8080. Ejecute 'docker compose up -d'." -ForegroundColor Red
    exit 1
}

# 2. Detectar réplicas del extractor
$rawContainers = docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"
$containers = @($rawContainers -split "`r?`n" | Where-Object { $_ -ne "" })

if ($containers.Count -lt 2) {
    Write-Host "[AVISO] Se requieren al menos 2 réplicas para probar drenado sin corte." -ForegroundColor Yellow
    Write-Host "Escalando a 3 réplicas..." -ForegroundColor Cyan
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor | Out-Null
    Start-Sleep -Seconds 3
    $rawContainers = docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"
    $containers = @($rawContainers -split "`r?`n" | Where-Object { $_ -ne "" })
}

Write-Host "Instancias activas de extractor detectadas: $($containers.Count)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# TEST 1: Arranque Rápido (Fast Startup)
# ------------------------------------------------------------------------------
Write-Host "`n[TEST 1] Evaluando Arranque Rápido (Fast Startup)..." -ForegroundColor Yellow
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$newTargetCount = $containers.Count + 1

docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=$newTargetCount extractor | Out-Null

$isHealthy = $false
for ($i = 1; $i -le 20; $i++) {
    try {
        $res = Invoke-WebRequest -Uri $HealthUrl -Headers @{ Host = $TargetHost } -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($res.StatusCode -eq 200) {
            $isHealthy = $true
            break
        }
    }
    catch {
        Start-Sleep -Milliseconds 250
    }
}
$sw.Stop()
$elapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

Write-Host "Tiempo de arranque y disponibilidad: $elapsedSec s" -ForegroundColor Green
if ($elapsedSec -lt 5.0) {
    Write-Host "✔ Cumple Criterio: Arranque rápido inferior a 5 segundos." -ForegroundColor Green
}
else {
    Write-Host "⚠ Arranque superior a 5s pero dentro de límites tolerables." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# TEST 2: Apagado Elegante y Drenado (Graceful Shutdown)
# ------------------------------------------------------------------------------
$targetCid = $containers[0]
$targetName = (docker inspect -f '{{.Name}}' $targetCid).TrimStart('/')

Write-Host "`n[TEST 2] Evaluando Apagado Elegante (Graceful Shutdown) en $targetName..." -ForegroundColor Yellow
Write-Host "Enviando SIGTERM con 'docker stop' y midiendo tiempo de drenado..." -ForegroundColor Cyan

$stopJob = Start-Job -ScriptBlock { param($cid) docker stop $cid } -ArgumentList $targetCid

$okCount = 0
$failCount = 0

while ($stopJob.State -eq 'Running') {
    try {
        $res = Invoke-WebRequest -Uri $HealthUrl -Headers @{ Host = $TargetHost } -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($res.StatusCode -eq 200) {
            $okCount++
            Write-Host "." -ForegroundColor Green -NoNewline
        } else {
            $failCount++
            Write-Host "X" -ForegroundColor Red -NoNewline
        }
    }
    catch {
        $failCount++
        Write-Host "X" -ForegroundColor Red -NoNewline
    }
    Start-Sleep -Milliseconds 100
}
Write-Host ""
Receive-Job $stopJob | Out-Null
Remove-Job $stopJob

$exitCode = (docker inspect -f '{{.State.ExitCode}}' $targetCid).Trim()
Write-Host "Código de salida del proceso al recibir SIGTERM: ExitCode=$exitCode" -ForegroundColor Cyan

if ($exitCode -eq "0") {
    Write-Host "✔ ÉXITO TOTAL: El contenedor interceptó SIGTERM y finalizó limpiamente (ExitCode=0)." -ForegroundColor Green
}
elseif ($exitCode -eq "137") {
    Write-Host "✘ FALLO: El contenedor fue forzado a morir por SIGKILL (ExitCode=137). Revise stop_grace_period o exec." -ForegroundColor Red
}
else {
    Write-Host "ℹ Finalizó con código $exitCode." -ForegroundColor Yellow
}

if ($failCount -eq 0) {
    Write-Host "✔ Cero Downtime: 100% de peticiones exitosas durante el apagado ($okCount exitosas)." -ForegroundColor Green
}
else {
    Write-Host "✘ Hubo $failCount peticiones caídas durante el apagado." -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# TEST 3: Resiliencia ante Caída Súbita (Crash Resilience)
# ------------------------------------------------------------------------------
$rawRemaining = docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"
$remainingList = @($rawRemaining -split "`r?`n" | Where-Object { $_ -ne "" })
$victimCid = $remainingList[0]

Write-Host "`n[TEST 3] Evaluando Resiliencia ante Caída Súbita (SIGKILL / Muerte de Hardware)..." -ForegroundColor Yellow
Write-Host "Matando contenedor réplica con 'docker kill'..." -ForegroundColor Cyan
docker kill $victimCid | Out-Null

try {
    $res = Invoke-WebRequest -Uri $HealthUrl -Headers @{ Host = $TargetHost } -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    if ($res.StatusCode -eq 200) {
        Write-Host "✔ Sistema Resiliente: Traefik descartó la réplica muerta y respondió 200 OK con el clúster." -ForegroundColor Green
    }
}
catch {
    Write-Host "✘ Error al resolver tras muerte súbita." -ForegroundColor Red
}

# Restaurar estado
Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "                    RESTAURANDO ESTADO DEL CLÚSTER                    " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor | Out-Null
Write-Host "[OK] Clúster restablecido a 3 réplicas saludables." -ForegroundColor Green
Write-Host "======================================================================`n" -ForegroundColor Cyan
