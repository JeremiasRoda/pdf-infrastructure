<#
==============================================================================
Script de Auditoria de Vulnerabilidades con TRIVY y GRYPE (via Docker)
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   AUDITORIA DE SEGURIDAD ESTICA (TRIVY & GRYPE)                      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Ejecucion de Trivy File System scan
Write-Host "`n[PASO 1/2] Ejecutando analisis de configuracion y dependencias con TRIVY..." -ForegroundColor Yellow
$currentDir = (Get-Location).Path
docker run --rm -v "${currentDir}:/workspace" aquasec/trivy fs --severity HIGH,CRITICAL /workspace

# 2. Ejecucion de Grype
Write-Host "`n[PASO 2/2] Ejecutando analisis con GRYPE..." -ForegroundColor Yellow
docker run --rm -v "${currentDir}:/workspace" anchore/grype dir:/workspace --only-fixed

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "   AUDITORIA FINALIZADA                                               " -ForegroundColor Green
Write-Host "======================================================================`n" -ForegroundColor Green
