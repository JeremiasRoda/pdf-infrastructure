#!/usr/bin/env bash
# ==============================================================================
# Script de inicialización de la red externa Docker para 'pdf-infrastructure'
# UTN FR San Rafael - Arquitectura de Microservicios
# ==============================================================================

set -euo pipefail

NETWORK_NAME="pdf-network"

echo "=========================================================="
echo " Verificando red externa de Docker: '${NETWORK_NAME}'"
echo "=========================================================="

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "[INFO] La red '${NETWORK_NAME}' ya existe. No se requiere acción."
else
    echo "[INFO] Creando red tipo bridge '${NETWORK_NAME}'..."
    docker network create \
        --driver bridge \
        --attachable \
        "${NETWORK_NAME}"
    echo "[SUCCESS] Red '${NETWORK_NAME}' creada exitosamente."
fi

echo "=========================================================="
