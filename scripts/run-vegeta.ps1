<#
==============================================================================
Script de Pruebas de Carga y Resiliencia con VEGETA
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

param(
    [int]$Rate = 30,          # Peticiones por segundo
    [int]$DurationSeconds = 5 # Duracion de la prueba
)

$ErrorActionPreference = "Stop"
$TargetHost = "api.universidad.localhost"
$TraefikPort = 80

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   PRUEBA DE ESTRES Y RESILIENCIA CON VEGETA                          " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " Tasa: $Rate req/s | Duracion: ${DurationSeconds}s | Destino: http://127.0.0.1:$TraefikPort/health" -ForegroundColor Yellow

# Comprobar si vegeta esta instalado en la maquina local
$hasLocalVegeta = Get-Command "vegeta" -ErrorAction SilentlyContinue

$targetContent = "GET http://127.0.0.1:$TraefikPort/health`nHost: $TargetHost`n`n"
$targetsFile = "vegeta-targets.txt"
$binFile = "vegeta-results.bin"

Set-Content -Path $targetsFile -Value $targetContent -NoNewline

try {
    if ($hasLocalVegeta) {
        Write-Host "`n[INFO] Ejecutando con binario local de Vegeta..." -ForegroundColor Cyan
        Get-Content $targetsFile | vegeta attack -rate=$Rate -duration="${DurationSeconds}s" | Tee-Object -FilePath $binFile | vegeta report
    } else {
        Write-Host "`n[INFO] Binario local no detectado. Ejecutando Vegeta mediante contenedor Docker (peterevans/vegeta)..." -ForegroundColor Cyan
        # Usamos host.docker.internal para alcanzar el puerto 80 de Traefik desde dentro del contenedor
        $dockerTarget = "GET http://host.docker.internal:$TraefikPort/health`nHost: $TargetHost`n`n"
        Set-Content -Path $targetsFile -Value $dockerTarget -NoNewline

        Get-Content $targetsFile | docker run --rm -i peterevans/vegeta sh -c "vegeta attack -rate=$Rate -duration=${DurationSeconds}s | vegeta report"
    }

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "   PRUEBA DE VEGETA COMPLETADA CON EXITO                              " -ForegroundColor Green
    Write-Host "======================================================================`n" -ForegroundColor Green
} catch {
    Write-Host "`n[ERROR] Ocurrio un fallo al ejecutar la prueba de Vegeta:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    if (Test-Path $targetsFile) { Remove-Item $targetsFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $binFile) { Remove-Item $binFile -Force -ErrorAction SilentlyContinue }
}
