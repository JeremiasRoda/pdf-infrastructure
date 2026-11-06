import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ==============================================================================
// Benchmark k6 - Prueba de Carga Spike (100 VUs)
// Cátedra: Desarrollo de Software - UTN FR San Rafael
// ==============================================================================
// Escenario de Prueba:
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
    // Tasa de fallos tolerable durante el spike (excluyendo o auditando 429/503)
    http_req_failed: ['rate<0.10'],
    // El 95% de las solicitudes exitosas deben responder en menos de 10s bajo carga pesada
    http_req_duration: ['p(95)<10000'],
  },
};

// URL objetivo (vía Traefik Ingress Proxy)
const TARGET_URL = __ENV.TARGET_URL || 'http://extractor.universidad.localhost/extract';

// Ruta configurable del fixture PDF
const FIXTURE_PATH = __ENV.PDF_FIXTURE_PATH || './pdfs/doc279.pdf';

// ------------------------------------------------------------------------------
// Carga Eficiente en Init Context (Memoria compartida entre VUs)
// ------------------------------------------------------------------------------
let pdfBinary;
let fixtureMetadata = {
  path: FIXTURE_PATH,
  isOfficial279: false,
  isFallback: false,
  sizeBytes: 0,
};

try {
  pdfBinary = open(FIXTURE_PATH, 'b');
  fixtureMetadata.sizeBytes = pdfBinary.byteLength;
  
  // Validar cabecera de archivo PDF (%PDF)
  const headerBytes = new Uint8Array(pdfBinary.slice(0, 4));
  const headerStr = String.fromCharCode.apply(null, headerBytes);
  if (headerStr !== '%PDF') {
    throw new Error(`El archivo en '${FIXTURE_PATH}' no tiene una cabecera PDF válida (encontrado '${headerStr}' != '%PDF').`);
  }
  
  if (FIXTURE_PATH.toLowerCase().includes('279') || fixtureMetadata.sizeBytes > 10 * 1024 * 1024) {
    fixtureMetadata.isOfficial279 = true;
  }
} catch (err) {
  // Si no se encuentra el PDF oficial de 279 páginas, intentar fallback de desarrollo local
  try {
    const fallbackPath = './pdfs/doc1.pdf';
    pdfBinary = open(fallbackPath, 'b');
    fixtureMetadata.path = fallbackPath;
    fixtureMetadata.sizeBytes = pdfBinary.byteLength;
    fixtureMetadata.isFallback = true;
    fixtureMetadata.isOfficial279 = false;
  } catch (_) {
    throw new Error(
      `\n[ERROR k6 - FIXTURE FALTANTE]\n` +
      `No se pudo cargar el archivo PDF en '${FIXTURE_PATH}' ni el fallback en './pdfs/doc1.pdf'.\n` +
      `Para ejecutar el benchmark oficial con el PDF de 279 páginas:\n` +
      `1. Copie el archivo oficial en 'load-tests/pdfs/doc279.pdf', o\n` +
      `2. Especifique la ruta completa con: PDF_FIXTURE_PATH=/ruta/al/pdf k6 run load-tests/k6-spike.js\n`
    );
  }
}

// ------------------------------------------------------------------------------
// Métricas Personalizadas de Resiliencia y Rendimiento
// ------------------------------------------------------------------------------
const successfulExtractions = new Counter('extracciones_exitosas_200');
const rateLimitedRequests = new Counter('solicitudes_rate_limited_429');
const circuitBrokenRequests = new Counter('solicitudes_circuit_breaker_503');
const otherFailedRequests = new Counter('solicitudes_otros_fallos');
const extractionDuration = new Trend('duracion_extraccion_ms');

export default function () {
  const startTime = Date.now();

  const params = {
    headers: {
      'Content-Type': 'application/pdf',
      'X-Filename': fixtureMetadata.isOfficial279 ? 'dataset_279_paginas.pdf' : 'fixture_prueba.pdf',
    },
    timeout: '35s',
  };

  // Envío del buffer binario cargado en init context (eficiencia de memoria)
  const res = http.post(TARGET_URL, pdfBinary, params);
  const duration = Date.now() - startTime;
  extractionDuration.add(duration);

  // Clasificación de respuestas para separar Rate Limiting de fallos de backend
  if (res.status === 200) {
    successfulExtractions.add(1);
    check(res, {
      'status 200 OK': (r) => r.status === 200,
      'JSON contiene content': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body && typeof body.content !== 'undefined';
        } catch (_) {
          return false;
        }
      },
      'JSON contiene page_count': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body && typeof body.page_count === 'number' && body.page_count > 0;
        } catch (_) {
          return false;
        }
      },
    });
  } else if (res.status === 429) {
    rateLimitedRequests.add(1);
  } else if (res.status === 503) {
    circuitBrokenRequests.add(1);
  } else {
    otherFailedRequests.add(1);
  }

  // Pequeña pausa entre iteraciones
  sleep(0.05 + Math.random() * 0.1);
}

