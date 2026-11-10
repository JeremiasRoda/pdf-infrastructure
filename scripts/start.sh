#!/usr/bin/env bash
set -e

COMPOSE_FILE="docker-compose.integration.yml"
NETWORK_NAME="pdf-network"

echo "======================================================================"
echo "   INICIANDO INFRAESTRUCTURA Y MICROSERVICIOS (PDF EXTRACTEXT)       "
echo "======================================================================"

# 1. Comprobar Docker
if ! docker info >/dev/null 2>&1; then
    echo "[ERROR] El daemon de Docker no esta activo."
    exit 1
fi

# 2. Red compartida
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "[INFO] Creando red $NETWORK_NAME..."
    docker network create --driver bridge --attachable "$NETWORK_NAME"
fi

# 3. Compilacion y arranque
echo "[INFO] Levantando entorno de integracion..."
docker compose -f "$COMPOSE_FILE" up -d --build

# 4. Esperar servicios saludables
echo "[INFO] Esperando estado healthy en los servicios..."
SERVICES=("consul" "mongodb" "extractor" "documents" "api")
TIMEOUT=60
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    ALL_HEALTHY=true
    for SVC in "${SERVICES[@]}"; do
        CID=$(docker compose -f "$COMPOSE_FILE" ps -q "$SVC" 2>/dev/null | head -n 1)
        if [ -z "$CID" ]; then
            ALL_HEALTHY=false
            break
        fi
        STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID" 2>/dev/null)
        if [ "$STATUS" != "healthy" ]; then
            ALL_HEALTHY=false
            break
        fi
    done

    if [ "$ALL_HEALTHY" = true ]; then
        echo "[EXITO] Todos los microservicios se encuentran operativos y saludables!"
        break
    fi

    sleep 3
    ELAPSED=$((ELAPSED + 3))
done

echo "======================================================================"
echo " - Traefik Dashboard : http://127.0.0.1:8080/dashboard/"
echo " - Consul UI         : http://127.0.0.1:8500/ui/"
echo " - API Health        : http://127.0.0.1/health (Host: api.universidad.localhost)"
echo "======================================================================"
