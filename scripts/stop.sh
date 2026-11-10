#!/usr/bin/env bash
COMPOSE_FILE="docker-compose.integration.yml"

echo "======================================================================"
echo "   DETENIENDO INFRAESTRUCTURA Y MICROSERVICIOS                        "
echo "======================================================================"

if [ "$1" == "--clean" ]; then
    echo "[INFO] Deteniendo servicios y eliminando volumenes..."
    docker compose -f "$COMPOSE_FILE" down -v
else
    echo "[INFO] Deteniendo contenedores preservando datos..."
    docker compose -f "$COMPOSE_FILE" down
fi

echo "[EXITO] Entorno detenido correctamente."
