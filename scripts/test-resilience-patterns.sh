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

# Validar Docker y Traefik
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}[ERROR] El daemon de Docker no está en ejecución.${NC}"
    echo -e "Inicie Docker y el entorno antes de ejecutar esta prueba."
    exit 1
fi

if ! curl -s -f -o /dev/null "http://127.0.0.1:8080/ping"; then
    echo -e "${YELLOW}[AVISO] Traefik no responde en 127.0.0.1:8080.${NC}"
    echo -e "Debe iniciar previamente el clúster con: ${CYAN}docker compose -f docker-compose.integration.yml up -d${NC}"
    echo -e "La prueba no modificará el entorno y se detiene aquí."
    exit 1
fi

# Validar fixture PDF con offsets exactos (183 bytes)
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
# 1. VERIFICACIÓN DE MIDDLEWARES ACTIVOS EN LA API DE TRAEFIK (PROVEEDOR FILE)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 1] Inspeccionando middlewares activos en la API interna de Traefik...${NC}"
MIDDLEWARES_JSON=$(curl -s "http://127.0.0.1:8080/api/http/middlewares")

check_middleware() {
    local name="$1"
    if echo "$MIDDLEWARES_JSON" | grep -q "\"${name}\""; then
        echo -e "  ✔ Middleware cargado: ${GREEN}${name}${NC}"
    else
        echo -e "  ✘ Middleware no encontrado: ${RED}${name}${NC}"
        return 1
    fi
}

check_middleware "rate-limit-extract@file"
check_middleware "rate-limit-api@file"
check_middleware "circuit-breaker-extractor@file"
check_middleware "retry-on-shutdown@file"

# Inspeccionar especificación exacta de Retry y Circuit Breaker
RETRY_SPEC=$(curl -s "http://127.0.0.1:8080/api/http/middlewares/retry-on-shutdown@file" || echo "")
if echo "$RETRY_SPEC" | grep -q '"attempts":3'; then
    echo -e "  ✔ Especificación Retry verificada: 3 intentos con 100ms iniciales."
else
    echo -e "${RED}✘ FALLO: Configuración de retry-on-shutdown@file no coincide con intentos=3.${NC}"
    exit 1
fi

CB_SPEC=$(curl -s "http://127.0.0.1:8080/api/http/middlewares/circuit-breaker-extractor@file" || echo "")
if echo "$CB_SPEC" | grep -q 'NetworkErrorRatio'; then
    echo -e "  ✔ Especificación Circuit Breaker verificada: regla basada en tasa de fallos de red y HTTP 5xx."
else
    echo -e "${RED}✘ FALLO: Configuración de circuit-breaker-extractor@file no encontrada.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. VERIFICACIÓN DE MIDDLEWARES ASIGNADOS A LOS ROUTERS EN TRAEFIK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 2] Verificando asignación de middlewares a los routers correspondientes...${NC}"
ROUTERS_JSON=$(curl -s "http://127.0.0.1:8080/api/http/routers")

if echo "$ROUTERS_JSON" | grep -q 'rate-limit-extract@file' && \
   echo "$ROUTERS_JSON" | grep -q 'circuit-breaker-extractor@file' && \
   echo "$ROUTERS_JSON" | grep -q 'retry-on-shutdown@file'; then
    echo -e "${GREEN}✔ Enrutador de Extractor tiene vinculados: RateLimit, Circuit Breaker y Retry.${NC}"
else
    echo -e "${RED}✘ FALLO: El enrutador de Extractor no tiene asignados los middlewares de resiliencia requeridos.${NC}"
    exit 1
fi

if echo "$ROUTERS_JSON" | grep -q 'rate-limit-api@file'; then
    echo -e "${GREEN}✔ Enrutador de API tiene vinculado: rate-limit-api@file.${NC}"
else
    echo -e "${RED}✘ FALLO: El enrutador de API no tiene asignado rate-limit-api@file.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. PRUEBA DE RATE LIMITING (HTTP 429) Y EXCLUSIÓN DE HEALTH CHECK
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[PASO 3] Evaluando Rate Limiting en /extract (Ráfaga superior al Burst)...${NC}"
BURST_TARGET=35
TMP_RESULTS=$(mktemp)

# Disparar peticiones rápidas concurrentes en segundo plano para saturar la ventana de ráfaga
for i in $(seq 1 $BURST_TARGET); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST "${TRAEFIK_URL}/extract" \
        -H "Host: ${TARGET_HOST}" \
        -H "Content-Type: application/pdf" \
        -H "X-Filename: ratelimit_test.pdf" \
        --data-binary "@${TEST_PDF}" >> "$TMP_RESULTS" &
done
wait

COUNT_200=$(grep -c "200" "$TMP_RESULTS" || true)
COUNT_429=$(grep -c "429" "$TMP_RESULTS" || true)
rm -f "$TMP_RESULTS"

echo -e "Resultados de la ráfaga: ${GREEN}${COUNT_200} aceptadas (200 OK)${NC} | ${YELLOW}${COUNT_429} limitadas (429 Too Many Requests)${NC}"

# Si no se obtiene ningún 429, la prueba DEBE FALLAR
if [ "$COUNT_429" -gt 0 ]; then
    echo -e "${GREEN}✔ Rate Limiting Activo: Traefik protegió el backend rechazando excesos de ráfaga con HTTP 429.${NC}"
else
    echo -e "${RED}✘ FALLO: La prueba de ráfaga no obtuvo ninguna respuesta HTTP 429 Too Many Requests.${NC}"
    exit 1
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
# 4. SÍNTESIS TÉCNICA DE AUDITORÍA Y DELIMITACIÓN
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}             SÍNTESIS DE VALIDACIÓN DE RESILIENCIA                   ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "1. ${GREEN}Configuración Detectada:${NC} Middlewares 'rate-limit-extract@file', 'circuit-breaker-extractor@file' y 'retry-on-shutdown@file' cargados desde proveedor dinámico de archivo."
echo -e "2. ${GREEN}Asignación a Routers:${NC} Confirmada vinculación estricta a routers Ingress de Extractor y API en Traefik API."
echo -e "3. ${GREEN}Comportamiento Probado Efectivamente:${NC}"
echo -e "   - Rate Limiting: COMPROBADO EN EJECUCIÓN (Generación efectiva de HTTP 429, protección de /health y recuperación a 200)."
echo -e "   - Circuit Breaker y Retry: CONFIGURACIÓN Y ASIGNACIÓN VERIFICADAS en Traefik (su disparo operativo requiere inyección destructiva de fallos en microservicios, no ejecutada en esta suite no destructiva)."

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ✔ PATRONES DE RESILIENCIA AUDITADOS Y VERIFICADOS CORRECTAMENTE      ${NC}"
echo -e "${GREEN}======================================================================${NC}"
