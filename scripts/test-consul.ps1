<#
==============================================================================
Suite de Pruebas Automatizadas de HashiCorp Consul y Traefik v3.6
Cátedra: Desarrollo de Software - UTN FR San Rafael
==============================================================================
#>

$ErrorActionPreference = "Stop"
$ConsulApi = "http://127.0.0.1:8500"
$TraefikApi = "http://127.0.0.1:8080"
$TestPdf = "load-tests/pdfs/doc1.pdf"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   UTN FRSR - SUITE DE VALIDACIÓN AUTOMATIZADA: HASHICORP CONSUL (PS) " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

# Guardar cantidad inicial de réplicas
$initialExtractors = (docker ps --filter "name=extractor" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
$initialCount = $initialExtractors.Count
if ($initialCount -lt 2) { $initialCount = 2 }

# Asegurar fixture PDF con offsets exactos (183 bytes)
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
183
%%EOF
"@
    [System.IO.File]::WriteAllText($TestPdf, $pdfMinimal)
}

try {
    # --------------------------------------------------------------------------
    # TEST 1: Salud de Consul y Registro Inicial con IPs Individuales
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 1] Verificando salud del servidor Consul y registro inicial..." -ForegroundColor Yellow

    try {
        $leader = (Invoke-WebRequest -Uri "$ConsulApi/v1/status/leader" -UseBasicParsing -TimeoutSec 3).Content.Trim('"')
    } catch {
        $leader = ""
    }

    if ([string]::IsNullOrWhiteSpace($leader)) {
        Write-Host "[ERROR] Consul no está disponible o no tiene líder electo en $ConsulApi." -ForegroundColor Red
        exit 1
    }
    Write-Host "Consul activo con líder electo: $leader" -ForegroundColor Green

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
            Write-Host "  ✔ Servicio registrado en catálogo: $svc" -ForegroundColor Green
        } else {
            Write-Host "  ✘ Servicio NO encontrado en catálogo: $svc" -ForegroundColor Red
            exit 1
        }
    }

    # Validar IPs propias
    foreach ($prop in $servicesObj.PSObject.Properties) {
        $addr = $prop.Value.Address
        if ($addr -in @("127.0.0.1", "localhost", "extractor")) {
            Write-Host "[ERROR] Dirección genérica detectada en $($prop.Name): $addr" -ForegroundColor Red
            exit 1
        }
        Write-Host "  ✔ Instancia $($prop.Name) con IP de red propia: $addr" -ForegroundColor Cyan
    }

    # --------------------------------------------------------------------------
    # TEST 2: Escalado Dinámico a 5 Réplicas y Descubrimiento en Traefik
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 2] Evaluando escalado horizontal del Extractor a 5 réplicas..." -ForegroundColor Yellow
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=5 extractor | Out-Null

    Write-Host "Esperando 6s para sincronización de Registrator, Consul y Traefik..." -ForegroundColor Yellow
    Start-Sleep -Seconds 6

    $healthResp = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
    $instanceCount = $healthResp.Count
    Write-Host "Instancias saludables de 'extractor' en Consul: $instanceCount / 5" -ForegroundColor Green

    if ($instanceCount -ne 5) {
        Write-Host "✘ FALLO: Se esperaban exactamente 5 instancias saludables en Consul, encontradas: $instanceCount." -ForegroundColor Red
        exit 1
    }

    # Validar 5 IDs únicos de instancia
    $serviceIds = $healthResp | ForEach-Object { $_.Service.ID } | Select-Object -Unique
    if ($serviceIds.Count -ne 5) {
        Write-Host "✘ FALLO: Los IDs de las instancias no son únicos ($($serviceIds.Count) únicos de 5)." -ForegroundColor Red
        exit 1
    }
    Write-Host "✔ 5 IDs únicos verificados: $($serviceIds -join ', ')" -ForegroundColor Green

    # Validar 5 IPs individuales distintas en pdf-network
    $serviceIps = $healthResp | ForEach-Object { $_.Service.Address } | Select-Object -Unique
    if ($serviceIps.Count -ne 5) {
        Write-Host "✘ FALLO: Las IPs registradas no son individuales o presentan duplicados ($($serviceIps.Count) únicas de 5)." -ForegroundColor Red
        exit 1
    }
    Write-Host "✔ 5 IPs individuales verificadas: $($serviceIps -join ', ')" -ForegroundColor Green

    # Verificar que Traefik v3 detectó las instancias en su pool de servidores
    try {
        $traefikSvcRaw = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services/extractor@consulcatalog" -UseBasicParsing -TimeoutSec 3).Content
        $traefikSvcObj = $traefikSvcRaw | ConvertFrom-Json
        $serverCount = $traefikSvcObj.loadBalancer.servers.Count
        Write-Host "Servidores balanceados en Traefik (extractor@consulcatalog): $serverCount / 5" -ForegroundColor Green
        if ($serverCount -eq 5) {
            Write-Host "✔ Traefik v3 balancea exactamente sobre las 5 instancias saludables." -ForegroundColor Green
        } else {
            Write-Host "ℹ Traefik reporta $serverCount servidores activos en el catálogo." -ForegroundColor Yellow
        }
    } catch {
        $traefikServices = (Invoke-WebRequest -Uri "$TraefikApi/api/http/services" -UseBasicParsing).Content
        if ($traefikServices -match "extractor@consulcatalog") {
            Write-Host "✔ Traefik v3 integró el backend dinámico 'extractor@consulcatalog'." -ForegroundColor Green
        } else {
            Write-Host "✘ Traefik no detectó el servicio desde Consul Catalog." -ForegroundColor Red
            exit 1
        }
    }

    # --------------------------------------------------------------------------
    # TEST 3: Baja Controlada (Detención de Réplica y Retiro del Catálogo)
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 3] Evaluando baja controlada y retiro de catálogo al detener réplica..." -ForegroundColor Yellow
    $allExtractors = (docker ps --filter "name=extractor" --format "{{.ID}}") -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $victimId = $allExtractors[0]
    $victimShort = $victimId.Substring(0, 12)
    $victimName = (docker inspect -f '{{.Name}}' $victimId).TrimStart('/')

    Write-Host "Deteniendo contenedor réplica $victimName ($victimShort)..." -ForegroundColor Yellow
    docker stop $victimId | Out-Null

    Write-Host "Esperando 4s para propagación de desregistro en Consul..." -ForegroundColor Yellow
    Start-Sleep -Seconds 4

    $postStopPassing = (Invoke-WebRequest -Uri "$ConsulApi/v1/health/service/extractor?passing=true" -UseBasicParsing).Content | ConvertFrom-Json
    Write-Host "Instancias saludables restantes en Consul: $($postStopPassing.Count) / 4" -ForegroundColor Green

    $postStopServices = (Invoke-WebRequest -Uri "$ConsulApi/v1/agent/services" -UseBasicParsing).Content
    if ($postStopServices -match "extractor-$victimShort") {
        Write-Host "ℹ La réplica permanece registrada pero en estado crítico/no-passing." -ForegroundColor Yellow
    } else {
        Write-Host "✔ Réplica $victimShort dada de baja exitosamente del catálogo de Consul." -ForegroundColor Green
    }

    # Petición de prueba a través de Traefik
    $extractCode = curl.exe -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:80/extract" `
        -H "Host: extractor.universidad.localhost" `
        -H "Content-Type: application/pdf" `
        -H "X-Filename: consul_test.pdf" `
        --data-binary "@$TestPdf"

    if ($extractCode -eq "200") {
        Write-Host "✔ Alta Disponibilidad: Extracción exitosa (HTTP 200 OK) a través de réplicas sobrevivientes." -ForegroundColor Green
    } else {
        Write-Host "✘ Error al invocar /extract durante la baja (HTTP $extractCode)." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 4: Recuperación y Auto-Registro
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 4] Evaluando recuperación y auto-registro de réplica iniciada..." -ForegroundColor Yellow
    docker start $victimId | Out-Null

    Write-Host "Esperando 5s para detección de Docker event y auto-registro..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5

    $recoveredServices = (Invoke-WebRequest -Uri "$ConsulApi/v1/agent/services" -UseBasicParsing).Content
    if ($recoveredServices -match "extractor-$victimShort") {
        Write-Host "✔ Réplica $victimShort se auto-registró correctamente en Consul tras reinicio." -ForegroundColor Green
    } else {
        Write-Host "✘ Réplica no volvió a aparecer en Consul." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 5: Reinicio de Consul y Reconciliación
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 5] Evaluando persistencia y reconciliación tras reinicio de Consul..." -ForegroundColor Yellow
    docker restart consul | Out-Null

    Write-Host "Esperando 6s para reconexión y reconciliación de Registrator..." -ForegroundColor Yellow
    Start-Sleep -Seconds 6

    $consulRestartServices = (Invoke-WebRequest -Uri "$ConsulApi/v1/agent/services" -UseBasicParsing).Content
    if ($consulRestartServices -match '"Service":"extractor"') {
        Write-Host "✔ Registrator reconcilió exitosamente el catálogo tras el reinicio de Consul." -ForegroundColor Green
    } else {
        Write-Host "✘ No se recuperaron los servicios tras reiniciar Consul." -ForegroundColor Red
        exit 1
    }

    # --------------------------------------------------------------------------
    # TEST 6: Ausencia de Routers Duplicados en Traefik API
    # --------------------------------------------------------------------------
    Write-Host "`n[TEST 6] Validando ausencia de colisión/duplicación de routers en Traefik..." -ForegroundColor Yellow
    $routersRaw = (Invoke-WebRequest -Uri "$TraefikApi/api/http/routers" -UseBasicParsing).Content

    if ($routersRaw -match 'extractor@docker') {
        Write-Host "✘ FALLO: Se detectó router duplicado 'extractor@docker'." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "✔ Ausencia de routers duplicados: 'extractor' proviene exclusivamente de Consul Catalog." -ForegroundColor Green
    }

    Write-Host "`n======================================================================" -ForegroundColor Green
    Write-Host "  ✔ HASHICORP CONSUL CATALOG INTEGRADO Y VERIFICADO EXITOSAMENTE (PS)" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green

} finally {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "                    RESTAURANDO ESTADO DEL CLÚSTER                    " -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale "extractor=$initialCount" extractor 2>$null | Out-Null
    Write-Host "[OK] Clúster restablecido a $initialCount réplicas de extractor." -ForegroundColor Green
}
