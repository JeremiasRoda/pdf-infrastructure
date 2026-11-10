<#
==============================================================================
Script de Detencion Ordenada de la Infraestructura y Microservicios
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

param(
    [switch]$CleanVolumes
)

$ComposeFile = "docker-compose.integration.yml"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   DETENIENDO INFRAESTRUCTURA Y MICROSERVICIOS                        " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

if ($CleanVolumes) {
    Write-Host "`n[INFO] Deteniendo servicios y eliminando volumenes de datos..." -ForegroundColor Yellow
    docker compose -f $ComposeFile down -v
} else {
    Write-Host "`n[INFO] Deteniendo contenedores de forma ordenada (preservando datos persistentes)..." -ForegroundColor Yellow
    docker compose -f $ComposeFile down
}

Write-Host "`n[EXITO] Entorno detenido correctamente.`n" -ForegroundColor Green
