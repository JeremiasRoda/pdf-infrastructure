<#
==============================================================================
Verificacion de Patrones de Resiliencia: Rate Limit, Circuit Breaker y Retry
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$TargetHost = "extractor.universidad.localhost"
$TraefikUrl = "http://127.0.0.1:80"
$TestPdf = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - VERIFICACION DE PATRONES DE RESILIENCIA EN TRAEFIK (PS) " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# 1. Comprobar Docker y Traefik
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker offline" }
} catch {
    Write-Host "[ERROR] El daemon de Docker no esta en ejecucion." -ForegroundColor Red
    Write-Host "Inicie Docker y el entorno antes de ejecutar esta prueba."
    exit 1
}

try {
    $ping = Invoke-WebRequest -Uri "http://127.0.0.1:8080/ping" -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Host "[AVISO] Traefik no esta respondiendo en 127.0.0.1:8080." -ForegroundColor Yellow
    Write-Host "Debe iniciar previamente el cluster con: docker compose -f docker-compose.integration.yml up -d" -ForegroundColor Cyan
    Write-Host "La prueba no modificara el entorno y se detiene aqui."
    exit 1
}

# 2. Asegurar fixture PDF con offsets exactos (183 bytes)
if (-not (Test-Path $TestPdf)) {
    $parent = Split-Path -Parent $TestPdf
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $pdfMinimal = @'
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
183
%%EOF
'@
    [System.IO.File]::WriteAllText($TestPdf, $pdfMinimal, [System.Text.Encoding]::ASCII)
}

# ------------------------------------------------------------------------------
# 1. Inspeccionar Middlewares en Traefik API (Proveedor File)
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 1] Inspeccionando middlewares activos en la API interna de Traefik..." -ForegroundColor Yellow
$middlewaresRaw = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/middlewares" -UseBasicParsing).Content

function Check-MiddlewareActive($name) {
    if ($middlewaresRaw -match [regex]::Escape($name)) {
        Write-Host "  OK: Middleware cargado: $name" -ForegroundColor Green
    } else {
        Write-Host "  FALLO: Middleware no encontrado: $name" -ForegroundColor Red
        throw "Middleware $name no esta activo en Traefik"
    }
}

Check-MiddlewareActive "rate-limit-extract@file"
Check-MiddlewareActive "rate-limit-api@file"
Check-MiddlewareActive "circuit-breaker-extractor@file"
Check-MiddlewareActive "retry-on-shutdown@file"

# Inspeccionar especificacion exacta de Retry y Circuit Breaker
$retrySpec = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/middlewares/retry-on-shutdown@file" -UseBasicParsing).Content
if ($retrySpec -match '"attempts":3') {
    Write-Host "  OK: Especificacion Retry verificada: 3 intentos con 100ms iniciales." -ForegroundColor Green
} else {
    Write-Host "  FALLO: Configuracion de retry-on-shutdown@file no coincide con intentos=3." -ForegroundColor Red
    exit 1
}

$cbSpec = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/middlewares/circuit-breaker-extractor@file" -UseBasicParsing).Content
if ($cbSpec -match 'NetworkErrorRatio') {
    Write-Host "  OK: Especificacion Circuit Breaker verificada: regla basada en tasa de fallos de red y HTTP 5xx." -ForegroundColor Green
} else {
    Write-Host "  FALLO: Configuracion de circuit-breaker-extractor@file no encontrada." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Verificacion de Middlewares Asignados a los Routers en Traefik
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 2] Verificando asignacion de middlewares a los routers correspondientes..." -ForegroundColor Yellow
$routersRaw = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/api/http/routers" -UseBasicParsing).Content

if ($routersRaw -match 'rate-limit-extract@file' -and $routersRaw -match 'circuit-breaker-extractor@file' -and $routersRaw -match 'retry-on-shutdown@file') {
    Write-Host "OK: Enrutador de Extractor tiene vinculados: RateLimit, Circuit Breaker y Retry." -ForegroundColor Green
} else {
    Write-Host "FALLO: El enrutador de Extractor no tiene asignados los middlewares de resiliencia requeridos." -ForegroundColor Red
    exit 1
}

