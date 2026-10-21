#!/usr/bin/env bash
# ==============================================================================
# Monitor de Recursos en Vivo para Benchmarks de Carga (k6 / Vegeta)
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Monitorea en tiempo real el consumo de CPU, RAM e I/O de:
# - Todas las réplicas de 'extractor'
# - El Reverse Proxy 'traefik'
# Permite exportar a CSV para las gráficas del informe final.
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CSV_EXPORT="${1:-}"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - MONITOR DE RECURSOS (CPU / RAM / RED) EN VIVO           ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Filtrando contenedores de infraestructura y microservicios..."
echo -e "Presione ${YELLOW}Ctrl+C${NC} para detener la monitorización.\n"

# Detectar contenedores relevantes
get_target_containers() {
    docker ps --format "{{.Names}}" | grep -E 'extractor|traefik|api|documents|redis' || true
}

CONTAINERS=$(get_target_containers)

if [ -z "$CONTAINERS" ]; then
    echo -e "${YELLOW}[AVISO] No se encontraron contenedores activos de extractor o traefik.${NC}"
    echo -e "Asegúrese de levantar los servicios previamente (ej. docker compose up -d)."
    echo -e "Monitoreando todos los contenedores en ejecución..."
    CONTAINER_ARGS=""
else
    echo -e "${GREEN}Contenedores identificados:${NC}"
    echo "$CONTAINERS" | sed 's/^/  - /'
    CONTAINER_ARGS=$(echo "$CONTAINERS" | tr '\n' ' ')
fi

if [ -n "$CSV_EXPORT" ]; then
    mkdir -p "$(dirname "$CSV_EXPORT")"
    echo "timestamp,container,cpu_percent,mem_usage,mem_percent,net_io" > "$CSV_EXPORT"
    echo -e "\n${GREEN}Exportando métricas en formato CSV a: ${CSV_EXPORT}${NC}"
    
    while true; do
        TS=$(date +"%Y-%m-%dT%H:%M:%S")
        # Captura sin stream para volcar snapshot a CSV
        docker stats --no-stream --format "$TS,{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}}" $CONTAINER_ARGS >> "$CSV_EXPORT"
        sleep 1
    done
else
    # Modo interactivo en vivo con docker stats formateado
    docker stats \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" \
        $CONTAINER_ARGS
fi
