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

# ------------------------------------------------------------------------------
# COMPROBACIÓN PREVIA: Verificar entorno de integración
# ------------------------------------------------------------------------------
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}[ERROR] El daemon de Docker no está en ejecución.${NC}"
    echo -e "Inicie Docker y el entorno de integración antes de ejecutar esta prueba."
    exit 1
fi

INITIAL_EXTRACTORS=($(docker compose -f docker-compose.integration.yml ps -q extractor 2>/dev/null || true))
INITIAL_COUNT="${#INITIAL_EXTRACTORS[@]}"

if [ "$INITIAL_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}[AVISO] No se detectó un entorno de integración iniciado.${NC}"
    echo -e "Debe iniciar previamente el clúster con: ${CYAN}docker compose -f docker-compose.integration.yml up -d${NC}"
    echo -e "La prueba no modificará el entorno y se detiene sin alterar contenedores."
    exit 1
fi

cleanup() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}                    RESTAURACIÓN DEL ENTORNO                          ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "Restableciendo el clúster a exactamente ${INITIAL_COUNT} réplicas de extractor..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${INITIAL_COUNT}" extractor > /dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Clúster restablecido a ${INITIAL_COUNT} réplicas originales de extractor.${NC}"
}
trap cleanup EXIT

# Función de sondeo periódico con timeout
wait_for_condition() {
    local description="$1"
    local timeout_sec="$2"
    local check_cmd="$3"
    local elapsed=0
    echo -e "Esperando: ${description} (timeout ${timeout_sec}s)..."
    while [ "$elapsed" -lt "$timeout_sec" ]; do
        if eval "$check_cmd" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo -e "${RED}[TIMEOUT] Condición no alcanzada tras ${timeout_sec}s: ${description}${NC}"
    return 1
}

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

wait_for_condition "Consul registra exactamente 5 réplicas passing de extractor" 20 \
    '[ $(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE "\"ServiceID\":\"extractor-[a-f0-9]+\"" | wc -l) -eq 5 ]' || {
    echo -e "${RED}✘ FALLO: Se esperaban exactamente 5 instancias saludables en Consul.${NC}"
    exit 1
}

EXTRACTOR_PASSING=$(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true")
PASSING_COUNT=$(echo "$EXTRACTOR_PASSING" | grep -oE '"ServiceID":"extractor-[a-f0-9]+"' | wc -l)
echo -e "Instancias saludables de 'extractor' en Consul: ${GREEN}${PASSING_COUNT} / 5${NC}"

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

# Verificar que Traefik v3 detectó exactamente las 5 instancias en su pool de servidores
wait_for_condition "Traefik detecta exactamente 5 backends en extractor@consulcatalog" 20 \
    '[ $(curl -s "${TRAEFIK_API}/api/http/services/extractor@consulcatalog" | grep -o "\"url\":" | wc -l) -eq 5 ]' || {
    TRAEFIK_COUNT=$(curl -s "${TRAEFIK_API}/api/http/services/extractor@consulcatalog" | grep -o '"url":' | wc -l || echo "0")
    echo -e "${RED}✘ FALLO: Traefik no detectó exactamente 5 backends activos (encontrados: ${TRAEFIK_COUNT}).${NC}"
    exit 1
}
echo -e "${GREEN}✔ Traefik v3 balancea exactamente sobre 5 backends saludables.${NC}"

# ------------------------------------------------------------------------------
# TEST 3: Baja Controlada (Detención de Réplica y Retiro del Catálogo)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 3] Evaluando baja controlada y retiro de catálogo al detener réplica...${NC}"
CONTAINERS=($(docker compose -f docker-compose.integration.yml ps -q extractor))
VICTIM_CID="${CONTAINERS[0]}"
VICTIM_SHORT="${VICTIM_CID:0:12}"
VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$VICTIM_CID" | tr -d '/')

echo -e "Deteniendo contenedor réplica ${CYAN}${VICTIM_NAME} (${VICTIM_SHORT})${NC}..."
docker stop "$VICTIM_CID" > /dev/null

wait_for_condition "Consul actualiza a exactamente 4 réplicas passing tras detención" 15 \
    '[ $(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE "\"ServiceID\":\"extractor-[a-f0-9]+\"" | wc -l) -eq 4 ]' || {
    echo -e "${RED}✘ FALLO: Consul no redujo a 4 instancias passing tras detener la réplica.${NC}"
    exit 1
}

POST_STOP_PASSING=$(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE '"ServiceID":"extractor-[a-f0-9]+"' | wc -l)
echo -e "Instancias saludables restantes en Consul: ${GREEN}${POST_STOP_PASSING} / 4${NC}"

wait_for_condition "Traefik reduce a exactamente 4 backends activos" 15 \
    '[ $(curl -s "${TRAEFIK_API}/api/http/services/extractor@consulcatalog" | grep -o "\"url\":" | wc -l) -eq 4 ]' || {
    echo -e "${RED}✘ FALLO: Traefik no redujo a 4 backends activos tras la baja de la réplica.${NC}"
    exit 1
}
echo -e "${GREEN}✔ Traefik v3 redujo su pool a exactamente 4 servidores activos.${NC}"

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

wait_for_condition "Consul vuelve a detectar 5 réplicas passing tras reinicio" 20 \
    '[ $(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE "\"ServiceID\":\"extractor-[a-f0-9]+\"" | wc -l) -eq 5 ]' || {
    echo -e "${RED}✘ FALLO: La réplica reiniciada no alcanzó estado passing en Consul.${NC}"
    exit 1
}

wait_for_condition "Traefik vuelve a balancear sobre exactamente 5 backends" 20 \
    '[ $(curl -s "${TRAEFIK_API}/api/http/services/extractor@consulcatalog" | grep -o "\"url\":" | wc -l) -eq 5 ]' || {
    echo -e "${RED}✘ FALLO: Traefik no reincorporó los 5 backends activos.${NC}"
    exit 1
}
echo -e "${GREEN}✔ Réplica ${VICTIM_SHORT} recuperada y reintegrada a Consul y Traefik (5 backends activos).${NC}"

# ------------------------------------------------------------------------------
# TEST 5: Reinicio de Consul y Reconciliación de Estado
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 5] Evaluando persistencia y reconciliación tras reinicio de Consul...${NC}"
echo -e "Reiniciando servicio 'consul' mediante Docker Compose..."
docker compose -f docker-compose.integration.yml restart consul > /dev/null

wait_for_condition "Consul recupera líder electo tras reinicio" 25 \
    '[ -n "$(curl -s "${CONSUL_API}/v1/status/leader" | tr -d "\"" | tr -d "[:space:]")" ]' || {
    echo -e "${RED}✘ FALLO: Consul no eligió líder tras reinicio.${NC}"
    exit 1
}

wait_for_condition "Registrator reconcilia las 5 réplicas en Consul" 25 \
    '[ $(curl -s "${CONSUL_API}/v1/health/service/extractor?passing=true" | grep -oE "\"ServiceID\":\"extractor-[a-f0-9]+\"" | wc -l) -eq 5 ]' || {
    echo -e "${RED}✘ FALLO: Registrator no reconcilió las 5 réplicas en Consul tras el reinicio.${NC}"
    exit 1
}
echo -e "${GREEN}✔ Registrator reconcilió exitosamente las 5 réplicas tras el reinicio de Consul.${NC}"

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
