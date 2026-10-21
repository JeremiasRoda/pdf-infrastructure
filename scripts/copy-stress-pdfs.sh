#!/usr/bin/env bash
# ==============================================================================
# Script de Importación de PDFs de Estrés para Benchmarks (k6 / Vegeta)
# Cátedra: Desarrollo de Software - UTN FR San Rafael
# ==============================================================================

set -euo pipefail

# Colores para salida en consola
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_DIR="${ROOT_DIR}/load-tests/pdfs"
DEFAULT_SOURCE="${ROOT_DIR}/../pdf-extractext/tests/stress/pdfs"
SOURCE_DIR="${1:-$DEFAULT_SOURCE}"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}    UTN FRSR - IMPORTACIÓN DE DATASET DE PDFS PARA BENCHMARK          ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "Directorio destino: ${GREEN}${TARGET_DIR}${NC}"
echo -e "Buscando dataset en: ${YELLOW}${SOURCE_DIR}${NC}"

mkdir -p "${TARGET_DIR}"

# Función para generar un PDF mínimo y válido de prueba
generar_pdf_valido() {
    local archivo="$1"
    local texto="$2"
    cat <<EOF > "$archivo"
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>
endobj
4 0 obj
<< /Length $((${#texto} + 40)) >>
stream
BT
/F1 12 Tf
72 712 Td
($texto) Tj
ET
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000214 00000 n 
trailer
<< /Size 5 /Root 1 0 R >>
startxref
310
%%EOF
}

if [ -d "${SOURCE_DIR}" ] && compgen -G "${SOURCE_DIR}/*.pdf" > /dev/null; then
    echo -e "${GREEN}[OK] Directorio fuente encontrado con archivos PDF.${NC}"
    cp -v "${SOURCE_DIR}"/*.pdf "${TARGET_DIR}/"

    # Mapear a nombres deterministas doc1.pdf .. doc4.pdf para compatibilidad estricta
    PDF_FILES=("${TARGET_DIR}"/*.pdf)
    idx=1
    for pdf in "${PDF_FILES[@]}"; do
        base=$(basename "$pdf")
        if [[ "$base" != "doc"* ]]; then
            cp "$pdf" "${TARGET_DIR}/doc${idx}.pdf"
            echo -e "  -> Mapeado: ${CYAN}${base}${NC} a ${GREEN}doc${idx}.pdf${NC}"
            idx=$((idx + 1))
            if [ $idx -gt 4 ]; then break; fi
        fi
    done
    echo -e "\n${GREEN}[ÉXITO] Archivos copiados y normalizados en ${TARGET_DIR}.${NC}"
else
    echo -e "${YELLOW}[AVISO] No se encontró la carpeta '${SOURCE_DIR}' o no contenía PDFs.${NC}"
    echo -e "${YELLOW}Generando 4 PDFs sintéticos válidos para permitir ejecución inmediata de pruebas...${NC}"

    generar_pdf_valido "${TARGET_DIR}/doc1.pdf" "Documento de prueba 1 - UTN FRSR Carga Baseline"
    generar_pdf_valido "${TARGET_DIR}/doc2.pdf" "Documento de prueba 2 - UTN FRSR Prueba de Concurrencia Spike"
    generar_pdf_valido "${TARGET_DIR}/doc3.pdf" "Documento de prueba 3 - UTN FRSR Extraccion de texto intensiva"
    generar_pdf_valido "${TARGET_DIR}/doc4.pdf" "Documento de prueba 4 - UTN FRSR Evaluacion de escalabilidad"

    echo -e "${GREEN}[OK] Se crearon exitosamente doc1.pdf, doc2.pdf, doc3.pdf y doc4.pdf en ${TARGET_DIR}.${NC}"
    echo -e "${CYAN}Nota: Cuando clones '../pdf-extractext', vuelve a ejecutar este script para usar los PDFs oficiales.${NC}"
fi

echo -e "\nContenido actual en ${TARGET_DIR}:"
ls -lh "${TARGET_DIR}" | grep -E '\.pdf$' || true
echo -e "${CYAN}======================================================================${NC}"
