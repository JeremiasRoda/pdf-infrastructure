<#
==============================================================================
Suite de Validacion Minima de Conectividad Inter-Servicios y Red Compartida (PS)
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$ComposeFile = "docker-compose.integration.yml"
$TraefikApi = "http://127.0.0.1:8080"
$NetworkName = "pdf-network"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - VALIDACION DE CONECTIVIDAD INTER-SERVICIOS Y RED (PS)  " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# COMPROBACION PREVIA: Verificar entorno de integracion
# ------------------------------------------------------------------------------
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker offline" }
} catch {
    Write-Host "[ERROR] El daemon de Docker no esta en ejecucion." -ForegroundColor Red
    Write-Host "Inicie Docker y el entorno de integracion antes de ejecutar esta prueba."
    exit 1
}

$runningContainers = (docker compose -f $ComposeFile ps -q 2>$null) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
if ($runningContainers.Count -eq 0) {
    Write-Host "[AVISO] No se detecto un entorno de integracion iniciado." -ForegroundColor Yellow
    Write-Host "Debe iniciar previamente el cluster con: docker compose -f $ComposeFile up -d" -ForegroundColor Cyan
    Write-Host "La prueba no modificara el entorno y se detiene aqui."
    exit 1
}

# ------------------------------------------------------------------------------
# 1. Verificacion de conexion a 'pdf-network' para todos los servicios
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 1] Verificando adhesion de contenedores a la red '$NetworkName'..." -ForegroundColor Yellow
$servicesToCheck = @("traefik", "consul", "consul-registrator", "extractor", "documents", "api", "mongodb")

foreach ($svc in $servicesToCheck) {
    $cids = (docker compose -f $ComposeFile ps -q $svc 2>$null) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    if ($cids.Count -eq 0) {
        Write-Host "  ERROR: Servicio '$svc' no tiene contenedores activos." -ForegroundColor Red
        exit 1
    }
    foreach ($cid in $cids) {
        $cname = (docker inspect -f '{{.Name}}' $cid).TrimStart('/')
        $netRaw = docker inspect -f "{{range `$k, `$v := .NetworkSettings.Networks}}{{if eq `$k `"$NetworkName`"}}found{{end}}{{end}}" $cid
        if ($netRaw -match "found") {
            $ip = docker inspect -f "{{with index .NetworkSettings.Networks `"$NetworkName`"}}{{.IPAddress}}{{end}}" $cid
            Write-Host "  OK: $cname conectado a $NetworkName (IP: $ip)" -ForegroundColor Green
        } else {
            Write-Host "  ERROR: $cname NO esta conectado a $NetworkName." -ForegroundColor Red
            exit 1
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Resolucion DNS de 'extractor' y 'documents' desde 'api'
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 2] Verificando resolucion DNS interna desde el contenedor 'api'..." -ForegroundColor Yellow
$pyDns = @'
import socket
for target in ["extractor", "documents"]:
    try:
        ip = socket.gethostbyname(target)
        print(f"  OK: {target} -> {ip}")
    except Exception as e:
        print(f"  ERROR: {target} -> {e}")
        exit(1)
'@
docker compose -f $ComposeFile exec -T api python -c $pyDns
if ($LASTEXITCODE -ne 0) {
    Write-Host "FALLO: Error en resolucion DNS desde 'api'." -ForegroundColor Red
    exit 1
}
Write-Host "OK: Resolucion DNS interna Docker (127.0.0.11) operativa desde 'api'." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Alcance de Endpoints de Readiness desde 'api'
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 3] Verificando que 'api' alcanza los endpoints de readiness..." -ForegroundColor Yellow
$pyReadiness = @'
import urllib.request, sys
targets = {
    "extractor": "http://extractor:8000/health/ready",
    "documents": "http://documents:8000/health/ready"
}
for name, url in targets.items():
    try:
        req = urllib.request.urlopen(url, timeout=5)
        code = req.getcode()
        print(f"  OK: {name} ({url}) respondio HTTP {code}")
    except urllib.error.HTTPError as e:
        print(f"  OK: {name} ({url}) respondio HTTP {e.code}")
    except Exception as e:
        print(f"  FALLO: {name} ({url}) inalcanzable: {e}")
        sys.exit(1)
'@
docker compose -f $ComposeFile exec -T api python -c $pyReadiness
if ($LASTEXITCODE -ne 0) {
    Write-Host "FALLO: Error de conectividad HTTP hacia endpoints de readiness." -ForegroundColor Red
    exit 1
}
Write-Host "OK: Conectividad HTTP de readiness confirmada entre microservicios." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 4. Conexion TCP de 'documents' hacia 'mongodb:27017'
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 4] Verificando conexion TCP desde 'documents' hacia 'mongodb:27017'..." -ForegroundColor Yellow
$pyMongo = @'
import socket, sys
try:
    sock = socket.create_connection(("mongodb", 27017), timeout=5)
    sock.close()
    print("  OK: documents -> mongodb:27017 conexion TCP establecida exitosamente.")
except Exception as e:
    print(f"  FALLO: Error de conexion hacia mongodb:27017: {e}")
    sys.exit(1)
'@
docker compose -f $ComposeFile exec -T documents python -c $pyMongo
if ($LASTEXITCODE -ne 0) {
    Write-Host "FALLO: Error de conexion TCP hacia MongoDB." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 5. Deteccion de los 3 Servicios en Traefik mediante Consul Catalog
# ------------------------------------------------------------------------------
Write-Host "`n[PASO 5] Verificando catalogo de servicios en Traefik v3 (Consul Catalog)..." -ForegroundColor Yellow
$traefikServicesRaw = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services" -UseBasicParsing).Content

foreach ($svc in @("extractor@consulcatalog", "documents@consulcatalog", "api@consulcatalog")) {
    if ($traefikServicesRaw -match [regex]::Escape($svc)) {
        Write-Host "  OK: Servicio detectado en Traefik Ingress: $svc" -ForegroundColor Green
    } else {
        Write-Host "  FALLO: Servicio NO detectado en Traefik Ingress: $svc" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "  OK: VALIDACION DE CONECTIVIDAD COMPLETADA CON EXITO (PS)            " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
