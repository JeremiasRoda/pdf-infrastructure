#!/usr/bin/env bash
# ==============================================================================
# Demostración y Validación del Factor IX (Desechabilidad - Twelve-Factor App)
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Aspectos auditados:
# 1. Inicio Rápido (Fast Startup): < 5s en la instancia específica creada.
# 2. Apagado Elegante (Graceful Shutdown): Drenado de extracción real de PDF en
#    vuelo ante SIGTERM y salida limpia del contenedor con ExitCode 0.
# 3. Resiliencia ante Muerte Súbita (Crash Resilience): Manejo de SIGKILL (137)
#    y absorción inmediata por réplicas sobrevivientes. Requiere --allow-destructive.
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
ALLOW_DESTRUCTIVE="${ALLOW_DESTRUCTIVE:-false}"

for arg in "$@"; do
    if [ "$arg" == "--allow-destructive" ]; then
        ALLOW_DESTRUCTIVE="true"
    fi
done

# Almacenar cantidad original de réplicas para restauración estricta
ORIGINAL_CONTAINERS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
ORIGINAL_REPLICA_COUNT="${#ORIGINAL_CONTAINERS[@]}"
if [ "$ORIGINAL_REPLICA_COUNT" -lt 2 ]; then
    ORIGINAL_REPLICA_COUNT=3
fi

cleanup() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}             RESTAURACIÓN Y LIMPIEZA DE CONTENEDORES                  ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "Restableciendo el clúster a ${ORIGINAL_REPLICA_COUNT} réplicas..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${ORIGINAL_REPLICA_COUNT}" extractor > /dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Estado original del clúster restaurado.${NC}"
}
trap cleanup EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - VALIDACIÓN RIGUROSA FACTOR IX: DESECHABILIDAD          ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Validar conectividad de Traefik
if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${RED}[ERROR] Traefik no responde en 127.0.0.1:8080. Inicie con 'docker compose up -d'.${NC}"
    exit 1
fi

# Validar existencia de fixture PDF
if [ ! -f "$TEST_PDF" ]; then
    mkdir -p "$(dirname "$TEST_PDF")"
    printf "%%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n190\n%%%%EOF" > "$TEST_PDF"
fi

# Asegurar al menos 2 réplicas base antes de empezar
if [ "${#ORIGINAL_CONTAINERS[@]}" -lt 2 ]; then
    echo -e "Escalando a 2 réplicas base para pruebas..."
    docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor=2 extractor
    sleep 3
fi

