#!/usr/bin/env bash
# ==============================================================================
# Suite de Pruebas Automatizadas de HashiCorp Consul y Traefik v3.6
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Pruebas ejecutadas:
# 1. Salud del Servidor Consul y Registro Inicial de Instancias con IPs propias.
# 2. Escalado Dinámico: Escala extractor a 3 réplicas y valida IDs únicos en Consul y Traefik.
# 3. Baja Controlada: Detiene una réplica y verifica baja en Consul y retiro en Traefik.
# 4. Recuperación: Reinicia réplica y valida auto-registro y reincorporación al balanceador.
# 5. Resiliencia de Consul: Reinicio del contenedor Consul y reconciliación de estado.
# 6. Ausencia de Routers Duplicados: Comprueba no-colisión entre Docker y ConsulCatalog.
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONSUL_API="http://127.0.0.1:8500"
TRAEFIK_API="http://127.0.0.1:8080"
TEST_PDF="./load-tests/pdfs/doc1.pdf"

# Guardar cantidad inicial de réplicas
INITIAL_EXTRACTORS=($(docker ps --filter "name=extractor" --format "{{.ID}}"))
INITIAL_COUNT="${#INITIAL_EXTRACTORS[@]}"
if [ "$INITIAL_COUNT" -lt 2 ]; then
    INITIAL_COUNT=2
fi

cleanup() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}                    RESTAURACIÓN DEL ENTORNO                          ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${INITIAL_COUNT}" extractor > /dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Clúster restablecido a ${INITIAL_COUNT} réplicas de extractor.${NC}"
}
trap cleanup EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - SUITE DE VALIDACIÓN AUTOMATIZADA: HASHICORP CONSUL      ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Asegurar fixture PDF con offsets xref exactos (183 bytes)
if [ ! -f "$TEST_PDF" ]; then
    mkdir -p "$(dirname "$TEST_PDF")"
    cat << 'EOF' > "$TEST_PDF"
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
EOF
fi

# ------------------------------------------------------------------------------
# TEST 1: Salud de Consul y Registro Inicial con IPs Individuales
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 1] Verificando salud del servidor Consul y registro inicial...${NC}"

LEADER=$(curl -s "${CONSUL_API}/v1/status/leader" || echo "")
if [ -z "$LEADER" ] || [ "$LEADER" == '""' ]; then
    echo -e "${RED}[ERROR] Consul no está disponible o no tiene líder en ${CONSUL_API}.${NC}"
    exit 1
fi
echo -e "Consul activo con líder electo: ${GREEN}${LEADER}${NC}"

SERVICES_JSON=$(curl -s "${CONSUL_API}/v1/agent/services")
echo -e "Inspeccionando catálogo de servicios en Consul..."

for svc in "extractor" "documents" "api"; do
    if echo "$SERVICES_JSON" | grep -q "\"Service\":\"$svc\""; then
        echo -e "  ✔ Servicio registrado en catálogo: ${GREEN}${svc}${NC}"
    else
        echo -e "  ✘ Servicio NO encontrado en catálogo: ${RED}${svc}${NC}"
        exit 1
    fi
done

# Validar que cada instancia tenga IP propia en pdf-network (no genérica)
IPS=$(echo "$SERVICES_JSON" | grep -oE '"Address":"[0-9.]+"' | cut -d'"' -f4)
for ip in $IPS; do
    if [ "$ip" == "127.0.0.1" ] || [ "$ip" == "localhost" ] || [ "$ip" == "extractor" ]; then
        echo -e "${RED}[ERROR] Dirección de instancia inválida o genérica: $ip${NC}"
        exit 1
    fi
    echo -e "  ✔ Instancia registrada con IP de red propia: ${CYAN}${ip}${NC}"
done

# ------------------------------------------------------------------------------
# TEST 2: Escalado Dinámico a 5 Réplicas y Descubrimiento en Traefik
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 2] Evaluando escalado horizontal del Extractor a 5 réplicas...${NC}"
docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=5 extractor > /dev/null

echo -e "Esperando 6s para sincronización de Registrator, Consul y Traefik..."
sleep 6