// ------------------------------------------------------------------------------
// Generación del Reporte Estructurado
// ------------------------------------------------------------------------------
export function handleSummary(data) {
  const reqs = data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0;
  const rate = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate.toFixed(2) : '0.00';
  const failRate = data.metrics.http_req_failed ? (data.metrics.http_req_failed.values.rate * 100).toFixed(2) : '0.00';

  const p50 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(50)'].toFixed(2) : '0.00';
  const p90 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(90)'].toFixed(2) : '0.00';
  const p95 = data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(95)'].toFixed(2) : '0.00';
  const max = data.metrics.http_req_duration ? data.metrics.http_req_duration.values.max.toFixed(2) : '0.00';

  const okCount = data.metrics.extracciones_exitosas_200 ? data.metrics.extracciones_exitosas_200.values.count : 0;
  const rateLimitCount = data.metrics.solicitudes_rate_limited_429 ? data.metrics.solicitudes_rate_limited_429.values.count : 0;
  const cbCount = data.metrics.solicitudes_circuit_breaker_503 ? data.metrics.solicitudes_circuit_breaker_503.values.count : 0;
  const otherFailCount = data.metrics.solicitudes_otros_fallos ? data.metrics.solicitudes_otros_fallos.values.count : 0;

  const tipoFixture = fixtureMetadata.isOfficial279
    ? 'PDF OFICIAL (279 Páginas - Benchmark Válido)'
    : (fixtureMetadata.isFallback
        ? 'FALLBACK LOCAL TEMPORAL (doc1.pdf - NO ES BENCHMARK OFICIAL)'
        : `PDF PERSONALIZADO (${fixtureMetadata.path})`);

  let rateLimitWarning = '';
  if (rateLimitCount > 0) {
    rateLimitWarning = `
[AVISO SOBRE RATE LIMITING EN FRONTERA]
Se registraron ${rateLimitCount} respuestas HTTP 429 correspondientes al middleware RateLimit de Traefik.
Esto demuestra la efectividad de la protección de frontera.
Para medir la capacidad cruda del backend sin limitador en k6, configure en .env:
  RATE_LIMIT_EXTRACT_AVERAGE=500
  RATE_LIMIT_EXTRACT_BURST=1000
y reinicie con 'docker compose up -d'.
`;
  }

  const resumen = `
======================================================================
  UTN FRSR - REPORTE DE BENCHMARK SPIKE (k6 - 100 VUs)
======================================================================
Objetivo HTTP:          ${TARGET_URL}
Fixture Utilizado:      ${tipoFixture}
Ruta del Archivo:       ${fixtureMetadata.path} (${(fixtureMetadata.sizeBytes / 1024 / 1024).toFixed(2)} MB)
Perfil de Carga:        40s (10s subida 0->100 VUs / 20s meseta / 10s bajada)
----------------------------------------------------------------------
Total de Solicitudes:   ${reqs}
Throughput Efectivo:    ${rate} req/s
Tasa Global de Fallos:  ${failRate}%
----------------------------------------------------------------------
Desglose de Respuestas:
  ✔ Exitosas (200 OK):             ${okCount}
  ⚠ Limitadas por RateLimit (429): ${rateLimitCount}
  ⚡ Cortadas por CircuitBreaker (503): ${cbCount}
  ✘ Otros Errores (4xx/5xx/timeout):   ${otherFailCount}
----------------------------------------------------------------------
Latencia del Endpoint:
  p(50) Mediana:        ${p50} ms
  p(90) Percentil 90:   ${p90} ms
  p(95) Percentil 95:   ${p95} ms
  Máxima Observada:     ${max} ms
======================================================================
${rateLimitWarning}
`;

  return {
    stdout: resumen,
  };
}