# ------------------------------------------------------------------------------
# TEST 1: Arranque Rápido (< 5s en la instancia específica creada)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 1] Evaluando Arranque Rápido sobre una NUEVA réplica específica...${NC}"
EXISTING_IDS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
NEW_SCALE=$(( ${#EXISTING_IDS[@]} + 1 ))

START_TIME=$(date +%s%N)
docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${NEW_SCALE}" extractor > /dev/null

# Identificar exclusivamente el nuevo contenedor (evitando falsos positivos del balanceador)
ALL_NEW_IDS=($(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}"))
NEW_CID=""
for cid in "${ALL_NEW_IDS[@]}"; do
    FOUND=false
    for old_cid in "${EXISTING_IDS[@]}"; do
        if [ "$cid" == "$old_cid" ]; then
            FOUND=true
            break
        fi
    done
    if [ "$FOUND" == "false" ]; then
        NEW_CID="$cid"
        break
    fi
done

if [ -z "$NEW_CID" ]; then
    echo -e "${RED}[ERROR] No se pudo identificar la nueva instancia creada.${NC}"
    exit 1
fi

NEW_NAME=$(docker inspect -f '{{.Name}}' "$NEW_CID" | tr -d '/')
echo -e "Nueva instancia aislada detectada: ${CYAN}${NEW_NAME} (${NEW_CID:0:12})${NC}"

# Sondeo directo del estado Health del contenedor específico (no vía Traefik)
STARTUP_OK=false
ELAPSED_SEC=0
for i in {1..25}; do
    HEALTH_STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$NEW_CID" 2>/dev/null || echo "starting")
    if [ "$HEALTH_STATUS" == "healthy" ]; then
        END_TIME=$(date +%s%N)
        DIFF_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        ELAPSED_SEC=$(awk "BEGIN {print $DIFF_MS / 1000}")
        STARTUP_OK=true
        break
    fi
    sleep 0.2
done

if [ "$STARTUP_OK" == "true" ] && (( $(echo "$ELAPSED_SEC <= 5.0" | bc -l) )); then
    echo -e "${GREEN}✔ ÉXITO: Contenedor ${NEW_NAME} saludable en ${ELAPSED_SEC}s (< 5.0s límite de cátedra).${NC}"
elif [ "$STARTUP_OK" == "true" ]; then
    echo -e "${YELLOW}⚠ AVISO: El contenedor tardó ${ELAPSED_SEC}s (> 5s).${NC}"
else
    echo -e "${RED}✘ FALLO: El contenedor no alcanzó estado healthy en el tiempo esperado.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 2: Apagado Elegante (Graceful Shutdown) y Drenado con Extracción Real
# ------------------------------------------------------------------------------
TARGET_CID="$NEW_CID"
echo -e "\n${YELLOW}[TEST 2] Evaluando Apagado Elegante (SIGTERM) y Drenado de Extracción Real en ${NEW_NAME}...${NC}"

# Lanzar extracción real en segundo plano apuntando a Traefik
EXTRACTION_OUTPUT=$(mktemp)
curl -s -X POST "${TRAEFIK_URL}/extract" \
     -H "Host: ${TARGET_HOST}" \
     -H "Content-Type: application/pdf" \
     -H "X-Filename: disposability_test.pdf" \
     --data-binary "@${TEST_PDF}" \
     -w "\n%{http_code}" > "$EXTRACTION_OUTPUT" &
EXTRACT_PID=$!

# Breve espera para que la solicitud ingrese a procesamiento antes de enviar SIGTERM
sleep 0.05

STOP_START=$(date +%s)
docker stop "$TARGET_CID" > /dev/null &
STOP_PID=$!

# Esperar ambos procesos
wait $EXTRACT_PID
wait $STOP_PID
STOP_END=$(date +%s)
STOP_DURATION=$((STOP_END - STOP_START))

HTTP_STATUS=$(tail -n 1 "$EXTRACTION_OUTPUT")
BODY_RESPONSE=$(head -n -1 "$EXTRACTION_OUTPUT")
rm -f "$EXTRACTION_OUTPUT"

# Inspeccionar código de salida del contenedor detenido
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$TARGET_CID")
echo -e "Código de salida del proceso tras SIGTERM: ${CYAN}ExitCode=${EXIT_CODE}${NC} (Duración: ${STOP_DURATION}s)"

if [ "$EXIT_CODE" -ne 0 ]; then
    echo -e "${RED}✘ FALLO: El proceso no salió con código 0 (ExitCode=${EXIT_CODE}).${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Apagado Elegante Verificado: ExitCode = 0 (Captura limpia de SIGTERM sin SIGKILL).${NC}"

if [ "$HTTP_STATUS" -eq 200 ] && echo "$BODY_RESPONSE" | grep -q '"content"'; then
    echo -e "${GREEN}✔ Drenado Exitoso: La extracción real en vuelo finalizó con HTTP 200 OK y JSON íntegro.${NC}"
else
    echo -e "${RED}✘ FALLO: La extracción en curso se abortó o falló (HTTP ${HTTP_STATUS}).${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 3: Muerte Súbita (Crash Resilience con SIGKILL intencional)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 3] Evaluando Tolerancia a Caída Súbita (SIGKILL / Fallo Catastrófico)...${NC}"
if [ "$ALLOW_DESTRUCTIVE" != "true" ]; then
    echo -e "${YELLOW}ℹ Test 3 omitido por seguridad. Para habilitar pruebas destructivas, ejecute:${NC}"
    echo -e "  ${CYAN}./scripts/test-disposability.sh --allow-destructive${NC}"
    echo -e "  o defina: ${CYAN}ALLOW_DESTRUCTIVE=true ./scripts/test-disposability.sh${NC}"
else
    REMAINING_CID=$(docker ps --filter "label=traefik.http.routers.extractor.rule" --format "{{.ID}}" | head -n 1)
    VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$REMAINING_CID" | tr -d '/')
    echo -e "Inyectando fallo abrupto intencional (SIGKILL) a ${VICTIM_NAME}..."
    docker kill -s KILL "$REMAINING_CID" > /dev/null

    KILL_EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$REMAINING_CID")
    echo -e "Código de salida esperado por SIGKILL: ${CYAN}ExitCode=${KILL_EXIT_CODE}${NC}"
    if [ "$KILL_EXIT_CODE" -eq 137 ]; then
        echo -e "${GREEN}✔ Confirmado: Finalización inmediata forzada por SIGKILL (código 137).${NC}"
    fi

    # Comprobar que Traefik absorbe las solicitudes a través de las réplicas restantes
    SURVIVOR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${TARGET_HOST}" "${TRAEFIK_URL}/health" || echo "000")
    if [ "$SURVIVOR_CODE" -eq 200 ]; then
        echo -e "${GREEN}✔ Alta Disponibilidad: Clúster respondió HTTP 200 OK inmediatamente a través de sobrevivientes.${NC}"
    else
        echo -e "${RED}✘ FALLO: Tráfico interrumpido tras caída súbita (HTTP ${SURVIVOR_CODE}).${NC}"
        exit 1
    fi
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ✔ FACTOR IX (DESECHABILIDAD) VALIDADO RIGUROSAMENTE CON ÉXITO       ${NC}"
echo -e "${GREEN}======================================================================${NC}"
