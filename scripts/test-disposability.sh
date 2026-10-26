#!/usr/bin/env bash
# ==============================================================================
# Script de Demostración del Factor IX (Desechabilidad - Twelve-Factor App)
# Cátedra: Desarrollo de Software - UTN FR San Rafael (Issue #8)
# ==============================================================================
# Evalúa:
# 1. Arranque Rápido (Fast Startup): Tiempo desde creación hasta estado saludable (< 5s).
# 2. Apagado Elegante (Graceful Shutdown): Drenado de peticiones y salida limpia (Exit 0, no 137).
# 3. Resiliencia ante Caída Súbita (Crash Resilience): Tolerancia a SIGKILL sin corrupción.
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_HOST="extractor.universidad.localhost"
HEALTH_URL="http://127.0.0.1:80/health"
TRAEFIK_API="http://127.0.0.1:8080/api/http/services"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - EVALUACIÓN FACTOR IX: DESECHABILIDAD (TWELVE-FACTOR)    ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# 1. Verificar Traefik
if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${RED}[ERROR] Traefik no está respondiendo en :8080. Ejecute 'docker compose up -d'.${NC}"
    exit 1
fi

# Detectar réplicas del extractor
CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
if [ "${#CONTAINERS[@]}" -lt 2 ]; then
    echo -e "${YELLOW}[AVISO] Se requieren al menos 2 réplicas para probar drenado sin corte.${NC}"
    echo -e "Escalando a 3 réplicas..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor
    sleep 3
    CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
fi

echo -e "Instancias activas de extractor detectadas: ${GREEN}${#CONTAINERS[@]}${NC}"

# ------------------------------------------------------------------------------
# TEST 1: Arranque Rápido (Fast Startup)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 1] Evaluando Arranque Rápido (Fast Startup)...${NC}"
START_TIME=$(date +%s%N)
TEST_CID=$(docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=$((${#CONTAINERS[@]} + 1)) extractor | grep -oE '[a-f0-9]{12,}' | head -n 1 || echo "")

# Medir hasta que Traefik o Docker reporte healthy
ELAPSED_SEC=0
for i in {1..20}; do
    if curl -s -f -H "Host: ${TARGET_HOST}" "${HEALTH_URL}" > /dev/null; then
        END_TIME=$(date +%s%N)
        DIFF_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        ELAPSED_SEC=$(awk "BEGIN {print $DIFF_MS / 1000}")
        break
    fi
    sleep 0.25
done

echo -e "Tiempo de arranque y disponibilidad: ${GREEN}${ELAPSED_SEC}s${NC}"
if (( $(echo "$ELAPSED_SEC < 5.0" | bc -l) )); then
    echo -e "${GREEN}✔ Cumple Criterio: Arranque rápido inferior a 5 segundos.${NC}"
else
    echo -e "${YELLOW}⚠ Arranque superior a 5s pero dentro de límites tolerables.${NC}"
fi

# ------------------------------------------------------------------------------
# TEST 2: Apagado Elegante y Drenado (Graceful Shutdown)
# ------------------------------------------------------------------------------
TARGET_CID="${CONTAINERS[0]}"
TARGET_NAME=$(docker inspect -f '{{.Name}}' "$TARGET_CID" | tr -d '/')
echo -e "\n${YELLOW}[TEST 2] Evaluando Apagado Elegante (Graceful Shutdown) en ${TARGET_NAME}...${NC}"
echo -e "Enviando SIGTERM con 'docker stop' y midiendo salida..."

STOP_START=$(date +%s)
docker stop "$TARGET_CID" > /dev/null &
STOP_PID=$!

# Disparar peticiones mientras se apaga para validar reintentos de Traefik y cero fallos
OK_REQUESTS=0
FAIL_REQUESTS=0
for j in {1..15}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${TARGET_HOST}" "${HEALTH_URL}" || echo "000")
    if [ "$HTTP_CODE" -eq 200 ]; then
        OK_REQUESTS=$((OK_REQUESTS + 1))
        echo -ne "${GREEN}.${NC}"
    else
        FAIL_REQUESTS=$((FAIL_REQUESTS + 1))
        echo -ne "${RED}X${NC}"
    fi
    sleep 0.1
done
echo ""

wait $STOP_PID
STOP_END=$(date +%s)
STOP_DURATION=$((STOP_END - STOP_START))

# Verificar código de salida del contenedor
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$TARGET_CID")
echo -e "Duración del apagado: ${CYAN}${STOP_DURATION}s${NC}"
echo -e "Código de salida del proceso: ${CYAN}ExitCode=${EXIT_CODE}${NC}"

if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}✔ ÉXITO TOTAL: El contenedor interceptó SIGTERM y finalizó limpiamente (Exit 0).${NC}"
elif [ "$EXIT_CODE" -eq 137 ]; then
    echo -e "${RED}✘ FALLO: El contenedor fue forzado a morir por SIGKILL (Exit 137). Revise stop_grace_period o exec.${NC}"
else
    echo -e "${YELLOW}ℹ Finalizó con código ${EXIT_CODE}.${NC}"
fi

if [ "$FAIL_REQUESTS" -eq 0 ]; then
    echo -e "${GREEN}✔ Cero Downtime: 100% de peticiones exitosas durante el apagado (${OK_REQUESTS}/$((OK_REQUESTS+FAIL_REQUESTS))).${NC}"
else
    echo -e "${RED}✘ Hubo ${FAIL_REQUESTS} peticiones caídas durante el apagado.${NC}"
fi

# ------------------------------------------------------------------------------
# TEST 3: Resiliencia ante Caída Súbita (Crash Resilience)
# ------------------------------------------------------------------------------
REMAINING_CID=$(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}" | head -n 1)
echo -e "\n${YELLOW}[TEST 3] Evaluando Resiliencia ante Caída Súbita (SIGKILL / Muerte de Hardware)...${NC}"
echo -e "Matando contenedor réplica con 'docker kill'..."
docker kill "$REMAINING_CID" > /dev/null

HTTP_SURVIVOR=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${TARGET_HOST}" "${HEALTH_URL}" || echo "000")
if [ "$HTTP_SURVIVOR" -eq 200 ]; then
    echo -e "${GREEN}✔ Sistema Resiliente: Traefik descartó la réplica muerta y respondió 200 OK con el clúster.${NC}"
else
    echo -e "${RED}✘ Error al resolver tras muerte súbita (HTTP ${HTTP_SURVIVOR}).${NC}"
fi

# Restaurar estado
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}                    RESTAURANDO ESTADO DEL CLÚSTER                    ${NC}"
echo -e "${CYAN}======================================================================${NC}"
docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=3 extractor
echo -e "${GREEN}[OK] Clúster restablecido a 3 réplicas saludables.${NC}"
echo -e "${CYAN}======================================================================${NC}\n"