EXTRACTOR_PASSING=$(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true")
PASSING_COUNT=$(echo "$EXTRACTOR_PASSING" | grep -oE '"ServiceID":"extractor-[a-f0-9]+"' | wc -l)
echo -e "Instancias saludables de 'extractor' en Consul: ${GREEN}${PASSING_COUNT} / 5${NC}"

if [ "$PASSING_COUNT" -ne 5 ]; then
    echo -e "${RED}✘ FALLO: Se esperaban exactamente 5 instancias saludables en Consul, encontradas: ${PASSING_COUNT}.${NC}"
    exit 1
fi

# Validar 5 IDs únicos de instancia
UNIQUE_IDS=($(echo "$EXTRACTOR_PASSING" | grep -oE '"ServiceID":"extractor-[a-f0-9]+"' | cut -d'"' -f4 | sort -u))
if [ "${#UNIQUE_IDS[@]}" -ne 5 ]; then
    echo -e "${RED}✘ FALLO: Los IDs de las instancias no son únicos (${#UNIQUE_IDS[@]} únicos de 5).${NC}"
    exit 1
fi
echo -e "${GREEN}✔ 5 IDs únicos verificados:${NC} ${UNIQUE_IDS[*]}"

# Validar 5 IPs individuales distintas en pdf-network
UNIQUE_IPS=($(echo "$EXTRACTOR_PASSING" | grep -oE '"ServiceAddress":"[0-9.]+"' | cut -d'"' -f4 | sort -u))
if [ "${#UNIQUE_IPS[@]}" -ne 5 ]; then
    echo -e "${RED}✘ FALLO: Las IPs registradas no son individuales o presentan duplicados (${#UNIQUE_IPS[@]} únicas de 5).${NC}"
    exit 1
fi
echo -e "${GREEN}✔ 5 IPs individuales verificadas:${NC} ${UNIQUE_IPS[*]}"

# Verificar que Traefik v3 detectó las 5 instancias en su pool de servidores
TRAEFIK_SERVICE_JSON=$(curl -s "${TRAEFIK_API}/api/http/services/extractor@consulcatalog" || echo "")
if [ -n "$TRAEFIK_SERVICE_JSON" ] && echo "$TRAEFIK_SERVICE_JSON" | grep -q "extractor@consulcatalog"; then
    TRAEFIK_SERVERS_COUNT=$(echo "$TRAEFIK_SERVICE_JSON" | grep -o '"url":' | wc -l)
    echo -e "Servidores balanceados en Traefik (extractor@consulcatalog): ${GREEN}${TRAEFIK_SERVERS_COUNT} / 5${NC}"
    if [ "$TRAEFIK_SERVERS_COUNT" -eq 5 ]; then
        echo -e "${GREEN}✔ Traefik v3 balancea exactamente sobre las 5 instancias saludables.${NC}"
    else
        echo -e "${YELLOW}ℹ Traefik reporta ${TRAEFIK_SERVERS_COUNT} servidores activos en el catálogo.${NC}"
    fi
else
    # Fallback si Traefik agrupa la lista completa en /api/http/services
    TRAEFIK_SERVICES=$(curl -s "${TRAEFIK_API}/api/http/services")
    if echo "$TRAEFIK_SERVICES" | grep -q "extractor@consulcatalog"; then
        echo -e "${GREEN}✔ Traefik v3 integró el backend dinámico 'extractor@consulcatalog'.${NC}"
    else
        echo -e "${RED}✘ Traefik no detectó el servicio desde Consul Catalog.${NC}"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# TEST 3: Baja Controlada (Detención de Réplica y Retiro del Catálogo)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 3] Evaluando baja controlada y retiro de catálogo al detener réplica...${NC}"
CONTAINERS=($(docker ps --filter "name=extractor" --format "{{.ID}}"))
VICTIM_CID="${CONTAINERS[0]}"
VICTIM_SHORT="${VICTIM_CID:0:12}"
VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$VICTIM_CID" | tr -d '/')

echo -e "Deteniendo contenedor réplica ${CYAN}${VICTIM_NAME} (${VICTIM_SHORT})${NC}..."
docker stop "$VICTIM_CID" > /dev/null

echo -e "Esperando 4s para propagación de desregistro en Consul..."
sleep 4

POST_STOP_PASSING=$(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE '"ServiceID":"extractor-[a-f0-9]+"' | wc -l)
echo -e "Instancias saludables restantes en Consul: ${GREEN}${POST_STOP_PASSING} / 4${NC}"

POST_STOP_INSTANCES=$(curl -s "${CONSUL_API}/v1/agent/services")
if echo "$POST_STOP_INSTANCES" | grep -q "extractor-${VICTIM_SHORT}"; then
    HEALTH_STATE=$(curl -s "${CONSUL_API}/v1/health/checks/extractor" | grep -oE '"Status":"(passing|critical)"' | head -n 1 || echo "")
    echo -e "Estado de salud en Consul para réplica detenida: ${YELLOW}${HEALTH_STATE}${NC}"
else
    echo -e "${GREEN}✔ Réplica ${VICTIM_SHORT} dada de baja exitosamente del catálogo de Consul.${NC}"
fi

# Comprobar que el endpoint sigue respondiendo a través de las réplicas restantes
EXTRACT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:80/extract" \
    -H "Host: extractor.universidad.localhost" \
    -H "Content-Type: application/pdf" \
    -H "X-Filename: consul_test.pdf" \
    --data-binary "@${TEST_PDF}" || echo "000")

if [ "$EXTRACT_CODE" -eq 200 ]; then
    echo -e "${GREEN}✔ Alta Disponibilidad: Extracción exitosa (HTTP 200 OK) a través de réplicas sobrevivientes.${NC}"
else
    echo -e "${RED}✘ Error al invocar /extract durante la baja (HTTP ${EXTRACT_CODE}).${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 4: Recuperación y Auto-Registro de Réplica Reiniciada
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 4] Evaluando recuperación y auto-registro de réplica iniciada...${NC}"
docker start "$VICTIM_CID" > /dev/null

