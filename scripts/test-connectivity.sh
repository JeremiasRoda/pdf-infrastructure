#!/usr/bin/env bash
# ==============================================================================
# Suite de Validación Mínima de Conectividad Inter-Servicios y Red Compartida
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Verificaciones:
# 1. Todos los contenedores involucrados están conectados a 'pdf-network'.
# 2. 'api' resuelve 'extractor' y 'documents' mediante el DNS interno de Docker.
# 3. 'api' alcanza los endpoints de readiness de 'extractor' y 'documents'.
# 4. 'documents' establece conexión TCP con 'mongodb:27017'.
# 5. Traefik v3.6 detecta los 3 servicios a través de Consul Catalog.
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

COMPOSE_FILE="docker-compose.integration.yml"
TRAEFIK_API="http://127.0.0.1:8080"
NETWORK_NAME="pdf-network"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - VALIDACIÓN DE CONECTIVIDAD INTER-SERVICIOS Y RED       ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# ------------------------------------------------------------------------------
# COMPROBACIÓN PREVIA: Verificar entorno de integración
# ------------------------------------------------------------------------------
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}[ERROR] El daemon de Docker no está en ejecución.${NC}"
    echo -e "Inicie Docker y el entorno de integración antes de ejecutar esta prueba."
    exit 1
fi

RUNNING_CONTAINERS=($(docker compose -f "${COMPOSE_FILE}" ps -q 2>/dev/null || true))
if [ "${#RUNNING_CONTAINERS[@]}" -eq 0 ]; then
    echo -e "${YELLOW}[AVISO] No se detectó un entorno de integración iniciado.${NC}"
    echo -e "Debe iniciar previamente el clúster con: ${CYAN}docker compose -f ${COMPOSE_FILE} up -d${NC}"
    echo -e "La prueba no modificará el entorno y se detiene aquí."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Verificación de conexión a 'pdf-network' para todos los servicios
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 1] Verificando adhesión de contenedores a la red '${NETWORK_NAME}'...${NC}"
SERVICES_TO_CHECK=("traefik" "consul" "consul-registrator" "extractor" "documents" "api" "mongodb")

for svc in "${SERVICES_TO_CHECK[@]}"; do
    CIDS=($(docker compose -f "${COMPOSE_FILE}" ps -q "$svc" 2>/dev/null || true))
    if [ "${#CIDS[@]}" -eq 0 ]; then
        echo -e "  ✘ Servicio '${svc}' no tiene contenedores activos."
        exit 1
    fi
    for cid in "${CIDS[@]}"; do
        CNAME=$(docker inspect -f '{{.Name}}' "$cid" | tr -d '/')
        NET_EXISTS=$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{if eq \$k \"${NETWORK_NAME}\"}}found{{end}}{{end}}" "$cid")
        if [ "$NET_EXISTS" == "found" ]; then
            IP=$(docker inspect -f "{{with index .NetworkSettings.Networks \"${NETWORK_NAME}\"}}{{.IPAddress}}{{end}}" "$cid")
            echo -e "  ✔ ${GREEN}${CNAME}${NC} conectado a ${CYAN}${NETWORK_NAME}${NC} (IP: ${IP})"
        else
            echo -e "  ✘ ${RED}${CNAME}${NC} NO está conectado a ${NETWORK_NAME}."
            exit 1
        fi
    done
done

# ------------------------------------------------------------------------------
# 2. Resolución DNS de 'extractor' y 'documents' desde 'api'
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 2] Verificando resolución DNS interna desde el contenedor 'api'...${NC}"
DNS_RESULT=$(docker compose -f "${COMPOSE_FILE}" exec -T api python -c "
import socket
for host in ['extractor', 'documents']:
    try:
        ip = socket.gethostbyname(host)
        print(f'{host} -> {ip}')
    except Exception as e:
        print(f'{host} -> ERROR: {e}')
        exit(1)
")
echo -e "${DNS_RESULT}"
echo -e "${GREEN}✔ Resolución DNS interna Docker (127.0.0.11) operativa desde 'api'.${NC}"

# ------------------------------------------------------------------------------
# 3. Alcance de Endpoints de Readiness desde 'api'
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 3] Verificando que 'api' alcanza los endpoints de readiness...${NC}"
READINESS_CHECK=$(docker compose -f "${COMPOSE_FILE}" exec -T api python -c "
import urllib.request, sys
targets = {
    'extractor': 'http://extractor:8000/health/ready',
    'documents': 'http://documents:8000/health/ready'
}
for name, url in targets.items():
    try:
        req = urllib.request.urlopen(url, timeout=5)
        code = req.getcode()
        print(f'  ✔ {name} ({url}) respondió HTTP {code}')
    except urllib.error.HTTPError as e:
        # 503 puede ser emitido si está en drain o degradado, pero responde a nivel HTTP
        print(f'  ✔ {name} ({url}) respondió HTTP {e.code}')
    except Exception as e:
        print(f'  ✘ {name} ({url}) inalcanzable: {e}')
        sys.exit(1)
")
echo -e "${READINESS_CHECK}"
echo -e "${GREEN}✔ Conectividad HTTP de readiness confirmada entre microservicios.${NC}"

# ------------------------------------------------------------------------------
# 4. Conexión TCP de 'documents' hacia 'mongodb:27017'
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 4] Verificando conexión TCP desde 'documents' hacia 'mongodb:27017'...${NC}"
MONGO_CHECK=$(docker compose -f "${COMPOSE_FILE}" exec -T documents python -c "
import socket, sys
try:
    sock = socket.create_connection(('mongodb', 27017), timeout=5)
    sock.close()
    print('  ✔ documents -> mongodb:27017 conexión TCP establecida exitosamente.')
except Exception as e:
    print(f'  ✘ Fallo de conexión hacia mongodb:27017: {e}')
    sys.exit(1)
")
echo -e "${MONGO_CHECK}"

# ------------------------------------------------------------------------------
# 5. Detección de los 3 Servicios en Traefik mediante Consul Catalog
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 5] Verificando catálogo de servicios en Traefik v3 (Consul Catalog)...${NC}"
TRAEFIK_SERVICES=$(curl -s "${TRAEFIK_API}/api/http/services" || echo "")

for svc in "extractor@consulcatalog" "documents@consulcatalog" "api@consulcatalog"; do
    if echo "$TRAEFIK_SERVICES" | grep -q "\"${svc}\""; then
        echo -e "  ✔ Servicio detectado en Traefik Ingress: ${GREEN}${svc}${NC}"
    else
        echo -e "  ✘ Servicio NO detectado en Traefik Ingress: ${RED}${svc}${NC}"
        exit 1
    fi
done

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ✔ VALIDACIÓN DE CONECTIVIDAD COMPLETADA CON ÉXITO                    ${NC}"
echo -e "${GREEN}======================================================================${NC}"
