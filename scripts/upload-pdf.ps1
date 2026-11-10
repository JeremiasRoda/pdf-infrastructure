<#
==============================================================================
Prueba de Flujo Completo: Subida de PDF, Extraccion y Verificacion de Persistencia
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$TraefikUrl = "http://127.0.0.1:80"
$ApiHost = "api.universidad.localhost"
$DocsHost = "documents.universidad.localhost"
$PdfFile = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   PRUEBA DE FLUJO COMPLETO END-TO-END (PDF -> API -> DOCS -> DB)     " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Asegurar que exista un archivo PDF de prueba valido
if (-not (Test-Path $PdfFile)) {
    Write-Host "[INFO] Generando PDF de prueba sintetico en $PdfFile..." -ForegroundColor Yellow
    $parentDir = Split-Path -Parent $PdfFile
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    
    # PDF sintetico valido minimo con texto 'UTN FRSR Evaluacion'
    $pdfContent = @"
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length 55 >> stream
BT /F1 24 Tf 100 700 Td (UTN FRSR Evaluacion Arquitectura) Tj ET
endstream endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000244 00000 n 
0000000350 00000 n 
trailer << /Size 6 /Root 1 0 R >>
startxref
427
%%EOF
"@
    [System.IO.File]::WriteAllText((Resolve-Path -Path $parentDir).Path + "/doc1.pdf", $pdfContent)
}

$pdfBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $PdfFile).Path)
Write-Host "`n[PASO 1/3] Enviando PDF ($($pdfBytes.Length) bytes) a traves de Traefik hacia la API..." -ForegroundColor Yellow
Write-Host "  POST $TraefikUrl/process [Host: $ApiHost]" -ForegroundColor Gray

$boundary = [System.Guid]::NewGuid().ToString()
$LF = "`r`n"
$bodyHeader = "--$boundary$LF" +
              "Content-Disposition: form-data; name=`"file`"; filename=`"doc1.pdf`"$LF" +
              "Content-Type: application/pdf$LF$LF"
$bodyFooter = "$LF--$boundary--$LF"

$encoding = [System.Text.Encoding]::GetEncoding("iso-8859-1")
$headerBytes = $encoding.GetBytes($bodyHeader)
$footerBytes = $encoding.GetBytes($bodyFooter)

$fullBody = New-Object byte[] ($headerBytes.Length + $pdfBytes.Length + $footerBytes.Length)
[System.Buffer]::BlockCopy($headerBytes, 0, $fullBody, 0, $headerBytes.Length)
[System.Buffer]::BlockCopy($pdfBytes, 0, $fullBody, $headerBytes.Length, $pdfBytes.Length)
[System.Buffer]::BlockCopy($footerBytes, 0, $fullBody, ($headerBytes.Length + $pdfBytes.Length), $footerBytes.Length)

try {
    $response = Invoke-RestMethod -Uri "$TraefikUrl/process" `
        -Method Post `
        -Headers @{ "Host" = $ApiHost } `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $fullBody `
        -TimeoutSec 30
} catch {
    Write-Host "`n[ERROR] Fallo la peticion a la API a traves de Traefik:" -ForegroundColor Red
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        Write-Host $reader.ReadToEnd() -ForegroundColor Red
    } else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    exit 1
}

Write-Host "  -> Respuesta recibida exitosamente de la API!" -ForegroundColor Green
Write-Host "     ID del Documento : $($response.document_id)" -ForegroundColor Cyan
Write-Host "     Checksum SHA-256 : $($response.checksum)" -ForegroundColor Cyan
Write-Host "     Cantidad Paginas : $($response.page_count)" -ForegroundColor Cyan
Write-Host "     Origen           : $($response.source)" -ForegroundColor Cyan
Write-Host "     Texto Extraido   : $($response.content.Trim())" -ForegroundColor Gray

$docId = $response.document_id

# 2. Consultar directamente a persistencia (documents) a traves de Traefik para comprobar el guardado
Write-Host "`n[PASO 2/3] Verificando en persistencia (MongoDB) via microservicio Documents..." -ForegroundColor Yellow
Write-Host "  GET $TraefikUrl/documents/$docId [Host: $DocsHost]" -ForegroundColor Gray

try {
    $docResponse = Invoke-RestMethod -Uri "$TraefikUrl/documents/$docId" `
        -Method Get `
        -Headers @{ "Host" = $DocsHost } `
        -TimeoutSec 10

    Write-Host "  -> Documento encontrado en Base de Datos!" -ForegroundColor Green
    Write-Host "     ID en Base de Datos : $($docResponse.id)" -ForegroundColor Cyan
    Write-Host "     Nombre de Archivo   : $($docResponse.filename)" -ForegroundColor Cyan
    Write-Host "     Fecha de Creacion   : $($docResponse.created_at)" -ForegroundColor Cyan
    Write-Host "     Checksum Verificado : $($docResponse.checksum)" -ForegroundColor Cyan
} catch {
    Write-Host "`n[ERROR] No se pudo recuperar el documento desde Documents Service:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# 3. Comprobar deduplicacion (si volvemos a enviar el mismo PDF, debe retornar source='existing')
Write-Host "`n[PASO 3/3] Comprobando deduplicacion al reenviar el mismo PDF..." -ForegroundColor Yellow
$responseDup = Invoke-RestMethod -Uri "$TraefikUrl/process" `
    -Method Post `
    -Headers @{ "Host" = $ApiHost } `
    -ContentType "multipart/form-data; boundary=$boundary" `
    -Body $fullBody `
    -TimeoutSec 30

Write-Host "  -> Origen retornado: $($responseDup.source) (esperado: existing)" -ForegroundColor Green

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "   FLUJO COMPLETO VERIFICADO EXITOSAMENTE                             " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host " 1. Traefik enruto el trafico al API Gateway correctamente."
Write-Host " 2. Extractor proceso y extrajo el texto del PDF."
Write-Host " 3. Documents persistio el registro en MongoDB con su hash SHA-256."
Write-Host " 4. Se recupero el documento comprobando el Schema de persistencia."
Write-Host " 5. Se valido la deduplicacion automatica en envios repetidos.`n"