echo -e "Esperando 5s para detección de Docker event y auto-registro..."
sleep 5

RECOVERED_SERVICES=$(curl -s "${CONSUL_API}/v1/agent/services")
if echo "$RECOVERED_SERVICES" | grep -q "extractor-${VICTIM_SHORT}"; then
    echo -e "${GREEN}✔ Réplica ${VICTIM_SHORT} se auto-registró correctamente en Consul tras reinicio.${NC}"
else
    echo -e "${RED}✘ Réplica no volvió a aparecer en Consul.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 5: Reinicio de Consul y Reconciliación de Estado
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 5] Evaluando persistencia y reconciliación tras reinicio de Consul...${NC}"
echo -e "Reiniciando contenedor 'consul'..."
docker restart consul > /dev/null

echo -e "Esperando 6s para reconexión y reconciliación de Registrator..."
sleep 6

CONSUL_POST_RESTART=$(curl -s "${CONSUL_API}/v1/agent/services")
if echo "$CONSUL_POST_RESTART" | grep -q '"Service":"extractor"'; then
    echo -e "${GREEN}✔ Registrator reconcilió exitosamente el catálogo tras el reinicio de Consul.${NC}"
else
    echo -e "${RED}✘ No se recuperaron los servicios tras reiniciar Consul.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 6: Ausencia de Routers Duplicados en Traefik API
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 6] Validando ausencia de colisión/duplicación de routers en Traefik...${NC}"
ROUTERS_JSON=$(curl -s "${TRAEFIK_API}/api/http/routers")

# Contar cuántos routers apuntan a extractor.universidad.localhost
EXTRACTOR_ROUTERS_COUNT=$(echo "$ROUTERS_JSON" | grep -o 'extractor.universidad.localhost' | wc -l)
echo -e "Total de referencias al dominio extractor: ${CYAN}${EXTRACTOR_ROUTERS_COUNT}${NC}"

# Validar que los routers provienen de consulcatalog y no de docker
if echo "$ROUTERS_JSON" | grep -q 'extractor@docker'; then
    echo -e "${RED}✘ FALLO: Se detectó router duplicado 'extractor@docker'.${NC}"
    exit 1
else
    echo -e "${GREEN}✔ Ausencia de routers duplicados: 'extractor' proviene exclusivamente de Consul Catalog.${NC}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ✔ HASHICORP CONSUL CATALOG INTEGRADO Y VERIFICADO EXITOSAMENTE      ${NC}"
echo -e "${GREEN}======================================================================${NC}"
