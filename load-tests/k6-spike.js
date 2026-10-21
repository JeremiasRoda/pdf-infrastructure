import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ==============================================================================
// Benchmark k6 - Prueba de Carga Spike (100 VUs)
// Cátedra: Desarrollo de Software - UTN FR San Rafael
// ==============================================================================
// Escenario:
// 1. 10s subiendo abruptamente de 0 a 100 usuarios virtuales (Spike)
// 2. 20s meseta sostenida con 100 VUs concurrentes
// 3. 10s rampa descendente de 100 a 0 VUs (Recuperación)
// Total: 40 segundos de prueba intensiva
// ==============================================================================

export const options = {
  stages: [
    { duration: '10s', target: 100 }, // Subida abrupta (Spike)
    { duration: '20s', target: 100 }, // Carga máxima sostenida
    { duration: '10s', target: 0 },   // Descenso y recuperación
  ],
  thresholds: {
    // Menos del 5% de errores admitidos durante la prueba
    http_req_failed: ['rate<0.05'],
    // El 95% de las solicitudes deben responder en menos de 5s bajo concurrencia
    http_req_duration: ['p(95)<5000'],
  },
};

// URL objetivo (vía Traefik Reverse Proxy o directo)
const TARGET_URL = __ENV.TARGET_URL || 'http://extractor.universidad.localhost/extract';

// Modo de envío: 'multipart' (por defecto para FastAPI UploadFile) o 'binary' (application/pdf directo)
const PAYLOAD_MODE = __ENV.PAYLOAD_MODE || 'multipart';

// Carga de los 4 archivos PDF del dataset oficial en tiempo de inicialización
const pdfFiles = [
  { name: 'doc1.pdf', data: open('./pdfs/doc1.pdf', 'b') },
  { name: 'doc2.pdf', data: open('./pdfs/doc2.pdf', 'b') },
  { name: 'doc3.pdf', data: open('./pdfs/doc3.pdf', 'b') },
  { name: 'doc4.pdf', data: open('./pdfs/doc4.pdf', 'b') },
];

// Métricas personalizadas
const successfulExtractions = new Counter('extracciones_exitosas');
const failedExtractions = new Counter('extracciones_fallidas');
const extractionDuration = new Trend('duracion_extraccion_ms');

export default function () {
  // Rotación determinista entre los 4 PDFs según el número de iteración y VU
  const fileIndex = (__VU + __ITER) % pdfFiles.length;
  const selectedPdf = pdfFiles[fileIndex];

  let res;
  const startTime = Date.now();

  if (PAYLOAD_MODE === 'binary') {
    // Envío directo con Content-Type: application/pdf
    const params = {
      headers: {
        'Content-Type': 'application/pdf',
        'X-Filename': selectedPdf.name,
      },
      timeout: '30s',
    };
    res = http.post(TARGET_URL, selectedPdf.data, params);
  } else {
    // Envío multipart/form-data estándar (campo 'file')
    const payload = {
      file: http.file(selectedPdf.data, selectedPdf.name, 'application/pdf'),
    };
    const params = {
      timeout: '30s',
    };
    res = http.post(TARGET_URL, payload, params);
  }

  const duration = Date.now() - startTime;
  extractionDuration.add(duration);

  // Validaciones exigidas por la cátedra: status 200 y JSON con 'content' y 'page_count'
  const isOk = check(res, {
    'código HTTP es 200': (r) => r.status === 200,
    'respuesta contiene campo content': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body && typeof body.content !== 'undefined';
      } catch (_) {
        return false;
      }
    },
    'respuesta contiene campo page_count': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body && typeof body.page_count === 'number';
      } catch (_) {
        return false;
      }
    },
  });

  if (isOk) {
    successfulExtractions.add(1);
  } else {
    failedExtractions.add(1);
  }

  // Pequeña pausa aleatoria de 50ms a 150ms para simular variabilidad de usuarios
  sleep(0.05 + Math.random() * 0.1);
}

// Generación de reporte final formateado en consola y guardado
export function handleSummary(data) {
  const reqs = data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0;
  const rate = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate.toFixed(2) : '0.00';
  const failRate = data.metrics.http_req_failed ? (data.metrics.http_req_failed.values.rate * 100).toFixed(2) : '0.00';
  
  const p50 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(50)'].toFixed(2) : '0.00';
  const p90 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(90)'].toFixed(2) : '0.00';
  const p95 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(95)'].toFixed(2) : '0.00';
  const max = data.metrics.http_req_duration ? data.metrics.http_req_duration.values.max.toFixed(2) : '0.00';

  const resumen = `
======================================================================
  UTN FRSR - REPORTE DE PRUEBA DE CARGA SPIKE (k6 - 100 VUs)
======================================================================
Objetivo:             ${TARGET_URL}
Modo de Carga:        ${PAYLOAD_MODE}
Duración de Prueba:   40 segundos (10s subida / 20s meseta / 10s bajada)
----------------------------------------------------------------------
Total de Solicitudes: ${reqs}
Throughput Efectivo:  ${rate} req/s
Tasa de Fallos:       ${failRate}%
----------------------------------------------------------------------
Latencia Mediana (p50): ${p50} ms
Latencia Percentil 90:  ${p90} ms
Latencia Percentil 95:  ${p95} ms
Latencia Máxima:        ${max} ms
======================================================================
`;

  return {
    stdout: resumen,
  };
}
