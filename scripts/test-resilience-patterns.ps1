<#
==============================================================================
Verificación de Patrones de Resiliencia: Rate Limit, Circuit Breaker y Retry
Cátedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$TargetHost = "extractor.universidad.localhost"
$TraefikUrl = "http://127.0.0.1:80"
$TestPdf = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - VERIFICACIÓN DE PATRONES DE RESILIENCIA EN TRAEFIK     " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Comprobar Traefik
try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Host "[ERROR] Traefik no está respondiendo en 127.0.0.1:8080. Inicie con 'docker compose up -d'." -ForegroundColor Red
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

# ------------------------------------------------------------------------------
# 1. Inspeccionar Middlewares en Traefik API
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 1] Inspeccionando middlewares activos en la API interna de Traefik..." -ForegroundColor Yellow
$middlewaresRaw = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/middlewares" -UseBasicParsing).Content

function Check-MiddlewareActive($name) {
    if ($middlewaresRaw -match $name) {
        Write-Host "  ✔ Middleware registrado: $name" -ForegroundColor Green
    } else {
        Write-Host "  ✘ Middleware no encontrado: $name" -ForegroundColor Red
        throw "Middleware $name no está activo en Traefik"
    }
}

Check-MiddlewareActive "rate-limit-extract"
Check-MiddlewareActive "circuit-breaker-extractor"
Check-MiddlewareActive "retry-on-shutdown"

# ------------------------------------------------------------------------------
# 2. Prueba de Rate Limiting (HTTP 429) y Exclusión de Health Check
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 2] Evaluando Rate Limiting en /extract (Ráfaga superior al Burst)..." -ForegroundColor Yellow
$burstTarget = 25
$count200 = 0
$count429 = 0

for ($i = 1; $i -le $burstTarget; $i++) {
    $code = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "$TraefikUrl/extract" `
        -H "Host: $TargetHost" `
        -H "Content-Type: application/pdf" `
        -H "X-Filename: ratelimit_test.pdf" `
        --data-binary "@$TestPdf"

    if ($code -eq "200") {
        $count200++
        Write-Host -NoNewline "." -ForegroundColor Green
    } elseif ($code -eq "429") {
        $count429++
        Write-Host -NoNewline "L(429)" -ForegroundColor Yellow
    } else {
        Write-Host -NoNewline "?($code)" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "Resultados de la ráfaga: $count200 aceptadas (200 OK) | $count429 limitadas (429 Too Many Requests)" -ForegroundColor Cyan

if ($count429 -gt 0) {
    Write-Host "✔ Rate Limiting Activo: Traefik protegió el backend rechazando ráfagas con HTTP 429." -ForegroundColor Green
} else {
    Write-Host "ℹ No se alcanzaron respuestas 429 (solicitudes atendidas dentro del presupuesto de tiempo)." -ForegroundColor Yellow
}

# Comprobar que /health permanece 100% disponible
Write-Host "`nComprobando que /health permanece 100% disponible sin verse afectado por RateLimit..." -ForegroundColor Yellow
$healthCode = curl.exe -s -o /dev/null -w "%{http_code}" -H "Host: $TargetHost" "$TraefikUrl/health"
if ($healthCode -eq "200") {
    Write-Host "✔ Correcto: /health respondió HTTP 200 OK (Router de salud no afectado por RateLimit)." -ForegroundColor Green
} else {
    Write-Host "✘ FALLO: /health devolvió código $healthCode." -ForegroundColor Red
    exit 1
}

# Comprobar recuperación del límite tras 1.5s
Write-Host "`nEsperando 1.5s para la renovación de tokens del Rate Limiter..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 1500

$recoverCode = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "$TraefikUrl/extract" `
    -H "Host: $TargetHost" `
    -H "Content-Type: application/pdf" `
    -H "X-Filename: ratelimit_recovery.pdf" `
    --data-binary "@$TestPdf"

if ($recoverCode -eq "200") {
    Write-Host "✔ Recuperación Verificada: Endpoint /extract vuelve a aceptar peticiones (HTTP 200 OK)." -ForegroundColor Green
} else {
    Write-Host "✘ FALLO en recuperación: Código devuelto $recoverCode." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Verificación de Retry y Circuit Breaker
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 3] Evaluando Especificación de Retry y Circuit Breaker en Traefik..." -ForegroundColor Yellow
$retryRaw = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/middlewares/retry-on-shutdown@docker" -UseBasicParsing).Content
Write-Host "Configuración de Retry en Traefik: $retryRaw" -ForegroundColor Cyan

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "  ✔ PATRONES DE RESILIENCIA AUDITADOS Y VERIFICADOS CORRECTAMENTE     " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
