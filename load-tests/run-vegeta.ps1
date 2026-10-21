<#
.SYNOPSIS
    Benchmark Vegeta - Carga Fija Constante (50 req/s, 30s).
    Cátedra: Desarrollo de Software - UTN FR San Rafael.
.DESCRIPTION
    Ejecuta un ataque de carga con tasa fija de 50 peticiones/segundo durante 30s (1500 solicitudes),
    rotando entre los 4 PDFs del dataset oficial y generando el reporte de percentiles y errores.
#>

[CmdletBinding()]
param (
    [string]$TargetUrl = "http://extractor.universidad.localhost/extract",
    [int]$Rate = 50,
    [string]$Duration = "30s",
    [string]$Timeout = "30s"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$rootDir = (Resolve-Path "$scriptDir\..").Path

$targetsFile = Join-Path $scriptDir "vegeta-targets.txt"
$resultsBin = Join-Path $scriptDir "results.bin"
$reportTxt = Join-Path $scriptDir "report.txt"
$pdfDir = Join-Path $scriptDir "pdfs"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - PRUEBA DE CARGA FIJA VEGETA (50 req/s - 30 segundos)   " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Objetivo:     $TargetUrl" -ForegroundColor Green
Write-Host "Tasa fija:    $Rate req/s" -ForegroundColor Yellow
Write-Host "Duracion:     $Duration (Total: 1500 solicitudes)" -ForegroundColor Yellow
Write-Host "Timeout:      $Timeout" -ForegroundColor Yellow

# Verificar existencia de los PDFs
if (-not (Test-Path (Join-Path $pdfDir "doc1.pdf"))) {
    Write-Host "AVISO: No se encontraron los PDFs de prueba. Generandolos..." -ForegroundColor Yellow
    & "$rootDir\scripts\copy-stress-pdfs.ps1"
}

# Preparar archivo de targets con rutas compatibles con Linux/Docker y Windows
# Para Docker, la ruta dentro del contenedor sera /work/pdfs/docX.pdf
$targetsContent = @"
POST $TargetUrl
Content-Type: application/pdf
@pdfs/doc1.pdf

POST $TargetUrl
Content-Type: application/pdf
@pdfs/doc2.pdf

POST $TargetUrl
Content-Type: application/pdf
@pdfs/doc3.pdf

POST $TargetUrl
Content-Type: application/pdf
@pdfs/doc4.pdf
"@

[System.IO.File]::WriteAllText($targetsFile, $targetsContent.Replace("`r`n", "`n"), [System.Text.Encoding]::ASCII)
Write-Host "OK: Archivo de objetivos configurado con rotacion de 4 PDFs." -ForegroundColor Green

Write-Host "`nIniciando ataque de carga fija durante $Duration..." -ForegroundColor Yellow

$vegetaCmd = Get-Command "vegeta" -ErrorAction SilentlyContinue

if ($vegetaCmd) {
    Write-Host "Ejecutando con binario local 'vegeta'..." -ForegroundColor Cyan
    Push-Location $scriptDir
    try {
        vegeta attack -rate=$Rate -duration=$Duration -timeout=$Timeout -targets="vegeta-targets.txt" | Out-File -FilePath $resultsBin -Encoding Byte
        Write-Host "`n======================================================================" -ForegroundColor Cyan
        Write-Host "                        REPORTE DE VEGETA                             " -ForegroundColor Cyan
        Write-Host "======================================================================" -ForegroundColor Cyan
        Get-Content $resultsBin -Raw -Encoding Byte | vegeta report -type=text | Tee-Object -FilePath $reportTxt
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "Vegeta no esta en el PATH. Ejecutando a traves del contenedor Docker oficial..." -ForegroundColor Yellow
    # Normalizar ruta para montaje en Docker de Windows
    $mountDir = $scriptDir.Replace("\", "/")
    
    # Ejecutar ataque dentro de Docker
    docker run --rm -i `
        --network=pdf-network `
        -v "${scriptDir}:/work" `
        -w /work `
        ghcr.io/tsenart/vegeta:latest `
        attack -rate=$Rate -duration=$Duration -timeout=$Timeout -targets=vegeta-targets.txt > $resultsBin

    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "                        REPORTE DE VEGETA                             " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan

    Get-Content $resultsBin -Raw | docker run --rm -i `
        -v "${scriptDir}:/work" `
        -w /work `
        ghcr.io/tsenart/vegeta:latest `
        report -type=text | Tee-Object -FilePath $reportTxt
}

Write-Host "`nEXITO: Benchmark completado. Reporte guardado en $reportTxt." -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Cyan
