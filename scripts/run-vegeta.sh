#!/usr/bin/env bash
RATE=${1:-30}
DURATION=${2:-5}
TRAEFIK_PORT=80
TARGET_HOST="api.universidad.localhost"

echo "======================================================================"
echo "   PRUEBA DE ESTRES Y RESILIENCIA CON VEGETA (BASH)                   "
echo "======================================================================"
echo "Tasa: $RATE req/s | Duracion: ${DURATION}s"

if command -v vegeta >/dev/null 2>&1; then
    echo "GET http://127.0.0.1:$TRAEFIK_PORT/health" | \
    vegeta attack -header "Host: $TARGET_HOST" -rate="$RATE" -duration="${DURATION}s" | \
    vegeta report
else
    echo "Ejecutando via contenedor Docker peterevans/vegeta..."
    docker run --rm -i --net host peterevans/vegeta sh -c \
    "echo 'GET http://127.0.0.1:$TRAEFIK_PORT/health' | vegeta attack -header 'Host: $TARGET_HOST' -rate=$RATE -duration=${DURATION}s | vegeta report"
fi
