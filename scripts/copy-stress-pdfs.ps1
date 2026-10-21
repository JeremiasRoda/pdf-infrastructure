<#
.SYNOPSIS
    Script de Importacion de PDFs de Estres para Benchmarks (k6 / Vegeta).
    Catedra: Desarrollo de Software - UTN FR San Rafael.
.DESCRIPTION
    Copia los 4 PDFs desde el monolito '../pdf-extractext/tests/stress/pdfs' hacia './load-tests/pdfs/'.
    Si el monolito aun no esta clonado, genera 4 PDFs validos de prueba para habilitar la ejecucion inmediata.
#>

[CmdletBinding()]
param (
    [string]$SourceDir = "",
    [string]$TargetDir = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$rootDir = (Resolve-Path "$scriptDir\..").Path

if (-not $TargetDir) {
    $TargetDir = Join-Path $rootDir "load-tests\pdfs"
}
if (-not $SourceDir) {
    $parentDir = Split-Path -Parent $rootDir
    $SourceDir = Join-Path $parentDir "pdf-extractext\tests\stress\pdfs"
}

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "    UTN FRSR - IMPORTACION DE DATASET DE PDFS PARA BENCHMARK          " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Directorio destino: $TargetDir" -ForegroundColor Green
Write-Host "Buscando dataset en: $SourceDir" -ForegroundColor Yellow

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

function Generar-PdfMinimo {
    param (
        [string]$RutaArchivo,
        [string]$Texto
    )
    $len = $Texto.Length + 40
    $plantilla = @'
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>
endobj
4 0 obj
<< /Length __LEN__ >>
stream
BT
/F1 12 Tf
72 712 Td
(__TEXTO__) Tj
ET
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000214 00000 n 
trailer
<< /Size 5 /Root 1 0 R >>
startxref
310
%%EOF
'@
    $contenido = $plantilla.Replace('__LEN__', $len.ToString()).Replace('__TEXTO__', $Texto)
    [System.IO.File]::WriteAllText($RutaArchivo, $contenido, [System.Text.Encoding]::ASCII)
}

$pdfSourceFound = $false
if (Test-Path $SourceDir) {
    $archivos = Get-ChildItem -Path $SourceDir -Filter "*.pdf"
    if ($archivos.Count -gt 0) {
        $pdfSourceFound = $true
        Write-Host "OK: Se encontraron $($archivos.Count) archivos PDF en el origen." -ForegroundColor Green
        foreach ($archivo in $archivos) {
            Copy-Item -Path $archivo.FullName -Destination $TargetDir -Force
            Write-Host "  -> Copiado: $($archivo.Name)" -ForegroundColor Cyan
        }

        # Asegurar nombres normalizados doc1.pdf .. doc4.pdf
        $idx = 1
        foreach ($archivo in $archivos) {
            $destName = "doc$idx.pdf"
            Copy-Item -Path $archivo.FullName -Destination (Join-Path $TargetDir $destName) -Force
            Write-Host "  -> Normalizado como: $destName" -ForegroundColor Green
            $idx++
            if ($idx -gt 4) { break }
        }
        Write-Host "`nEXITO: Archivos copiados y normalizados en $TargetDir." -ForegroundColor Green
    }
}

if (-not $pdfSourceFound) {
    Write-Host "AVISO: No se encontro la carpeta '$SourceDir' o no contenia archivos PDF." -ForegroundColor Yellow
    Write-Host "Generando 4 PDFs sinteticos validos para permitir ejecucion inmediata de k6 y Vegeta..." -ForegroundColor Yellow

    Generar-PdfMinimo -RutaArchivo (Join-Path $TargetDir "doc1.pdf") -Texto "Documento 1 - UTN FRSR Carga Baseline"
    Generar-PdfMinimo -RutaArchivo (Join-Path $TargetDir "doc2.pdf") -Texto "Documento 2 - UTN FRSR Prueba Spike Concurrente"
    Generar-PdfMinimo -RutaArchivo (Join-Path $TargetDir "doc3.pdf") -Texto "Documento 3 - UTN FRSR Procesamiento Intensivo"
    Generar-PdfMinimo -RutaArchivo (Join-Path $TargetDir "doc4.pdf") -Texto "Documento 4 - UTN FRSR Tolerancia a Fallos"

    Write-Host "OK: Se crearon exitosamente doc1.pdf, doc2.pdf, doc3.pdf y doc4.pdf en $TargetDir." -ForegroundColor Green
    Write-Host "Nota: Cuando clones '../pdf-extractext', vuelve a ejecutar este script para usar los PDFs oficiales." -ForegroundColor Cyan
}

Write-Host "`nArchivos presentes en ${TargetDir}:" -ForegroundColor Yellow
Get-ChildItem -Path $TargetDir -Filter "*.pdf" | Format-Table Name, Length, LastWriteTime
Write-Host "======================================================================" -ForegroundColor Cyan
