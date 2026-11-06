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

# ------------------------------------------------------------------------------
# COMPROBACIÓN PREVIA: Verificar entorno de integración
# ------------------------------------------------------------------------------
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}[ERROR] El daemon de Docker no está en ejecución.${NC}"
    echo -e "Inicie Docker y el entorno de integración antes de ejecutar esta prueba."
    exit 1
fi

ORIGINAL_CONTAINERS=($(docker compose -f docker-compose.integration.yml ps -q extractor 2>/dev/null || true))
ORIGINAL_REPLICA_COUNT="${#ORIGINAL_CONTAINERS[@]}"

if [ "$ORIGINAL_REPLICA_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}[AVISO] No se detectó un entorno de integración iniciado con réplicas de extractor.${NC}"
    echo -e "Debe iniciar previamente el clúster con: ${CYAN}docker compose -f docker-compose.integration.yml up -d${NC}"
    echo -e "La prueba no modificará el entorno y se detiene sin alterar contenedores."
    exit 1
fi

cleanup() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}             RESTAURACIÓN Y LIMPIEZA DE CONTENEDORES                  ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "Restableciendo el clúster a exactamente ${ORIGINAL_REPLICA_COUNT} réplicas originales..."
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

# Validar existencia de fixture PDF con offsets exactos (183 bytes)
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
# TEST 1: Arranque Rápido (< 5s en la instancia específica creada)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 1] Evaluando Arranque Rápido sobre una NUEVA réplica específica...${NC}"
EXISTING_IDS=($(docker compose -f docker-compose.integration.yml ps -q extractor))
NEW_SCALE=$(( ${#EXISTING_IDS[@]} + 1 ))

START_TIME=$(date +%s%N)
docker compose -f docker-compose.integration.yml up -d --no-deps --scale extractor="${NEW_SCALE}" extractor > /dev/null

# Identificar inequívocamente el nuevo contenedor mediante Docker Compose
ALL_NEW_IDS=($(docker compose -f docker-compose.integration.yml ps -q extractor))
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
    echo -e "${RED}[ERROR] No se pudo identificar inequívocamente la nueva instancia creada.${NC}"
    exit 1
fi

NEW_NAME=$(docker inspect -f '{{.Name}}' "$NEW_CID" | tr -d '/')
echo -e "Nueva instancia aislada detectada: ${CYAN}${NEW_NAME} (${NEW_CID:0:12})${NC}"

# Sondeo directo del estado Health del contenedor específico (no vía Traefik)
STARTUP_OK=false
ELAPSED_SEC=0
for i in {1..30}; do
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

# Validación estricta: si supera 5.0 segundos o no es healthy, DEBE FALLAR
if [ "$STARTUP_OK" == "true" ] && (( $(echo "$ELAPSED_SEC <= 5.0" | bc -l) )); then
    echo -e "${GREEN}✔ ÉXITO: Contenedor ${NEW_NAME} saludable en ${ELAPSED_SEC}s (< 5.0s límite estricto).${NC}"
else
    echo -e "${RED}✘ FALLO: El contenedor no cumplió el límite de arranque rápido de 5.0s (tiempo: ${ELAPSED_SEC}s, healthy: ${STARTUP_OK}).${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 2: Apagado Elegante (Graceful Shutdown) y Drenado con Extracción Real
# ------------------------------------------------------------------------------
TARGET_CID="$NEW_CID"
TARGET_NAME="$NEW_NAME"
echo -e "\n${YELLOW}[TEST 2] Evaluando Apagado Elegante (SIGTERM) y Drenado de Extracción Real en ${TARGET_NAME}...${NC}"

AUDIT_ID="drain-test-$(date +%s)-$RANDOM"
EXTRACTION_OUTPUT=$(mktemp)

# Lanzar extracción real en segundo plano con identificador de auditoría inequívoco
curl -s -X POST "${TRAEFIK_URL}/extract" \
     -H "Host: ${TARGET_HOST}" \
     -H "Content-Type: application/pdf" \
     -H "X-Filename: disposability_test.pdf" \
     -H "X-Audit-Id: ${AUDIT_ID}" \
     -H "X-Request-Id: ${AUDIT_ID}" \
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
echo -e "Código de salida del proceso tras SIGTERM: ${CYAN}ExitCode=${EXIT_CODE}${NC} (Duración del stop: ${STOP_DURATION}s)"

if [ "$EXIT_CODE" -ne 0 ]; then
    echo -e "${RED}✘ FALLO: El proceso no salió con código 0 tras SIGTERM (ExitCode=${EXIT_CODE}).${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Apagado Elegante Verificado: ExitCode = 0 (Captura limpia de SIGTERM sin SIGKILL forzado).${NC}"

if [ "$HTTP_STATUS" -ne 200 ] || ! echo "$BODY_RESPONSE" | grep -q '"content"'; then
    echo -e "${RED}✘ FALLO: La extracción en curso se abortó o falló (HTTP ${HTTP_STATUS}).${NC}"
    exit 1
fi
echo -e "${GREEN}✔ Extracción exitosa con HTTP 200 OK y JSON íntegro.${NC}"

# Comprobación rigurosa de si la solicitud fue procesada por la instancia detenida
TARGET_LOGS=$(docker logs "$TARGET_CID" 2>&1 || true)
if echo "$TARGET_LOGS" | grep -q "${AUDIT_ID}"; then
    echo -e "${GREEN}✔ Drenado Concluyente Verificado: Se comprobó en los logs de ${TARGET_NAME} (Audit ID: ${AUDIT_ID}) que esta réplica específica procesó y completó la extracción antes de terminar.${NC}"
else
    echo -e "${YELLOW}ℹ Comprobación de Drenado: La extracción en vuelo finalizó con éxito (HTTP 200 OK), pero el balanceador Traefik la derivó a otra réplica sobreviviente (Audit ID ${AUDIT_ID} no presente en logs de ${TARGET_NAME}). No se presenta como demostración concluyente del drenaje en esta instancia específica.${NC}"
fi

# ------------------------------------------------------------------------------
# TEST 3: Muerte Súbita (Crash Resilience con SIGKILL intencional)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[TEST 3] Evaluando Tolerancia a Caída Súbita (SIGKILL / Fallo Catastrófico)...${NC}"
if [ "$ALLOW_DESTRUCTIVE" != "true" ]; then
    echo -e "${YELLOW}ℹ Test 3 omitido: No se ejecutó la prueba destructiva (--allow-destructive no especificado).${NC}"
    echo -e "${YELLOW}  No se declara validada la totalidad del Factor IX.${NC}"
else
    REMAINING_CID=$(docker compose -f docker-compose.integration.yml ps -q extractor | head -n 1)
    VICTIM_NAME=$(docker inspect -f '{{.Name}}' "$REMAINING_CID" | tr -d '/')
    echo -e "Inyectando fallo abrupto intencional (SIGKILL) a ${VICTIM_NAME} (${REMAINING_CID:0:12})..."
    docker kill -s KILL "$REMAINING_CID" > /dev/null

    KILL_EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$REMAINING_CID")
    echo -e "Código de salida tras SIGKILL: ${CYAN}ExitCode=${KILL_EXIT_CODE}${NC}"
    if [ "$KILL_EXIT_CODE" -eq 137 ]; then
        echo -e "${GREEN}✔ Confirmado: Finalización inmediata forzada por SIGKILL (código 137).${NC}"
    else
        echo -e "${RED}✘ FALLO: Se esperaba código 137 para SIGKILL, obtenido: ${KILL_EXIT_CODE}.${NC}"
        exit 1
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
echo -e "${GREEN}  EVALUACIÓN DE FACTOR IX (DESECHABILIDAD) FINALIZADA                  ${NC}"
echo -e "${GREEN}======================================================================${NC}"
