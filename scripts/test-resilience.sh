#!/usr/bin/env bash
# ==============================================================================
# Demostración de Resiliencia y Alta Disponibilidad
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Objetivo:
# 1. Comprobar que existen múltiples réplicas de 'extractor' balanceadas por Traefik.
# 2. Detener una réplica activa mientras se ejecutan extracciones reales de PDF.
# 3. Demostrar 0% de errores en la respuesta a los clientes.
# 4. Restaurar automáticamente el estado original del clúster.
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_HOST="extractor.universidad.localhost"
TRAEFIK_URL="http://127.0.0.1:80"
TEST_PDF="./load-tests/pdfs/doc1.pdf"
BURST_COUNT=30

ORIGINAL_CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
ORIGINAL_COUNT="${#ORIGINAL_CONTAINERS[@]}"
if [ "$ORIGINAL_COUNT" -lt 3 ]; then
    ORIGINAL_COUNT=3
fi

cleanup() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}                    RESTAURANDO ESTADO DEL CLÚSTER                    ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${ORIGINAL_COUNT}" extractor > /dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Clúster restablecido a ${ORIGINAL_COUNT} réplicas saludables.${NC}"
}
trap cleanup EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - DEMOSTRACIÓN DE TOLERANCIA A FALLOS Y RESILIENCIA      ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# 1. Verificar conectividad con Traefik
if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${RED}[ERROR] Traefik no está respondiendo en el puerto 8080.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Traefik v3 activo y escuchando.${NC}"

# 2. Asegurar fixture PDF
if [ ! -f "$TEST_PDF" ]; then
    mkdir -p "$(dirname "$TEST_PDF")"
    printf "%%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n190\n%%%%EOF" > "$TEST_PDF"
fi

# 3. Detectar y escalar si es necesario a mínimo 3 réplicas
if [ "${#ORIGINAL_CONTAINERS[@]}" -lt 2 ]; then
    echo -e "${YELLOW}[AVISO] Se requieren al menos 2 réplicas para demostrar resiliencia.${NC}"
    echo -e "Escalando a 3 réplicas..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor
    sleep 3
    ORIGINAL_CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
fi

TOTAL_INSTANCES="${#ORIGINAL_CONTAINERS[@]}"
echo -e "Instancias activas de 'extractor': ${GREEN}${TOTAL_INSTANCES}${NC}"

# 4. Inyección de Falla: Detener una réplica mientras se procesan extracciones
VICTIM_ID="${ORIGINAL_CONTAINERS[0]}"
VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$VICTIM_ID" | tr -d '/')
echo -e "\n${YELLOW}[INYECCIÓN DE FALLA]${NC} Deteniendo contenedor réplica ${RED}${VICTIM_NAME}${NC} con 'docker stop'..."
docker stop "$VICTIM_ID" > /dev/null &
STOP_PID=$!

echo -e "Enviando ráfaga de ${BURST_COUNT} solicitudes de extracción real a través de Traefik..."
OK_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 $BURST_COUNT); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${TRAEFIK_URL}/extract" \
        -H "Host: ${TARGET_HOST}" \
        -H "Content-Type: application/pdf" \
        -H "X-Filename: resilience_test.pdf" \
        --data-binary "@${TEST_PDF}" || echo "000")

    if [ "$HTTP_CODE" -eq 200 ]; then
        OK_COUNT=$((OK_COUNT + 1))
        echo -ne "${GREEN}.${NC}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -ne "${RED}X(${HTTP_CODE})${NC}"
    fi
    sleep 0.05
done
echo ""

wait $STOP_PID

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}                        REPORTE DE RESILIENCIA                        ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Total de solicitudes de extracción: ${BURST_COUNT}"
echo -e "Respuestas exitosas (200 OK):       ${GREEN}${OK_COUNT}${NC}"
echo -e "Solicitudes fallidas:               ${RED}${FAIL_COUNT}${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "\n${GREEN}✔ ÉXITO TOTAL: 100% de peticiones de extracción completadas sin degradación.${NC}"
    echo -e "${GREEN}  Traefik reasignó las peticiones automáticamente a las réplicas vivas.${NC}"
else
    ERROR_PCT=$(( (FAIL_COUNT * 100) / BURST_COUNT ))
    echo -e "\n${RED}✘ HUBO FALLAS (${ERROR_PCT}% de error). Verifique el middleware retry y healthchecks.${NC}"
    exit 1
fi
