#!/usr/bin/env bash
# ==============================================================================
# Script de Demostración de Resiliencia y Alta Disponibilidad
# UTN FR San Rafael - Ecosistema 'pdf-extractext'
# ==============================================================================
# Objetivo:
# 1. Comprobar que existen múltiples réplicas del servicio 'extractor'.
# 2. Detener intencionalmente una réplica activa ('chaos injection').
# 3. Disparar una ráfaga de peticiones concurrentes a Traefik.
# 4. Demostrar 0% de errores en la respuesta a los clientes (100% 200 OK).
# ==============================================================================

set -euo pipefail

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TARGET_HOST="extractor.universidad.localhost"
TRAEFIK_URL="http://127.0.0.1:80/health"
TRAEFIK_API="http://127.0.0.1:8080/api/http/services"
BURST_COUNT=40

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - DEMOSTRACIÓN DE TOLERANCIA A FALLOS Y RESILIENCIA      ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# 1. Verificar conectividad con Traefik
echo -e "\n${YELLOW}[PASO 1]${NC} Verificando disponibilidad de Traefik..."
if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${RED}[ERROR] Traefik no está respondiendo en el puerto 8080.${NC}"
    echo -e "Asegúrese de haber ejecutado: docker compose up -d"
    exit 1
fi
echo -e "${GREEN}[OK] Traefik v3 activo y escuchando.${NC}"

# 2. Contar réplicas del extractor en Docker
echo -e "\n${YELLOW}[PASO 2]${NC} Detectando réplicas del servicio 'extractor'..."
CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    # Intentar búsqueda por nombre si los labels no se resolvieron
    CONTAINERS=($(docker ps --filter "name=extractor" --format "{{.ID}}"))
fi

TOTAL_INSTANCES="${#CONTAINERS[@]}"
echo -e "Instancias activas de 'extractor' detectadas: ${GREEN}${TOTAL_INSTANCES}${NC}"

if [ "${TOTAL_INSTANCES}" -lt 2 ]; then
    echo -e "${RED}[ADVERTENCIA] Se requiere al menos 2 réplicas para demostrar resiliencia.${NC}"
    echo -e "Para escalar a 5 réplicas, ejecute:"
    echo -e "  ${CYAN}docker compose -f docker-compose.integration.yml up -d --scale extractor=5${NC}"
    exit 1
fi

# Listar las instancias
echo "Detalle de réplicas en ejecución:"
for CID in "${CONTAINERS[@]}"; do
    CNAME=$(docker inspect -f '{{.Name}}' "$CID" | tr -d '/')
    CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CID")
    echo -e "  - ID: ${CYAN}${CID:0:12}${NC} | Nombre: ${CNAME} | IP: ${CIP}"
done

# 3. Seleccionar y matar una réplica (Inyección de falla)
VICTIM_ID="${CONTAINERS[0]}"
VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$VICTIM_ID" | tr -d '/')
echo -e "\n${YELLOW}[PASO 3]${NC} Inyectando falla: Deteniendo contenedor réplica ${RED}${VICTIM_NAME} (${VICTIM_ID:0:12})${NC}..."
docker stop "$VICTIM_ID" > /dev/null

echo -e "${GREEN}[OK] Réplica detenida.${NC} Quedan $((TOTAL_INSTANCES - 1)) réplicas vivas."

# 4. Disparar ráfaga de peticiones a través de Traefik
echo -e "\n${YELLOW}[PASO 4]${NC} Disparando ráfaga de ${BURST_COUNT} peticiones hacia http://${TARGET_HOST}/health..."
OK_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 $BURST_COUNT); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${TARGET_HOST}" "${TRAEFIK_URL}" || echo "000")
    if [ "$HTTP_CODE" -eq 200 ]; then
        OK_COUNT=$((OK_COUNT + 1))
        echo -ne "${GREEN}.${NC}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -ne "${RED}X${NC}"
    fi
    # Pequeño delay de 25ms para simular concurrencia continua
    sleep 0.025
done
echo ""

# 5. Reporte de Resultados
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}                        REPORTE DE AUDITORÍA                          ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Total de peticiones enviadas: ${BURST_COUNT}"
echo -e "Respuestas exitosas (200 OK): ${GREEN}${OK_COUNT}${NC}"
echo -e "Peticiones fallidas:          ${RED}${FAIL_COUNT}${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "\n${GREEN}✔ ÉXITO TOTAL (0% de errores): Traefik balanceó transparentemente la carga${NC}"
    echo -e "${GREEN}  hacia las réplicas sanas sin degradación de servicio percibida por el cliente.${NC}"
else
    ERROR_PCT=$(( (FAIL_COUNT * 100) / BURST_COUNT ))
    echo -e "\n${RED}✘ HUBO ERRORES (${ERROR_PCT}% de falla). Verifique healthcheck en Traefik.${NC}"
fi

echo -e "\n${YELLOW}[PASO 5]${NC} Para restaurar la réplica o volver al estado deseado:"
echo -e "  ${CYAN}docker compose -f docker-compose.integration.yml up -d --scale extractor=5${NC}"
echo -e "${CYAN}======================================================================${NC}\n"
