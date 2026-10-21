<#
.SYNOPSIS
    Demostración de Resiliencia, Balanceo y Tolerancia a Fallos con Traefik v3.
    Cátedra: Desarrollo de Software - UTN FR San Rafael.
.DESCRIPTION
    1. Verifica la presencia de Traefik v3 y réplicas del servicio 'extractor'.
    2. Detiene intencionalmente una réplica activa (Inyección de falla).
    3. Lanza una ráfaga de peticiones HTTP concurrentes hacia Traefik.
    4. Verifica que no haya pérdida de servicio (100% respuestas 200 OK).
#>

[CmdletBinding()]
param (
    [string]$TargetHost = "extractor.universidad.localhost",
    [string]$TraefikUrl = "http://127.0.0.1:80/health",
    [string]$PingUrl = "http://127.0.0.1:8080/ping",
    [int]$BurstCount = 40
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - DEMOSTRACIÓN DE TOLERANCIA A FALLOS Y RESILIENCIA      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Verificar conectividad con Traefik
Write-Host "`n[PASO 1] Verificando disponibilidad de Traefik..." -ForegroundColor Yellow
try {
    $pingResponse = Invoke-RestMethod -Uri $PingUrl -TimeoutSec 3 -ErrorAction Stop
    if ($pingResponse -eq "OK") {
        Write-Host "[OK] Traefik v3 activo y respondiendo." -ForegroundColor Green
    }
}
catch {
    Write-Host "[ERROR] Traefik no está respondiendo en el puerto 8080." -ForegroundColor Red
    Write-Host "Asegúrese de haber ejecutado: docker compose up -d" -ForegroundColor Yellow
    exit 1
}

# 2. Contar réplicas del extractor en Docker
Write-Host "`n[PASO 2] Detectando réplicas del microservicio 'extractor'..." -ForegroundColor Yellow
$containers = docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"
if (-not $containers) {
    $containers = docker ps --filter "name=extractor" --format "{{.ID}}"
}

$containerList = @($containers -split "`r?`n" | Where-Object { $_ -ne "" })
$totalInstances = $containerList.Count

Write-Host "Instancias activas de 'extractor' detectadas: " -NoNewline
Write-Host "$totalInstances" -ForegroundColor Green

if ($totalInstances -lt 2) {
    Write-Host "[ADVERTENCIA] Se requieren al menos 2 réplicas para demostrar resiliencia." -ForegroundColor Red
    Write-Host "Para escalar a 5 réplicas, ejecute:" -ForegroundColor Yellow
    Write-Host "  docker compose -f docker-compose.integration.yml up -d --scale extractor=5" -ForegroundColor Cyan
    exit 1
}

# Listar detalle de las instancias
Write-Host "Detalle de réplicas en ejecución:"
foreach ($cid in $containerList) {
    $cname = (docker inspect -f '{{.Name}}' $cid).TrimStart('/')
    $cip = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cid
    Write-Host "  - ID: $($cid.Substring(0, [Math]::Min(12, $cid.Length))) | Nombre: $cname | IP: $cip" -ForegroundColor Cyan
}

# 3. Seleccionar y matar una réplica
$victimId = $containerList[0]
$victimName = (docker inspect -f '{{.Name}}' $victimId).TrimStart('/')
Write-Host "`n[PASO 3] Inyectando falla: Deteniendo contenedor réplica '$victimName' ($($victimId.Substring(0,12)))..." -ForegroundColor Yellow
docker stop $victimId | Out-Null
Write-Host "[OK] Réplica detenida." -ForegroundColor Green -NoNewline
Write-Host " Quedan $($totalInstances - 1) réplicas vivas."

# 4. Disparar ráfaga de peticiones a través de Traefik
Write-Host "`n[PASO 4] Disparando ráfaga de $BurstCount peticiones hacia http://$TargetHost/health..." -ForegroundColor Yellow

$okCount = 0
$failCount = 0

for ($i = 1; $i -le $BurstCount; $i++) {
    try {
        # Usamos Invoke-WebRequest con Header Host para rutear vía localhost:80
        $response = Invoke-WebRequest -Uri $TraefikUrl -Headers @{ Host = $TargetHost } -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
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
    Start-Sleep -Milliseconds 25
}
Write-Host ""

# 5. Reporte de Resultados
Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "                        REPORTE DE AUDITORÍA                          " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Total de peticiones enviadas: $BurstCount"
Write-Host "Respuestas exitosas (200 OK): " -NoNewline
Write-Host "$okCount" -ForegroundColor Green
Write-Host "Peticiones fallidas:          " -NoNewline
Write-Host "$failCount" -ForegroundColor Red

if ($failCount -eq 0) {
    Write-Host "`n✔ ÉXITO TOTAL (0% de errores): Traefik balanceó transparentemente la carga" -ForegroundColor Green
    Write-Host "  hacia las réplicas sanas sin degradación de servicio percibida por el cliente." -ForegroundColor Green
} else {
    $errPct = [Math]::Round(($failCount / $BurstCount) * 100, 2)
    Write-Host "`n✘ HUBO ERRORES ($errPct% de fallas). Verifique el healthcheck en Traefik." -ForegroundColor Red
}

Write-Host "`n[PASO 5] Para restaurar la réplica o volver al estado deseado:" -ForegroundColor Yellow
Write-Host "  docker compose -f docker-compose.integration.yml up -d --scale extractor=5`n" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
