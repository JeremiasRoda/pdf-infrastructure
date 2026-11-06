<#
==============================================================================
Demostración de Resiliencia y Alta Disponibilidad
Cátedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$TargetHost = "extractor.universidad.localhost"
$TraefikUrl = "http://127.0.0.1:80"
$TestPdf = "load-tests/pdfs/doc1.pdf"
$BurstCount = 20

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - DEMOSTRACIÓN DE TOLERANCIA A FALLOS Y RESILIENCIA       " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Verificar Traefik
try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3
    Write-Host "[OK] Traefik v3 activo y escuchando." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Traefik no responde en 127.0.0.1:8080. Inicie con 'docker compose up -d'." -ForegroundColor Red
    exit 1
}

# 2. Asegurar fixture PDF
if (-not (Test-Path $TestPdf)) {
    $parent = Split-Path -Parent $TestPdf
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $pdfMinimal = @"
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
endobj
xref
0 4
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
trailer
<< /Size 4 /Root 1 0 R >>
startxref
190
%%EOF
"@
    [System.IO.File]::WriteAllText($TestPdf, $pdfMinimal)
}

$initialContainers = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
$initialCount = $initialContainers.Count
if ($initialCount -lt 3) { $initialCount = 3 }

try {
    if ($initialContainers.Count -lt 2) {
        Write-Host "Escalando a 3 réplicas base para pruebas..." -ForegroundColor Yellow
        docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor | Out-Null
        Start-Sleep -Seconds 3
        $initialContainers = (docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    }

    Write-Host "Instancias activas de extractor: $($initialContainers.Count)" -ForegroundColor Green

    # Inyección de Falla
    $victimId = $initialContainers[0]
    $victimName = (docker inspect -f '{{.Name}}' $victimId).TrimStart('/')
    Write-Host "`n[INYECCIÓN DE FALLA] Deteniendo réplica $victimName con 'docker stop'..." -ForegroundColor Yellow

    $stopJob = Start-Job -ScriptBlock {
        param($cid)
        docker stop $cid | Out-Null
    } -ArgumentList $victimId

    Write-Host "Enviando ráfaga de $BurstCount extracciones reales hacia Traefik..." -ForegroundColor Yellow
    $okCount = 0
    $failCount = 0

    for ($i = 1; $i -le $BurstCount; $i++) {
        $httpCode = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "$TraefikUrl/extract" `
            -H "Host: $TargetHost" `
            -H "Content-Type: application/pdf" `
            -H "X-Filename: resilience_test.pdf" `
            --data-binary "@$TestPdf"

        if ($httpCode -eq "200") {
            $okCount++
            Write-Host -NoNewline "." -ForegroundColor Green
        } else {
            $failCount++
            Write-Host -NoNewline "X($httpCode)" -ForegroundColor Red
        }
        Start-Sleep -Milliseconds 60
    }
    Write-Host ""

    Receive-Job -Job $stopJob -Wait | Out-Null
    Remove-Job -Job $stopJob -Force | Out-Null

    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "                        REPORTE DE RESILIENCIA                        " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "Total de solicitudes enviadas: $BurstCount"
    Write-Host "Respuestas exitosas (200 OK):  $okCount" -ForegroundColor Green
    Write-Host "Solicitudes fallidas:          $failCount" -ForegroundColor Red

    if ($failCount -eq 0) {
        Write-Host "`n✔ ÉXITO TOTAL: 100% de peticiones atendidas sin degradación por el clúster." -ForegroundColor Green
    } else {
        Write-Host "`n✘ HUBO FALLAS ($failCount solicitudes caídas). Verifique middleware de reintentos." -ForegroundColor Red
        exit 1
    }

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "                    RESTAURANDO ESTADO DEL CLÚSTER                    " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$initialCount" extractor 2>$null | Out-Null
    Write-Host "[OK] Clúster restablecido a $initialCount réplicas saludables." -ForegroundColor Green
}