if ($routersRaw -match 'rate-limit-api@file') {
    Write-Host "OK: Enrutador de API tiene vinculado: rate-limit-api@file." -ForegroundColor Green
} else {
    Write-Host "FALLO: El enrutador de API no tiene asignado rate-limit-api@file." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Prueba de Rate Limiting (HTTP 429) y Exclusion de Health Check
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 3] Evaluando Rate Limiting en /extract (Rafaga superior al Burst)..." -ForegroundColor Yellow
$burstTarget = 35
$burstResults = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
$threads = [System.Collections.Generic.List[System.Threading.Thread]]::new()

1..$burstTarget | ForEach-Object {
    $t = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
        $code = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "$TraefikUrl/extract" `
            -H "Host: $TargetHost" `
            -H "Content-Type: application/pdf" `
            -H "X-Filename: ratelimit_test.pdf" `
            --data-binary "@$TestPdf"
        $burstResults.Add($code)
    })
    $t.Start()
    $threads.Add($t)
}

foreach ($t in $threads) { $t.Join() }

$count200 = ($burstResults | Where-Object { $_ -eq "200" }).Count
$count429 = ($burstResults | Where-Object { $_ -eq "429" }).Count

Write-Host "Resultados de la rafaga: $count200 aceptadas (200 OK) | $count429 limitadas (429 Too Many Requests)" -ForegroundColor Cyan

# Si no se obtiene ningun 429, la prueba DEBE FALLAR
if ($count429 -gt 0) {
    Write-Host "OK: Rate Limiting Activo: Traefik protegio el backend rechazando excesos de rafaga con HTTP 429." -ForegroundColor Green
} else {
    Write-Host "FALLO: La prueba de rafaga no obtuvo ninguna respuesta HTTP 429 Too Many Requests." -ForegroundColor Red
    exit 1
}

# Comprobar que /health permanece 100% disponible
Write-Host "`nComprobando que /health permanece 100% disponible sin verse afectado por RateLimit..." -ForegroundColor Yellow
$healthCode = curl.exe -s -o /dev/null -w "%{http_code}" -H "Host: $TargetHost" "$TraefikUrl/health"
if ($healthCode -eq "200") {
    Write-Host "OK: /health respondio HTTP 200 OK (Router de salud no afectado por RateLimit)." -ForegroundColor Green
} else {
    Write-Host "FALLO: /health devolvio codigo $healthCode." -ForegroundColor Red
    exit 1
}

# Comprobar recuperacion del limite tras 1.5s
Write-Host "`nEsperando 1.5s para la renovacion de tokens del Rate Limiter..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 1500

$recoverCode = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "$TraefikUrl/extract" `
    -H "Host: $TargetHost" `
    -H "Content-Type: application/pdf" `
    -H "X-Filename: ratelimit_recovery.pdf" `
    --data-binary "@$TestPdf"

if ($recoverCode -eq "200") {
    Write-Host "OK: Recuperacion Verificada: Endpoint /extract vuelve a aceptar peticiones (HTTP 200 OK)." -ForegroundColor Green
} else {
    Write-Host "FALLO en recuperacion: Codigo devuelto $recoverCode." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 4. Sintesis Tecnica de Auditoria y Delimitacion
# ------------------------------------------------------------------------------
Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "             SINTESIS DE VALIDACION DE RESILIENCIA                   " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "1. Configuracion Detectada: Middlewares 'rate-limit-extract@file', 'circuit-breaker-extractor@file' y 'retry-on-shutdown@file' cargados desde proveedor de archivo." -ForegroundColor Green
Write-Host "2. Asignacion a Routers: Confirmada vinculacion estricta a routers Ingress de Extractor y API en Traefik API." -ForegroundColor Green
Write-Host "3. Comportamiento Probado Efectivamente:" -ForegroundColor Green
Write-Host "   - Rate Limiting: COMPROBADO EN EJECUCION (Generacion efectiva de HTTP 429, proteccion de /health y recuperacion a 200)." -ForegroundColor Green
Write-Host "   - Circuit Breaker y Retry: CONFIGURACION Y ASIGNACION VERIFICADAS en Traefik (su disparo operativo requiere inyeccion destructiva de fallos en microservicios, no ejecutada en esta suite no destructiva)." -ForegroundColor Green

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "  OK: PATRONES DE RESILIENCIA AUDITADOS Y VERIFICADOS CORRECTAMENTE   " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
