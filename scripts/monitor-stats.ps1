<#
.SYNOPSIS
    Monitor de Recursos en Vivo para Benchmarks de Carga (k6 / Vegeta).
    Cátedra: Desarrollo de Software - UTN FR San Rafael.
.DESCRIPTION
    Monitorea en tiempo real el consumo de CPU, RAM e I/O de:
    - Todas las réplicas de 'extractor'
    - El Reverse Proxy 'traefik'
    Permite opcionalmente exportar a un archivo CSV para gráficos del informe final.
#>

[CmdletBinding()]
param (
    [string]$CsvExportPath = ""
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - MONITOR DE RECURSOS (CPU / RAM / RED) EN VIVO           " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Presione Ctrl+C para finalizar la monitorizacion.`n" -ForegroundColor Yellow

# Obtener nombres de contenedores activos
$allContainers = docker ps --format "{{.Names}}"
$targetContainers = @($allContainers -split "`r?`n" | Where-Object { $_ -match "extractor|traefik|api|documents|redis" })

if ($targetContainers.Count -eq 0) {
    Write-Host "AVISO: No se detectaron contenedores activos de extractor o traefik." -ForegroundColor Yellow
    Write-Host "Monitoreando todos los contenedores en ejecucion..." -ForegroundColor Yellow
    $containerArgs = ""
}
else {
    Write-Host "Contenedores identificados para monitorizacion:" -ForegroundColor Green
    foreach ($c in $targetContainers) {
        Write-Host "  - $c" -ForegroundColor Cyan
    }
    $containerArgs = $targetContainers -join " "
}

if ($CsvExportPath) {
    $parent = Split-Path -Parent $CsvExportPath
    if ($parent -and (-not (Test-Path $parent))) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    "timestamp,container,cpu_percent,mem_usage,mem_percent,net_io" | Out-File -FilePath $CsvExportPath -Encoding UTF8
    Write-Host "`nExportando metricas continuas a: $CsvExportPath" -ForegroundColor Green

    while ($true) {
        $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        $stats = docker stats --no-stream --format "$ts,{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}}" $targetContainers
        $stats | Out-File -FilePath $CsvExportPath -Append -Encoding UTF8
        Start-Sleep -Seconds 1
    }
}
else {
    # Modo interactivo nativo
    if ($targetContainers.Count -gt 0) {
        docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" $targetContainers
    }
    else {
        docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
    }
}
