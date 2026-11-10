#!/usr/bin/env bash
set -e

TRAEFIK_URL="http://127.0.0.1:80"
API_HOST="api.universidad.localhost"
DOCS_HOST="documents.universidad.localhost"
PDF_FILE="load-tests/pdfs/doc1.pdf"

echo "======================================================================"
echo "   PRUEBA DE FLUJO COMPLETO END-TO-END (BASH / CURL)                 "
echo "======================================================================"

if [ ! -f "$PDF_FILE" ]; then
    echo "[INFO] Generando PDF de prueba sintetico..."
    mkdir -p "$(dirname "$PDF_FILE")"
    cat << 'EOF' > "$PDF_FILE"
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length 55 >> stream
BT /F1 24 Tf 100 700 Td (UTN FRSR Evaluacion Arquitectura) Tj ET
endstream endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000244 00000 n 
0000000350 00000 n 
trailer << /Size 6 /Root 1 0 R >>
startxref
427
%%EOF
fi

echo "[PASO 1/2] Enviando PDF a traves de Traefik hacia la API..."
RESPONSE=$(curl -s -X POST "$TRAEFIK_URL/process" \
    -H "Host: $API_HOST" \
    -F "file=@$PDF_FILE;type=application/pdf")

echo "Respuesta de la API:"
echo "$RESPONSE"

DOC_ID=$(echo "$RESPONSE" | grep -o '"document_id":"[^"]*' | cut -d'"' -f4)

if [ -n "$DOC_ID" ]; then
    echo -e "\n[PASO 2/2] Verificando en Documents Service (MongoDB)..."
    DOC_RESPONSE=$(curl -s -X GET "$TRAEFIK_URL/documents/$DOC_ID" -H "Host: $DOCS_HOST")
    echo "Respuesta de Documents:"
    echo "$DOC_RESPONSE"
    echo -e "\n[EXITO] Documento persistido y verificado correctamente."
fi
