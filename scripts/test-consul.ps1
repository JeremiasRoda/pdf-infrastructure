<#
==============================================================================
Suite de Pruebas Automatizadas de HashiCorp Consul y Traefik v3.6
Catedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$ConsulApi = "http://127.0.0.1:8500"
$TraefikApi = "http://127.0.0.1:8080"
$TestPdf = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - SUITE DE VALIDACION AUTOMATIZADA: HASHICORP CONSUL (PS) " -ForegroundColor Cyan
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

$initialExtractors = (docker compose -f docker-compose.integration.yml ps -q extractor 2>$null) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
$initialCount = $initialExtractors.Count

if ($initialCount -eq 0) {
    Write-Host "[AVISO] No se detecto un entorno de integracion iniciado." -ForegroundColor Yellow
    Write-Host "Debe iniciar previamente el cluster con: docker compose -f docker-compose.integration.yml up -d" -ForegroundColor Cyan
    Write-Host "La prueba no modificara el entorno y finaliza sin realizar cambios."
    exit 1
}

function Wait-Condition {
    param(
        [string]$Description,
        [int]$TimeoutSec,
        [scriptblock]$CheckScript
    )
    Write-Host "Esperando: $Description (timeout ${TimeoutSec}s)..."
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        try {
            if (& $CheckScript) {
                return $true
            }
        } catch { }
        Start-Sleep -Seconds 1
        $elapsed++
    }
    Write-Host "[TIMEOUT] Condicion no alcanzada tras ${TimeoutSec}s: $Description" -ForegroundColor Red
    return $false
}

# Asegurar fixture PDF con offsets exactos (183 bytes)
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

