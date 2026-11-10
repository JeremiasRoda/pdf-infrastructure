<#
==============================================================================
Script de Inicio y Orquestacion Automatizada del Sistema Completo
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$ComposeFile = "docker-compose.integration.yml"
$NetworkName = "pdf-network"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   INICIANDO INFRAESTRUCTURA Y MICROSERVICIOS (PDF EXTRACTEXT)       " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Comprobar que Docker Desktop este ejecutandose
Write-Host "`n[PASO 1/4] Verificando estado de Docker Desktop..." -ForegroundColor Yellow
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker offline" }
    Write-Host "  -> Docker Desktop esta en ejecucion." -ForegroundColor Green
} catch {
    Write-Host "`n[ERROR] Docker Desktop NO esta abierto o no responde." -ForegroundColor Red
    Write-Host "Por favor, abre la aplicacion 'Docker Desktop' en Windows, espera a que inicie y vuelve a ejecutar este script.`n" -ForegroundColor Yellow
    exit 1
}

# 2. Verificar y crear la red externa compartida
Write-Host "`n[PASO 2/4] Verificando la red virtual compartida '$NetworkName'..." -ForegroundColor Yellow
$networkExists = docker network ls --filter "name=^${NetworkName}$" --format "{{.Name}}"
if (-not $networkExists) {
    Write-Host "  -> Creando red de tipo bridge '$NetworkName'..." -ForegroundColor Cyan
    docker network create --driver bridge --attachable $NetworkName | Out-Null
    Write-Host "  -> Red '$NetworkName' creada exitosamente." -ForegroundColor Green
} else {
    Write-Host "  -> La red '$NetworkName' ya existe." -ForegroundColor Green
}

# 3. Construir y levantar todos los contenedores en orden
Write-Host "`n[PASO 3/4] Levantando contenedores y compilando imagenes..." -ForegroundColor Yellow
docker compose -f $ComposeFile up -d --build
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Ocurrio un fallo al levantar los contenedores con Docker Compose." -ForegroundColor Red
    exit 1
}

# 4. Monitorear hasta que todos los servicios esten saludables (healthy)
Write-Host "`n[PASO 4/4] Esperando a que todos los servicios esten saludables (healthy)..." -ForegroundColor Yellow
$servicesWithHealth = @("consul", "mongodb", "extractor", "documents", "api")
$timeoutSeconds = 60
$elapsed = 0
$checkInterval = 3

while ($elapsed -lt $timeoutSeconds) {
    $allHealthy = $true
    $statusList = @()

    foreach ($svc in $servicesWithHealth) {
        $cids = (docker compose -f $ComposeFile ps -q $svc 2>$null) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
        if ($cids.Count -eq 0) {
            $allHealthy = $false
            $statusList += "$svc: no iniciado"
            continue
        }
        $cid = $cids[0]
        $health = (docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $cid 2>$null).Trim()
        $statusList += "$svc: $health"
        if ($health -ne "healthy") {
            $allHealthy = $false
        }
    }

    if ($allHealthy) {
        Write-Host "`n[EXITO] Todos los servicios se encuentran activos y saludables!" -ForegroundColor Green
        break
    }

    Write-Host "  Progreso ($($elapsed)s): $($statusList -join ' | ')" -ForegroundColor Gray
    Start-Sleep -Seconds $checkInterval
    $elapsed += $checkInterval
}

if (-not $allHealthy) {
    Write-Host "`n[ADVERTENCIA] Algunos servicios tardaron mas de ${timeoutSeconds}s en responder:" -ForegroundColor Yellow
    docker compose -f $ComposeFile ps
}

# 5. Resumen final con accesos directos para la evaluacion
Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "   SISTEMA OPERATIVO Y LISTO PARA LA EVALUACION                       " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host " - Traefik Dashboard : http://127.0.0.1:8080/dashboard/" -ForegroundColor Cyan
Write-Host " - HashiCorp Consul UI: http://127.0.0.1:8500/ui/" -ForegroundColor Cyan
Write-Host " - API Healthcheck   : http://127.0.0.1/health (Host: api.universidad.localhost)" -ForegroundColor Cyan
Write-Host " - Extractor Health  : http://127.0.0.1/health (Host: extractor.universidad.localhost)" -ForegroundColor Cyan
Write-Host " - Documents Health  : http://127.0.0.1/health (Host: documents.universidad.localhost)" -ForegroundColor Cyan
Write-Host "`nPara probar el flujo completo con un PDF ejecuta: .\scripts\upload-pdf.ps1" -ForegroundColor Yellow
Write-Host "Para detener el entorno ejecuta: .\scripts\stop.ps1`n" -ForegroundColor Yellow
