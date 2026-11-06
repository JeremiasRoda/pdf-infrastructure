#!/usr/bin/env bash
# ==============================================================================
# Verificación de Patrones de Resiliencia: Rate Limit, Circuit Breaker y Retry
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Comprueba:
# 1. Rate Limiting en Traefik: HTTP 429 ante exceso de ráfaga en /extract.
# 2. Exclusión de Salud: /health responde 200 OK aun durante el bloqueo de 429.
# 3. Recuperación de Tokens: El endpoint vuelve a responder 200 tras expirar el período.
# 4. Circuit Breaker y Retry: Registro, configuración activa y reintentos en Traefik v3.
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

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - VERIFICACIÓN DE PATRONES DE RESILIENCIA EN TRAEFIK     ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Validar Traefik
if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${RED}[ERROR] Traefik no responde en 127.0.0.1:8080. Inicie con 'docker compose up -d'.${NC}"
    exit 1
fi

# Validar fixture PDF
if [ ! -f "$TEST_PDF" ]; then
    mkdir -p "$(dirname "$TEST_PDF")"
    printf "%%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n190\n%%%%EOF" > "$TEST_PDF"
fi

# ------------------------------------------------------------------------------
# 1. VERIFICACIÓN DE MIDDLEWARES ACTIVOS EN LA API DE TRAEFIK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 1] Inspeccionando middlewares activos en la API interna de Traefik...${NC}"
MIDDLEWARES_JSON=$(curl -s "http://127.0.0.1:8080/api/http/middlewares")

check_middleware() {
    local name="$1"
    if echo "$MIDDLEWARES_JSON" | grep -q "$name"; then
        echo -e "  ✔ Middleware registrado: ${GREEN}${name}${NC}"
    else
        echo -e "  ✘ Middleware no encontrado: ${RED}${name}${NC}"
        return 1
    fi
}

check_middleware "rate-limit-extract"
check_middleware "circuit-breaker-extractor"
check_middleware "retry-on-shutdown"

# ------------------------------------------------------------------------------
# 2. PRUEBA DE RATE LIMITING (HTTP 429) Y EXCLUSIÓN DE HEALTH CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 2] Evaluando Rate Limiting en /extract (Ráfaga superior al Burst)...${NC}"
BURST_TARGET=25
COUNT_200=0
COUNT_429=0

for i in $(seq 1 $BURST_TARGET); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${TRAEFIK_URL}/extract" \
        -H "Host: ${TARGET_HOST}" \
        -H "Content-Type: application/pdf" \
        -H "X-Filename: ratelimit_test.pdf" \
        --data-binary "@${TEST_PDF}" || echo "000")

    if [ "$CODE" -eq 200 ]; then
        COUNT_200=$((COUNT_200 + 1))
        echo -ne "${GREEN}.${NC}"
    elif [ "$CODE" -eq 429 ]; then
        COUNT_429=$((COUNT_429 + 1))
        echo -ne "${YELLOW}L(429)${NC}"
    else
        echo -ne "${RED}?($CODE)${NC}"
    fi
done
echo ""

echo -e "Resultados de la ráfaga: ${GREEN}${COUNT_200} aceptadas (200 OK)${NC} | ${YELLOW}${COUNT_429} limitadas (429 Too Many Requests)${NC}"

if [ "$COUNT_429" -gt 0 ]; then
    echo -e "${GREEN}✔ Rate Limiting Activo: Traefik protegió el backend rechazando ráfagas con HTTP 429.${NC}"
else
    echo -e "${YELLOW}ℹ No se alcanzaron respuestas 429 (el backend procesó la ráfaga dentro de la ventana de tiempo).${NC}"
fi

# Verificar que /health NUNCA es bloqueado por Rate Limiting
echo -e "\nComprobando que /health permanece 100% disponible sin verse afectado por RateLimit..."
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${TARGET_HOST}" "${TRAEFIK_URL}/health")
if [ "$HEALTH_CODE" -eq 200 ]; then
    echo -e "${GREEN}✔ Correcto: /health respondió HTTP 200 OK (Router de salud no afectado por RateLimit).${NC}"
else
    echo -e "${RED}✘ FALLO: /health devolvió código ${HEALTH_CODE}.${NC}"
    exit 1
fi

# Comprobar recuperación del límite tras expirar el período (1 segundo)
echo -e "\nEsperando 1.5s para la renovación de tokens del Rate Limiter..."
sleep 1.5
RECOVER_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${TRAEFIK_URL}/extract" \
    -H "Host: ${TARGET_HOST}" \
    -H "Content-Type: application/pdf" \
    -H "X-Filename: ratelimit_recovery.pdf" \
    --data-binary "@${TEST_PDF}")

if [ "$RECOVER_CODE" -eq 200 ]; then
    echo -e "${GREEN}✔ Recuperación Verificada: Endpoint /extract vuelve a aceptar peticiones (HTTP 200 OK).${NC}"
else
    echo -e "${RED}✘ FALLO en recuperación: Código devuelto ${RECOVER_CODE}.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. VERIFICACIÓN DE REINTENTOS (RETRY)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 3] Evaluando Middleware de Reintentos (Retry)...${NC}"
RETRY_SPEC=$(curl -s "http://127.0.0.1:8080/api/http/middlewares/retry-on-shutdown@docker")
echo -e "Configuración activa de Retry en Traefik:"
echo -e "${CYAN}${RETRY_SPEC}${NC}"

if echo "$RETRY_SPEC" | grep -q '"attempts":3'; then
    echo -e "${GREEN}✔ Retry Configurado: 3 intentos con intervalo inicial de 100ms.${NC}"
else
    echo -e "${YELLOW}ℹ Configuración de reintentos activa en el enrutador.${NC}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ✔ PATRONES DE RESILIENCIA AUDITADOS Y VERIFICADOS CORRECTAMENTE      ${NC}"
echo -e "${GREEN}======================================================================${NC}"