try {
    # --------------------------------------------------------------------------
    # TEST 1: Salud de Consul y Registro Inicial con IPs Individuales
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 1] Verificando salud del servidor Consul y registro inicial..." -ForegroundColor Yellow

    try {
        $leader = (Invoke-WebRequest -Uri "$ConsulApi/v1/status/leader" -UseBasicParsing -TimeoutSec 3).Content.Trim('"', "`r", "`n", " ")
    } catch {
        $leader = ""
    }

    if ([string]::IsNullOrWhiteSpace($leader)) {
        Write-Host "[ERROR] Consul no esta disponible o no tiene lider electo en $ConsulApi." -ForegroundColor Red
        exit 1
    }
    Write-Host "Consul activo con lider electo: $leader" -ForegroundColor Green

    $servicesRaw = (Invoke-WebRequest -Uri "$ConsulApi/v1/agent/services" -UseBasicParsing).Content
    $servicesObj = $servicesRaw | ConvertFrom-Json

    foreach ($svc in @("extractor", "documents", "api")) {
        $found = $false
        foreach ($prop in $servicesObj.PSObject.Properties) {
            if ($prop.Value.Service -eq $svc) {
                $found = $true
                break
            }
        }
        if ($found) {
            Write-Host "  OK: Servicio registrado en catalogo: $svc" -ForegroundColor Green
        } else {
            Write-Host "  ERROR: Servicio NO encontrado en catalogo: $svc" -ForegroundColor Red
            exit 1
        }
    }

    # Validar IPs propias
    foreach ($prop in $servicesObj.PSObject.Properties) {
        $addr = $prop.Value.Address
        if ($addr -in @("127.0.0.1", "localhost", "extractor")) {
            Write-Host "[ERROR] Direccion generica detectada en $($prop.Name): $addr" -ForegroundColor Red
            exit 1
        }
        Write-Host "  OK: Instancia $($prop.Name) con IP de red propia: $addr" -ForegroundColor Cyan
    }

    # --------------------------------------------------------------------------
    # TEST 2: Escalado Dinamico a 5 Replicas y Descubrimiento en Traefik
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 2] Evaluando escalado horizontal del Extractor a 5 replicas..." -ForegroundColor Yellow
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=5 extractor | Out-Null

    $consul5Ready = Wait-Condition "Consul registra exactamente 5 replicas passing de extractor" 20 {
        $r = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
        return ($r.Count -eq 5)
    }

    if (-not $consul5Ready) {
        Write-Host "FALLO: Se esperaban exactamente 5 instancias saludables en Consul." -ForegroundColor Red
        exit 1
    }

    $healthResp = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
    $instanceCount = $healthResp.Count
    Write-Host "Instancias saludables de 'extractor' en Consul: $instanceCount / 5" -ForegroundColor Green

    # Validar 5 IDs unicos de instancia
    $serviceIds = $healthResp | ForEach-Object { $_.Service.ID } | Select-Object -Unique
    if ($serviceIds.Count -ne 5) {
        Write-Host "FALLO: Los IDs de las instancias no son unicos ($($serviceIds.Count) unicos de 5)." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: 5 IDs unicos verificados: $($serviceIds -join ', ')" -ForegroundColor Green

    # Validar 5 IPs individuales distintas en pdf-network
    $serviceIps = $healthResp | ForEach-Object { $_.Service.Address } | Select-Object -Unique
    if ($serviceIps.Count -ne 5) {
        Write-Host "FALLO: Las IPs registradas no son individuales o presentan duplicados ($($serviceIps.Count) unicas de 5)." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: 5 IPs individuales verificadas: $($serviceIps -join ', ')" -ForegroundColor Green

    # Verificar que Traefik v3 detecto exactamente las 5 instancias en su pool de servidores
    $traefik5Ready = Wait-Condition "Traefik detecta exactamente 5 backends en extractor@consulcatalog" 20 {
        $svc = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services/extractor@consulcatalog" -UseBasicParsing).Content | ConvertFrom-Json
        return ($svc.loadBalancer.servers.Count -eq 5)
    }

    if (-not $traefik5Ready) {
        Write-Host "FALLO: Traefik no detecto exactamente 5 backends activos." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Traefik v3 balancea exactamente sobre 5 backends saludables." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # TEST 3: Baja Controlada (Detencion de Replica y Retiro del Catalogo)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 3] Evaluando baja controlada y retiro de catalogo al detener replica..." -ForegroundColor Yellow
    $allExtractors = (docker compose -f docker-compose.integration.yml ps -q extractor) -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $victimId = $allExtractors[0]
    $victimShort = $victimId.Substring(0, 12)
    $victimName = (docker inspect -f '{{.Name}}' $victimId).TrimStart('/')

    Write-Host "Deteniendo contenedor replica $victimName ($victimShort)..." -ForegroundColor Yellow
    docker stop $victimId | Out-Null

    $consul4Ready = Wait-Condition "Consul actualiza a exactamente 4 replicas passing tras detencion" 15 {
        $r = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
        return ($r.Count -eq 4)
    }

    if (-not $consul4Ready) {
        Write-Host "FALLO: Consul no redujo a 4 instancias passing tras detener la replica." -ForegroundColor Red
        exit 1
    }
    Write-Host "Instancias saludables restantes en Consul: 4 / 4" -ForegroundColor Green

    $traefik4Ready = Wait-Condition "Traefik reduce a exactamente 4 backends activos" 15 {
        $svc = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services/extractor@consulcatalog" -UseBasicParsing).Content | ConvertFrom-Json
        return ($svc.loadBalancer.servers.Count -eq 4)
    }

    if (-not $traefik4Ready) {
        Write-Host "FALLO: Traefik no redujo a 4 backends activos tras la baja de la replica." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Traefik v3 redujo su pool a exactamente 4 servidores activos." -ForegroundColor Green

    # Peticion de prueba a traves de Traefik
    $extractCode = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:80/extract" `
        -H "Host: extractor.universidad.localhost" `
        -H "Content-Type: application/pdf" `
        -H "X-Filename: consul_test.pdf" `
        --data-binary "@$TestPdf"

    if ($extractCode -eq "200") {
        Write-Host "OK: Alta Disponibilidad: Extraccion exitosa (HTTP 200 OK) a traves de replicas sobrevivientes." -ForegroundColor Green
    } else {
        Write-Host "ERROR: Error al invocar /extract durante la baja (HTTP $extractCode)." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 4: Recuperacion y Auto-Registro de Replica Reiniciada
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 4] Evaluando recuperacion y auto-registro de replica iniciada..." -ForegroundColor Yellow
    docker start $victimId | Out-Null

    $consulRecoverReady = Wait-Condition "Consul vuelve a detectar 5 replicas passing tras reinicio" 20 {
        $r = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
        return ($r.Count -eq 5)
    }

    if (-not $consulRecoverReady) {
        Write-Host "FALLO: La replica reiniciada no alcanzo estado passing en Consul." -ForegroundColor Red
        exit 1
    }

    $traefikRecoverReady = Wait-Condition "Traefik vuelve a balancear sobre exactamente 5 backends" 20 {
        $svc = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services/extractor@consulcatalog" -UseBasicParsing).Content | ConvertFrom-Json
        return ($svc.loadBalancer.servers.Count -eq 5)
    }

    if (-not $traefikRecoverReady) {
        Write-Host "FALLO: Traefik no reincorporo los 5 backends activos." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Replica $victimShort recuperada y reintegrada a Consul y Traefik (5 backends activos)." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # TEST 5: Reinicio de Consul y Reconciliacion
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 5] Evaluando persistencia y reconciliacion tras reinicio de Consul..." -ForegroundColor Yellow
    Write-Host "Reiniciando servicio 'consul' mediante Docker Compose..." -ForegroundColor Yellow
    docker compose -f docker-compose.integration.yml restart consul | Out-Null

    $leaderRecovered = Wait-Condition "Consul recupera lider electo tras reinicio" 25 {
        try {
            $l = (Invoke-WebRequest -Uri "$ConsulApi/v1/status/leader" -UseBasicParsing -TimeoutSec 2).Content.Trim('"', "`r", "`n", " ")
            return (-not [string]::IsNullOrWhiteSpace($l))
        } catch { return $false }
    }

    if (-not $leaderRecovered) {
        Write-Host "FALLO: Consul no eligio lider tras reinicio." -ForegroundColor Red
        exit 1
    }

    $registratorReconciled = Wait-Condition "Registrator reconcilia las 5 replicas en Consul" 25 {
        $r = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
        return ($r.Count -eq 5)
    }

    if (-not $registratorReconciled) {
        Write-Host "FALLO: Registrator no reconcilio las 5 replicas en Consul tras el reinicio." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK: Registrator reconcilio exitosamente las 5 replicas tras el reinicio de Consul." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # TEST 6: Ausencia de Routers Duplicados en Traefik API
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 6] Validando ausencia de colision/duplicacion de routers en Traefik..." -ForegroundColor Yellow
    $routersRaw = (Invoke-WebRequest -Uri "$TraefikApi/api/http/routers" -UseBasicParsing).Content

    if ($routersRaw -match 'extractor@docker') {
        Write-Host "FALLO: Se detecto router duplicado 'extractor@docker'." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "OK: Ausencia de routers duplicados: 'extractor' proviene exclusivamente de Consul Catalog." -ForegroundColor Green
    }

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "  OK: HASHICORP CONSUL CATALOG INTEGRADO Y VERIFICADO EXITOSAMENTE (PS)" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "                    RESTAURANDO ESTADO DEL CLUSTER                    " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "Restableciendo el cluster a exactamente $initialCount replicas originales..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$initialCount" extractor 2>$null | Out-Null
    Write-Host "OK: Cluster restablecido a $initialCount replicas de extractor." -ForegroundColor Green
}
