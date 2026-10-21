#!/usr/bin/env bash
# ==============================================================================
# Benchmark Vegeta - Carga Fija Constante (50 req/s, 30s)
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================
# Perfil:
# - Rate: 50 requests/segundo constante
# - Duración: 30 segundos (Total: 1500 solicitudes)
# - Timeout: 30 segundos
# - Rotación entre los 4 PDFs del dataset oficial
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TARGETS_FILE="${SCRIPT_DIR}/vegeta-targets.txt"
RESULTS_BIN="${SCRIPT_DIR}/results.bin"
REPORT_TXT="${SCRIPT_DIR}/report.txt"

TARGET_URL="${TARGET_URL:-http://extractor.universidad.localhost/extract}"
RATE=50
DURATION="30s"
TIMEOUT="30s"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UTN FRSR - PRUEBA DE CARGA FIJA VEGETA (50 req/s - 30 segundos)   ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Objetivo:     ${GREEN}${TARGET_URL}${NC}"
echo -e "Tasa fija:    ${YELLOW}${RATE} req/s${NC}"
echo -e "Duración:     ${YELLOW}${DURATION}${NC} (Total: 1500 solicitudes)"
echo -e "Timeout:      ${YELLOW}${TIMEOUT}${NC}"

# Verificar existencia de los 4 PDFs
PDF_DIR="${SCRIPT_DIR}/pdfs"
if [ ! -f "${PDF_DIR}/doc1.pdf" ]; then
    echo -e "${YELLOW}[AVISO] No se encontraron los PDFs de prueba. Generándolos...${NC}"
    "${ROOT_DIR}/scripts/copy-stress-pdfs.sh"
fi

# Generar archivo de objetivos con rotación de los 4 PDFs
echo -e "\nGenerando archivo de targets para Vegeta..."
cat <<EOF > "${TARGETS_FILE}"
POST ${TARGET_URL}
Content-Type: application/pdf
@${PDF_DIR}/doc1.pdf

POST ${TARGET_URL}
Content-Type: application/pdf
@${PDF_DIR}/doc2.pdf

POST ${TARGET_URL}
Content-Type: application/pdf
@${PDF_DIR}/doc3.pdf

POST ${TARGET_URL}
Content-Type: application/pdf
@${PDF_DIR}/doc4.pdf
EOF

echo -e "${GREEN}[OK] Archivo de objetivos configurado con rotación de 4 PDFs.${NC}"

# Ejecutar el ataque con Vegeta (binario local o contenedor Docker)
echo -e "\n${YELLOW}Iniciando ataque de carga fija durante ${DURATION}...${NC}"

if command -v vegeta >/dev/null 2>&1; then
    echo -e "Ejecutando con binario local 'vegeta'..."
    vegeta attack \
        -rate="${RATE}" \
        -duration="${DURATION}" \
        -timeout="${TIMEOUT}" \
        -targets="${TARGETS_FILE}" \
        > "${RESULTS_BIN}"
    
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}                        REPORTE DE VEGETA                             ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    vegeta report -type=text "${RESULTS_BIN}" | tee "${REPORT_TXT}"
    echo -e "\n${CYAN}Histograma de Latencias:${NC}"
    vegeta report -type='hist[0,50ms,100ms,200ms,500ms,1s,2s,5s]' "${RESULTS_BIN}"
else
    echo -e "${YELLOW}Vegeta no está instalado en el PATH del sistema.${NC}"
    echo -e "Ejecutando a través de contenedor Docker oficial ('ghcr.io/tsenart/vegeta')..."
    docker run --rm -i \
        --network=pdf-network \
        -v "${SCRIPT_DIR}:/work" \
        -w /work \
        ghcr.io/tsenart/vegeta:latest \
        attack -rate="${RATE}" -duration="${DURATION}" -timeout="${TIMEOUT}" -targets="vegeta-targets.txt" \
        > "${RESULTS_BIN}"
    
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}                        REPORTE DE VEGETA                             ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    docker run --rm -i \
        -v "${SCRIPT_DIR}:/work" \
        -w /work \
        ghcr.io/tsenart/vegeta:latest \
        report -type=text < "${RESULTS_BIN}" | tee "${REPORT_TXT}"
fi

echo -e "\n${GREEN}[ÉXITO] Benchmark completado. Reporte guardado en ${REPORT_TXT}.${NC}"
echo -e "${CYAN}======================================================================${NC}"
